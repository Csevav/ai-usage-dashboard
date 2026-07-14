#!/usr/bin/env python3
from __future__ import annotations

import argparse
import glob
import hmac
import html as html_lib
import json
import os
import platform
import re
import secrets
import shutil
import subprocess
import sys
import time
import webbrowser
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.error import URLError
from urllib.request import urlopen

try:
    import pwd  # type: ignore
except ImportError:  # pragma: no cover - Windows
    pwd = None


ROOT_FILES = (
    "build.sh",
    "build.ps1",
    "template.html",
)
SCRIPT_FILES = (
    "build_dashboard.py",
    "dashboard_daemon.py",
    "dashboard_server.py",
    "manage_daemon.py",
)


@dataclass
class Paths:
    source_dir: Path
    home_dir: Path
    template: Path
    out: Path
    server_script: Path
    token_file: Path
    daemon_script: Path
    server_port: int

    @property
    def server_url(self) -> str:
        return f"http://127.0.0.1:{self.server_port}"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--home", default=os.environ.get("AI_USAGE_DASHBOARD_HOME", str(Path.home() / ".ai-usage-dashboard")))
    parser.add_argument("--no-open", action="store_true")
    parser.add_argument("--no-summary", action="store_true")
    parser.add_argument("--from-server", action="store_true")
    return parser.parse_args()


def path_config(args: argparse.Namespace) -> Paths:
    home_dir = Path(args.home).expanduser()
    server_port = int(os.environ.get("AI_USAGE_DASHBOARD_PORT", "46327"))
    return Paths(
        source_dir=Path(args.source_dir).expanduser().resolve(),
        home_dir=home_dir,
        template=home_dir / "template.html",
        out=home_dir / "index.html",
        server_script=home_dir / "scripts" / "dashboard_server.py",
        token_file=home_dir / ".refresh-token",
        daemon_script=home_dir / "dashboard_daemon.sh",
        server_port=server_port,
    )


def sync_runtime(paths: Paths) -> None:
    paths.home_dir.mkdir(parents=True, exist_ok=True)
    scripts_dir = paths.home_dir / "scripts"
    scripts_dir.mkdir(parents=True, exist_ok=True)

    source_root = paths.source_dir
    daemon_src = source_root / "scripts" / "dashboard_daemon.sh"
    for name in ROOT_FILES:
        src = source_root / name
        dst = paths.home_dir / name
        if src.exists():
            shutil.copy2(src, dst)
            if dst.suffix in ("", ".sh"):
                try:
                    dst.chmod(dst.stat().st_mode | 0o111)
                except OSError:
                    pass

    for name in SCRIPT_FILES:
        src = source_root / "scripts" / name
        dst = scripts_dir / name
        if src.exists():
            shutil.copy2(src, dst)
            try:
                dst.chmod(dst.stat().st_mode | 0o111)
            except OSError:
                pass


def ensure_refresh_token(token_file: Path) -> str:
    token_file.parent.mkdir(parents=True, exist_ok=True)
    if not token_file.exists() or token_file.stat().st_size == 0:
        token_file.write_text(secrets.token_urlsafe(32), encoding="utf-8")
        try:
            os.chmod(token_file, 0o600)
        except OSError:
            pass
    return token_file.read_text(encoding="utf-8").strip()


def print_notice(level: str, message: str) -> None:
    print(f"[{level}] {message}", file=sys.stderr)


def check_required_tools() -> None:
    if shutil.which("node") is None:
        print_notice("ERROR", "未检测到 Node.js。这个 dashboard 需要 Node.js 18+ 作为 npx fallback，并用于读取包版本。")
        raise SystemExit(1)
    try:
        major = int(subprocess.run(["node", "-p", "process.versions.node.split('.')[0]"], capture_output=True, text=True, check=True).stdout.strip() or "0")
    except Exception:
        major = 0
    if major < 18:
        version = subprocess.run(["node", "-v"], capture_output=True, text=True, check=False).stdout.strip() or "unknown"
        print_notice("ERROR", f"当前 Node.js 版本过低（检测到 {version}）。请升级到 Node.js 18 或更高版本。")
        raise SystemExit(1)


def npx_command() -> str | None:
    if os.name == "nt" and shutil.which("npx.cmd"):
        return "npx.cmd"
    if shutil.which("npx"):
        return "npx"
    return None


def resolve_ccusage_command(notices: list[dict[str, str]]) -> list[str] | None:
    if shutil.which("ccusage"):
        return ["ccusage"]
    npx = npx_command()
    if npx:
        notices.append(
            {
                "level": "warning",
                "zh": "未检测到本机 ccusage，已改用 npx 临时运行 ccusage。首次运行需要能访问 npm；如果 npm 登录态、代理或网络异常，数据面板会为空。",
                "en": "No local ccusage binary was found, so the dashboard will run ccusage through npx. The first run needs npm access; stale npm credentials, proxy issues, or network failures can leave data panels empty.",
            }
        )
        print_notice("WARN", "未检测到本机 ccusage，已改用 npx 临时运行 ccusage。")
        return [npx, "--yes", "ccusage"]
    notices.append(
        {
            "level": "error",
            "zh": "未检测到 ccusage，也未检测到 npx。看板可以打开，但无法拉取 Claude Code / Codex 用量数据。请安装 ccusage：npm install -g ccusage，或安装 Node.js/npm 以启用 npx fallback。",
            "en": "Neither ccusage nor npx was found. The dashboard can open, but it cannot load Claude Code / Codex usage data. Install ccusage with: npm install -g ccusage, or install Node.js/npm to enable the npx fallback.",
        }
    )
    print_notice("ERROR", "未检测到 ccusage，也未检测到 npx。看板将生成空数据页面。")
    return None


def add_data_source_notices(notices: list[dict[str, str]]) -> None:
    claude_dir = Path.home() / ".claude" / "projects"
    codex_dir = Path.home() / ".codex" / "sessions"
    if not claude_dir.is_dir():
        notices.append({"level": "warning", "zh": "未检测到 ~/.claude/projects，所以 Claude Code 面板大概率会为空。", "en": "No ~/.claude/projects directory was found, so the Claude Code panels will likely be empty."})
    elif not any(claude_dir.rglob("*.jsonl")):
        notices.append({"level": "warning", "zh": "检测到了 ~/.claude/projects，但里面还没有对话记录，所以 Claude Code 面板会为空。", "en": "The ~/.claude/projects directory exists, but no conversation records were found, so the Claude Code panels will be empty."})
    if not codex_dir.is_dir():
        notices.append({"level": "warning", "zh": "未检测到 ~/.codex/sessions，所以 Codex 面板大概率会为空。", "en": "No ~/.codex/sessions directory was found, so the Codex panels will likely be empty."})
    elif not any(codex_dir.rglob("rollout-*.jsonl")):
        notices.append({"level": "warning", "zh": "检测到了 ~/.codex/sessions，但里面还没有会话记录，所以 Codex 面板会为空。", "en": "The ~/.codex/sessions directory exists, but no session records were found, so the Codex panels will be empty."})


def fetch_health(server_url: str) -> str:
    try:
        with urlopen(f"{server_url}/__health__", timeout=1.5) as res:
            return res.read().decode("utf-8")
    except Exception:
        return ""


def stop_stale_server(paths: Paths) -> None:
    if platform.system() == "Darwin" and shutil.which("launchctl"):
        subprocess.run(["launchctl", "remove", f"com.csevav.ai-usage-dashboard.{paths.server_port}"], capture_output=True, check=False)
    pids: list[str] = []
    if shutil.which("lsof"):
        proc = subprocess.run(["lsof", f"-tiTCP:{paths.server_port}", "-sTCP:LISTEN"], capture_output=True, text=True, check=False)
        pids.extend(line.strip() for line in proc.stdout.splitlines() if line.strip())
    elif os.name == "nt":
        proc = subprocess.run(["netstat", "-ano", "-p", "tcp"], capture_output=True, text=True, check=False)
        for line in proc.stdout.splitlines():
            if f":{paths.server_port}" not in line or "LISTENING" not in line.upper():
                continue
            parts = line.split()
            if parts:
                pids.append(parts[-1])
    elif shutil.which("ss"):
        proc = subprocess.run(["ss", "-ltnp"], capture_output=True, text=True, check=False)
        for line in proc.stdout.splitlines():
            if f":{paths.server_port}" not in line:
                continue
            match = re.search(r"pid=(\d+)", line)
            if match:
                pids.append(match.group(1))
    pids = sorted({pid for pid in pids if pid})
    for pid in pids:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", pid, "/F"], capture_output=True, check=False)
        else:
            subprocess.run(["kill", pid], capture_output=True, check=False)


def start_server(paths: Paths) -> None:
    log_out = paths.home_dir / "dashboard-server.out.log"
    log_err = paths.home_dir / "dashboard-server.err.log"
    log_out.parent.mkdir(parents=True, exist_ok=True)
    stdout = open(log_out, "ab")
    stderr = open(log_err, "ab")
    kwargs: dict[str, Any] = {"cwd": str(paths.home_dir), "stdout": stdout, "stderr": stderr}
    if os.name == "nt":
        kwargs["creationflags"] = getattr(subprocess, "DETACHED_PROCESS", 0) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    else:
        kwargs["start_new_session"] = True
    subprocess.Popen(
        [sys.executable, str(paths.server_script), "--dir", str(paths.home_dir), "--port", str(paths.server_port), "--token-file", str(paths.token_file)],
        **kwargs,
    )


def ensure_server(paths: Paths) -> None:
    if not paths.server_script.exists():
        raise SystemExit(f"Refresh server script not found: {paths.server_script}")
    health = fetch_health(paths.server_url)
    if '"refreshAuth": "token"' in health or '"refreshAuth":"token"' in health:
        return
    if '"ok": true' in health or '"ok":true' in health:
        stop_stale_server(paths)
    start_server(paths)
    for _ in range(20):
        time.sleep(0.2)
        health = fetch_health(paths.server_url)
        if '"refreshAuth": "token"' in health or '"refreshAuth":"token"' in health:
            return
    raise SystemExit(f"Failed to start local dashboard server on {paths.server_url}")


def run_text(*args: str) -> str:
    try:
        proc = subprocess.run(list(args), capture_output=True, text=True, check=False)
    except Exception:
        return ""
    return (proc.stdout or "").strip()


def clean_name(value: str | None) -> str:
    text = " ".join(str(value or "").strip().split())
    if not text:
        return ""
    if text.lower() in {"unknown", "user", "none", "null"}:
        return ""
    return text


def user_name() -> str:
    def claude_name() -> str:
        try:
            proc = subprocess.run(["claude", "auth", "status", "--json"], capture_output=True, text=True, check=False)
            raw = (proc.stdout or "").strip()
            if not raw:
                return ""
            data = json.loads(raw)
        except Exception:
            return ""
        for key in ("name", "fullName", "displayName", "userName"):
            value = clean_name(data.get(key))
            if value:
                return value
        email = (data.get("email") or "").split("@", 1)[0]
        parts = [p for p in re.split(r"[._-]+", email) if p]
        return " ".join(p.capitalize() for p in parts)

    def system_name() -> str:
        if os.name != "nt":
            value = clean_name(run_text("id", "-F"))
            if value:
                return value
            try:
                if pwd is None:
                    return ""
                return clean_name(pwd.getpwuid(os.getuid()).pw_gecos.split(",", 1)[0])
            except Exception:
                return ""
        return clean_name(os.environ.get("USERNAME"))

    for getter in (claude_name, system_name, lambda: clean_name(run_text("git", "config", "--global", "user.name"))):
        value = getter()
        if value:
            return value
    return "User"


def run_usage_jobs(ccusage_cmd: list[str] | None, notices: list[dict[str, str]]) -> dict[str, str]:
    fallbacks = {
        "DAILY": '{"daily":[]}',
        "WEEKLY": '{"weekly":[]}',
        "MONTHLY": '{"monthly":[]}',
        "CLAUDE_SESSIONS": '{"sessions":[]}',
        "MIXED_DAILY": '{"daily":[]}',
        "MIXED_WEEKLY": '{"weekly":[]}',
        "MIXED_MONTHLY": '{"monthly":[]}',
        "CODEX_DAILY": '{"daily":[]}',
        "CODEX_WEEKLY": '{"weekly":[]}',
        "CODEX_MONTHLY": '{"monthly":[]}',
        "CODEX_SESSIONS": '{"sessions":[]}',
    }
    if ccusage_cmd is None:
        return fallbacks

    include_mixed = os.environ.get("AI_USAGE_DASHBOARD_INCLUDE_MIXED", "0") == "1"
    jobs = [
        ("DAILY", ccusage_cmd + ["claude", "daily", "--json", "--breakdown"], "Claude Code 用量数据加载失败。可能无法运行 ccusage，当前网络/npm 不可用，或这台电脑上还没有 Claude Code 使用记录。", "Claude Code metrics could not be loaded. ccusage may fail to run, npm/network access may be blocked, or this machine may not have Claude Code usage records yet."),
        ("WEEKLY", ccusage_cmd + ["claude", "weekly", "--json", "--breakdown"], "Claude Code 用量数据加载失败。可能无法运行 ccusage，当前网络/npm 不可用，或这台电脑上还没有 Claude Code 使用记录。", "Claude Code metrics could not be loaded. ccusage may fail to run, npm/network access may be blocked, or this machine may not have Claude Code usage records yet."),
        ("MONTHLY", ccusage_cmd + ["claude", "monthly", "--json", "--breakdown"], "Claude Code 用量数据加载失败。可能无法运行 ccusage，当前网络/npm 不可用，或这台电脑上还没有 Claude Code 使用记录。", "Claude Code metrics could not be loaded. ccusage may fail to run, npm/network access may be blocked, or this machine may not have Claude Code usage records yet."),
        ("CLAUDE_SESSIONS", ccusage_cmd + ["claude", "session", "--json"], "Claude Code 对话数据加载失败。可能无法运行 ccusage，当前网络/npm 不可用，或这台电脑上还没有 Claude Code 使用记录。", "Claude Code session data could not be loaded. ccusage may fail to run, npm/network access may be blocked, or this machine may not have Claude Code usage records yet."),
        ("CODEX_DAILY", ccusage_cmd + ["codex", "daily", "--json"], "Codex 用量数据加载失败。可能无法运行 ccusage codex，当前网络/npm 不可用，或这台电脑上还没有 Codex 使用记录。", "Codex metrics could not be loaded. ccusage codex may fail to run, npm/network access may be blocked, or this machine may not have Codex usage records yet."),
        ("CODEX_MONTHLY", ccusage_cmd + ["codex", "monthly", "--json"], "Codex 用量数据加载失败。可能无法运行 ccusage codex，当前网络/npm 不可用，或这台电脑上还没有 Codex 使用记录。", "Codex metrics could not be loaded. ccusage codex may fail to run, npm/network access may be blocked, or this machine may not have Codex usage records yet."),
        ("CODEX_SESSIONS", ccusage_cmd + ["codex", "session", "--json"], "Codex 用量数据加载失败。可能无法运行 ccusage codex，当前网络/npm 不可用，或这台电脑上还没有 Codex 使用记录。", "Codex metrics could not be loaded. ccusage codex may fail to run, npm/network access may be blocked, or this machine may not have Codex usage records yet."),
    ]
    if include_mixed:
        jobs.extend(
            [
                ("MIXED_DAILY", ccusage_cmd + ["daily", "--json", "--breakdown"], "综合总用量数据加载失败。可能无法运行 ccusage，当前网络/npm 不可用，或这台电脑上还没有 AI 使用记录。", "Combined usage totals could not be loaded. ccusage may fail to run, npm/network access may be blocked, or this machine may not have AI usage records yet."),
                ("MIXED_WEEKLY", ccusage_cmd + ["weekly", "--json", "--breakdown"], "综合总用量数据加载失败。可能无法运行 ccusage，当前网络/npm 不可用，或这台电脑上还没有 AI 使用记录。", "Combined usage totals could not be loaded. ccusage may fail to run, npm/network access may be blocked, or this machine may not have AI usage records yet."),
                ("MIXED_MONTHLY", ccusage_cmd + ["monthly", "--json", "--breakdown"], "综合总用量数据加载失败。可能无法运行 ccusage，当前网络/npm 不可用，或这台电脑上还没有 AI 使用记录。", "Combined usage totals could not be loaded. ccusage may fail to run, npm/network access may be blocked, or this machine may not have AI usage records yet."),
            ]
        )
    max_workers = int(os.environ.get("AI_USAGE_DASHBOARD_MAX_PARALLEL", "4"))

    def run_job(name: str, cmd: list[str], zh: str, en: str) -> tuple[str, str]:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        output = (proc.stdout or "").strip()
        if proc.returncode == 0 and output:
            return name, output
        error_text = " ".join((proc.stderr or proc.stdout or "").split())
        notices.append({"level": "warning", "zh": zh, "en": en})
        print_notice("WARN", f"{zh}{' 原因：' + error_text if error_text else ''}")
        return name, fallbacks[name]

    results = dict(fallbacks)
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = [pool.submit(run_job, *job) for job in jobs]
        for future in as_completed(futures):
            name, value = future.result()
            results[name] = value
    return results


_codex_meta_cache: dict[str, dict[str, str | None]] = {}
_claude_title_cache: dict[str, dict[str, str | None]] | None = None


def clean_title(value: Any, limit: int = 80) -> str | None:
    text = " ".join(str(value or "").replace("\r", "\n").split())
    if not text:
        return None
    return text[:limit]


def claude_title_map() -> dict[str, dict[str, str | None]]:
    global _claude_title_cache
    if _claude_title_cache is not None:
        return _claude_title_cache
    title_map: dict[str, dict[str, str | None]] = {}
    for path in sorted(glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))):
        sid = os.path.basename(path).replace(".jsonl", "")
        ai_title = None
        last_prompt = None
        first_user = None
        first_timestamp = None
        last_timestamp = None
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    try:
                        entry = json.loads(line)
                    except Exception:
                        continue
                    ts = entry.get("timestamp")
                    if ts:
                        first_timestamp = first_timestamp or ts
                        last_timestamp = ts
                    if not ai_title and entry.get("type") == "ai-title" and entry.get("aiTitle"):
                        ai_title = clean_title(entry.get("aiTitle"))
                    if not last_prompt and entry.get("type") == "last-prompt" and entry.get("lastPrompt"):
                        last_prompt = clean_title(entry.get("lastPrompt"))
                    if first_user or entry.get("type") != "user":
                        continue
                    message = entry.get("message") or {}
                    content = message.get("content")
                    text = None
                    if isinstance(content, str):
                        text = content
                    elif isinstance(content, list):
                        parts = [item.get("text") for item in content if isinstance(item, dict) and item.get("type") == "text" and item.get("text")]
                        if parts:
                            text = "\n".join(parts)
                    text = clean_title(text)
                    if text:
                        first_user = text
        except Exception:
            continue
        title_map[sid] = {"title": ai_title or last_prompt or first_user, "first_timestamp": first_timestamp, "last_timestamp": last_timestamp}
    _claude_title_cache = title_map
    return title_map


def claude_project_label(raw: Any) -> str:
    bits = [part for part in str(raw or "").split("-") if part]
    return bits[-1] if bits else "claude"


def codex_project_label(raw: Any) -> str:
    text = str(raw or "").rstrip("/\\")
    if not text:
        return "codex"
    return os.path.basename(text) or text


def codex_session_path(session: dict[str, Any]) -> str | None:
    fn = session.get("sessionFile") or ""
    if not fn:
        return None
    home = os.path.expanduser("~")
    fname = fn if fn.endswith(".jsonl") else f"{fn}.jsonl"
    candidates = []
    directory = session.get("directory") or ""
    if directory:
        candidates.append(os.path.join(home, ".codex", "sessions", directory, fname))
    candidates.extend(
        [
            os.path.join(home, ".codex", "sessions", fname),
            os.path.join(home, ".codex", "archived_sessions", fname),
        ]
    )
    for candidate in candidates:
        if os.path.exists(candidate):
            return candidate
    hits = glob.glob(os.path.join(home, ".codex", "**", fname), recursive=True)
    return hits[0] if hits else None


def codex_metadata(session: dict[str, Any]) -> dict[str, str | None]:
    cache_key = session.get("sessionFile") or session.get("sessionId") or json.dumps(session, sort_keys=True)
    if cache_key in _codex_meta_cache:
        return _codex_meta_cache[cache_key]
    title = None
    project = None
    path = codex_session_path(session)
    try:
        if path:
            with open(path, "r", encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    try:
                        entry = json.loads(line)
                    except Exception:
                        continue
                    payload = entry.get("payload") or {}
                    if not project and entry.get("type") == "session_meta":
                        cwd = payload.get("cwd")
                        if cwd:
                            project = codex_project_label(cwd)
                    if title or entry.get("type") != "response_item" or payload.get("type") != "message" or payload.get("role") != "user":
                        continue
                    for item in payload.get("content") or []:
                        text = (item.get("text") or "").strip()
                        if not text:
                            continue
                        if text.startswith("<") or text.startswith("# AGENTS.md") or text.startswith("## Memory") or text.startswith("# Files mentioned"):
                            continue
                        first = text.split("\n", 1)[0].strip()
                        if first.startswith("[$") and "SKILL.md" in first:
                            continue
                        if first.startswith("http://") or first.startswith("https://"):
                            match = re.match(r"https?://(?:www\.)?([^/]+)(/[^?#]*)?", first)
                            if match:
                                first = match.group(1) + (match.group(2) or "")
                        title = first[:80]
                        break
    except Exception:
        pass
    if not project:
        project = codex_project_label(session.get("project") or session.get("projectPath") or session.get("cwd") or session.get("workspace") or "")
    meta = {"title": title, "project": project}
    _codex_meta_cache[cache_key] = meta
    return meta


def normalize_period_rows(rows: list[Any], grain: str) -> list[Any]:
    key_by_grain = {"daily": "date", "weekly": "week", "monthly": "month"}
    primary_key = key_by_grain[grain]
    out = []
    for row in rows or []:
        if not isinstance(row, dict):
            out.append(row)
            continue
        fixed = dict(row)
        period = fixed.get("period")
        if period and not fixed.get(primary_key):
            fixed[primary_key] = period
        out.append(fixed)
    return out


def normalize_summary(scope: str, totals: dict[str, Any]) -> dict[str, float]:
    totals = totals or {}
    if scope == "claude":
        return {"cost": totals.get("totalCost", 0) or 0, "tokens": totals.get("totalTokens", 0) or 0, "cacheRead": totals.get("cacheReadTokens", 0) or 0}
    return {"cost": totals.get("costUSD", 0) or 0, "tokens": totals.get("totalTokens", 0) or 0, "cacheRead": totals.get("cachedInputTokens", 0) or 0}


def summarize_rows(scope: str, rows: list[dict[str, Any]]) -> dict[str, float]:
    if scope == "claude":
        return {"cost": sum((r.get("totalCost", 0) or 0) for r in rows), "tokens": sum((r.get("totalTokens", 0) or 0) for r in rows), "cacheRead": sum((r.get("cacheReadTokens", 0) or 0) for r in rows)}
    return {"cost": sum((r.get("costUSD", 0) or 0) for r in rows), "tokens": sum((r.get("totalTokens", 0) or 0) for r in rows), "cacheRead": sum((r.get("cachedInputTokens", 0) or 0) for r in rows)}


def row_by_key(rows: list[dict[str, Any]], key_name: str, expected: str) -> dict[str, Any] | None:
    for row in rows or []:
        if str(row.get(key_name) or "") == expected:
            return row
    return None


def build_summary(scope: str, daily_rows: list[dict[str, Any]], weekly_rows: list[dict[str, Any]], monthly_rows: list[dict[str, Any]], all_totals: dict[str, Any]) -> dict[str, Any]:
    today = date.today()
    summary: dict[str, Any] = {"all": normalize_summary(scope, all_totals), "ranges": {}, "years": {}}
    today_row = row_by_key(daily_rows, "date", today.isoformat())
    summary["ranges"]["today"] = summarize_rows(scope, [today_row] if today_row else [])
    if scope == "claude":
        week_start = today - timedelta(days=today.isoweekday() - 1)
        week_row = row_by_key(weekly_rows, "week", week_start.isoformat())
        month_row = row_by_key(monthly_rows, "month", f"{today.year}-{today.month:02d}")
        summary["ranges"]["week"] = summarize_rows(scope, [week_row] if week_row else [])
        summary["ranges"]["month"] = summarize_rows(scope, [month_row] if month_row else [])
    else:
        week_start = today - timedelta(days=today.isoweekday() - 1)
        week_end = week_start + timedelta(days=6)
        month_key = f"{today.year}-{today.month:02d}"
        summary["ranges"]["week"] = summarize_rows(scope, [r for r in daily_rows if week_start.isoformat() <= str(r.get("date") or "") <= week_end.isoformat()])
        month_row = row_by_key(monthly_rows, "month", month_key)
        summary["ranges"]["month"] = summarize_rows(scope, [month_row] if month_row else [r for r in daily_rows if str(r.get("date") or "").startswith(month_key + "-")])
    years = sorted({str(r.get("date", ""))[:4] for r in daily_rows if r.get("date")}, reverse=True)
    for year in years:
        if monthly_rows:
            summary["years"][year] = summarize_rows(scope, [r for r in monthly_rows if str(r.get("month") or "").startswith(f"{year}-")])
        else:
            summary["years"][year] = summarize_rows(scope, [r for r in daily_rows if str(r.get("date") or "").startswith(f"{year}-")])
    return summary


def build_project_rows(sessions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    projects: dict[str, dict[str, Any]] = {}
    for session in sessions or []:
        name = session.get("project") or "unknown"
        bucket = projects.setdefault(name, {"project": name, "sessions": 0, "costUSD": 0, "totalTokens": 0, "lastTimestamp": "", "models": set()})
        bucket["sessions"] += 1
        bucket["costUSD"] += session.get("costUSD") or 0
        bucket["totalTokens"] += session.get("totalTokens") or 0
        ts = session.get("timestamp") or session.get("date") or ""
        if ts > bucket["lastTimestamp"]:
            bucket["lastTimestamp"] = ts
        bucket["models"].update(session.get("models") or [])
    out = []
    for item in projects.values():
        fixed = dict(item)
        fixed["models"] = sorted(fixed["models"])
        fixed["date"] = (fixed["lastTimestamp"] or "")[:10]
        out.append(fixed)
    return sorted(out, key=lambda row: (row.get("costUSD") or 0, row.get("totalTokens") or 0), reverse=True)


def dump_json_for_script(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False).replace("&", "\\u0026").replace("<", "\\u003c").replace(">", "\\u003e").replace("</", "<\\/")


def render_dashboard(paths: Paths, data_env: dict[str, str], notices: list[dict[str, str]], refresh_token: str) -> None:
    claude_daily = normalize_period_rows(json.loads(data_env["DAILY"]).get("daily", []), "daily")
    claude_weekly = normalize_period_rows(json.loads(data_env["WEEKLY"]).get("weekly", []), "weekly")
    claude_monthly = normalize_period_rows(json.loads(data_env["MONTHLY"]).get("monthly", []), "monthly")
    codex_daily_rows = normalize_period_rows(json.loads(data_env["CODEX_DAILY"]).get("daily", []), "daily")
    codex_weekly_rows = normalize_period_rows(json.loads(data_env["CODEX_WEEKLY"]).get("weekly", []), "weekly")
    codex_monthly_rows = normalize_period_rows(json.loads(data_env["CODEX_MONTHLY"]).get("monthly", []), "monthly")
    mixed_daily_rows = normalize_period_rows(json.loads(data_env["MIXED_DAILY"]).get("daily", []), "daily")
    mixed_weekly_rows = normalize_period_rows(json.loads(data_env["MIXED_WEEKLY"]).get("weekly", []), "weekly")
    mixed_monthly_rows = normalize_period_rows(json.loads(data_env["MIXED_MONTHLY"]).get("monthly", []), "monthly")
    claude_titles = claude_title_map()
    claude_sessions_raw = json.loads(data_env["CLAUDE_SESSIONS"]).get("sessions", [])
    codex_sessions_raw = json.loads(data_env["CODEX_SESSIONS"]).get("sessions", [])

    claude_session_rows = [
        {
            "sessionId": s.get("sessionId"),
            "date": ((claude_titles.get(s.get("sessionId")) or {}).get("last_timestamp") or s.get("lastActivity") or "")[:10],
            "timestamp": (claude_titles.get(s.get("sessionId")) or {}).get("last_timestamp") or s.get("lastActivity") or "",
            "title": ((claude_titles.get(s.get("sessionId")) or {}).get("title")) or f"{claude_project_label(s.get('projectPath'))} · {(s.get('sessionId') or '')[:8]}",
            "project": claude_project_label(s.get("projectPath")),
            "costUSD": s.get("totalCost") or 0,
            "totalTokens": s.get("totalTokens") or 0,
            "models": s.get("modelsUsed") or [],
        }
        for s in claude_sessions_raw
    ]
    codex_session_rows = [
        {
            "sessionId": s.get("sessionId"),
            "date": (s.get("lastActivity") or "")[:10],
            "timestamp": s.get("lastActivity") or "",
            "title": (codex_metadata(s).get("title")) or (s.get("sessionFile") or "")[-12:],
            "project": (codex_metadata(s).get("project")) or "codex",
            "costUSD": s.get("costUSD") or 0,
            "totalTokens": s.get("totalTokens") or 0,
            "models": sorted(list((s.get("models") or {}).keys())),
        }
        for s in codex_sessions_raw
    ]

    payload = {
        "daily": claude_daily,
        "weekly": claude_weekly,
        "monthly": claude_monthly,
        "totals": json.loads(data_env["MONTHLY"]).get("totals", {}),
        "summary": build_summary("claude", claude_daily, claude_weekly, claude_monthly, json.loads(data_env["MONTHLY"]).get("totals", {})),
        "sessions": claude_session_rows,
        "projects": build_project_rows(claude_session_rows),
        "codex": {
            "daily": codex_daily_rows,
            "weekly": codex_weekly_rows,
            "monthly": codex_monthly_rows,
            "totals": json.loads(data_env["CODEX_MONTHLY"]).get("totals", {}),
            "summary": build_summary("codex", codex_daily_rows, codex_weekly_rows, codex_monthly_rows, json.loads(data_env["CODEX_MONTHLY"]).get("totals", {})),
            "sessions": codex_session_rows,
            "projects": build_project_rows(codex_session_rows),
        },
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "notices": notices,
        "combined": {
            "summary": build_summary("claude", mixed_daily_rows, mixed_weekly_rows, mixed_monthly_rows, json.loads(data_env["MIXED_MONTHLY"]).get("totals", {})),
        },
    }

    html = paths.template.read_text(encoding="utf-8")
    html = html.replace("__DATA__", dump_json_for_script(payload))
    html = html.replace("__USER_NAME__", html_lib.escape(user_name()))
    html = html.replace("__SERVER_URL__", paths.server_url)
    html = html.replace("__REFRESH_TOKEN__", json.dumps(refresh_token))
    paths.out.write_text(html, encoding="utf-8")


def print_summary(data_env: dict[str, str], notices: list[dict[str, str]]) -> None:
    if notices:
        print("\n## Environment notices\n")
        for item in notices:
            msg = (item.get("en") or item.get("zh") or "").strip()
            if msg:
                print(f"- {msg}")

    daily = normalize_period_rows(json.loads(data_env["DAILY"]).get("daily", []), "daily")
    monthly = normalize_period_rows(json.loads(data_env["MONTHLY"]).get("monthly", []), "monthly")
    now = datetime.now()
    today_str = now.strftime("%Y-%m-%d")
    this_month = now.strftime("%Y-%m")
    cutoff_7d = (now - timedelta(days=6)).strftime("%Y-%m-%d")
    today_row = next((r for r in daily if r.get("date") == today_str), None)
    month_row = next((r for r in monthly if r.get("month") == this_month), None)
    last7 = [r for r in daily if (r.get("date") or "") >= cutoff_7d]
    sum_cost_7d = sum(r.get("totalCost", 0) or 0 for r in last7)
    sum_tokens_7d = sum(r.get("totalTokens", 0) or 0 for r in last7)
    all_cost = sum(r.get("totalCost", 0) or 0 for r in monthly)
    all_tokens = sum(r.get("totalTokens", 0) or 0 for r in monthly)
    model_costs: dict[str, float] = {}
    for row in monthly:
        for breakdown in row.get("modelBreakdowns", []):
            model = breakdown.get("modelName")
            model_costs[model] = model_costs.get(model, 0) + (breakdown.get("cost") or 0)
    top_models = sorted(model_costs.items(), key=lambda item: -item[1])[:5]

    def fmt_usd(value: float) -> str:
        return f"${value:.2f}"

    def fmt_n(value: float) -> str:
        return f"{int(value):,}"

    def short(model: str) -> str:
        return re.sub(r"-\d{8}$", "", model.replace("claude-", ""))

    print("\n## Claude Usage — quick summary\n")
    print("| Period | Cost | Tokens |")
    print("|---|---:|---:|")
    if today_row:
        print(f"| Today ({today_str}) | {fmt_usd(today_row.get('totalCost', 0) or 0)} | {fmt_n(today_row.get('totalTokens', 0) or 0)} |")
    else:
        print(f"| Today ({today_str}) | $0.00 | 0 |")
    print(f"| Last 7 days | {fmt_usd(sum_cost_7d)} | {fmt_n(sum_tokens_7d)} |")
    if month_row:
        print(f"| This month ({this_month}) | {fmt_usd(month_row.get('totalCost', 0) or 0)} | {fmt_n(month_row.get('totalTokens', 0) or 0)} |")
    else:
        print(f"| This month ({this_month}) | $0.00 | 0 |")
    print(f"| All time | {fmt_usd(all_cost)} | {fmt_n(all_tokens)} |")
    print()
    if top_models:
        print("### Top models by cost (all time)\n")
        print("| Model | Cost |")
        print("|---|---:|")
        for model, cost in top_models:
            print(f"| {short(model)} | {fmt_usd(cost)} |")
        print()


def maybe_open(paths: Paths, from_server: bool) -> None:
    target = f"{paths.server_url}/index.html?t={int(time.time())}" if not from_server else paths.out.resolve().as_uri()
    if os.environ.get("TERM_PROGRAM") == "vscode":
        print("\nInside VS Code? Open in Simple Browser instead of a separate window:")
        print(f"  {target}")
    try:
        webbrowser.open(target)
    except Exception:
        print(f"Dashboard ready: {target}")


def main() -> int:
    args = parse_args()
    paths = path_config(args)
    check_required_tools()
    sync_runtime(paths)
    if not paths.template.exists():
        print_notice("ERROR", f"Template not found: {paths.template}")
        return 1
    refresh_token = ensure_refresh_token(paths.token_file)
    notices: list[dict[str, str]] = []
    add_data_source_notices(notices)
    ccusage_cmd = resolve_ccusage_command(notices)
    if not args.from_server:
        ensure_server(paths)
    data_env = run_usage_jobs(ccusage_cmd, notices)
    render_dashboard(paths, data_env, notices, refresh_token)
    if not args.no_summary:
        print_summary(data_env, notices)
    print(f"Dashboard regenerated: {paths.out}")
    if not args.no_open:
        maybe_open(paths, args.from_server)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
