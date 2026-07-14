#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["install", "uninstall", "start", "stop", "restart", "status", "print-config", "run"])
    parser.add_argument("--source-dir", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--home", default=os.environ.get("AI_USAGE_DASHBOARD_HOME", str(Path.home() / ".ai-usage-dashboard")))
    return parser.parse_args()


def python_command_for_runner(script: Path, source_dir: Path, home_dir: Path) -> list[str]:
    command = [sys.executable, str(script), "--source-dir", str(source_dir), "--home", str(home_dir)]
    return command


def windows_task_name(port: int) -> str:
    return f"AIUsageDashboardDaemon-{port}"


def windows_runner_cmd(home_dir: Path, source_dir: Path) -> Path:
    path = home_dir / "dashboard-daemon.cmd"
    python_cmd = subprocess.list2cmdline(python_command_for_runner(home_dir / "scripts" / "dashboard_daemon.py", home_dir, home_dir))
    content = "@echo off\r\n" + python_cmd + "\r\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


def run_checked(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, check=False)


def manage_windows(action: str, source_dir: Path, home_dir: Path, port: int) -> int:
    task_name = windows_task_name(port)
    runner = windows_runner_cmd(home_dir, source_dir)
    if action == "install":
        proc = run_checked(["schtasks", "/Create", "/SC", "ONLOGON", "/TN", task_name, "/TR", str(runner), "/RL", "LIMITED", "/F"])
        if proc.returncode != 0:
            print(proc.stderr or proc.stdout, file=sys.stderr)
            return proc.returncode
        run_checked(["schtasks", "/Run", "/TN", task_name])
        print(f"Installed AI Usage Dashboard daemon at http://127.0.0.1:{port}")
        print(f"Task Scheduler name: {task_name}")
        return 0
    if action == "uninstall":
        run_checked(["schtasks", "/End", "/TN", task_name])
        proc = run_checked(["schtasks", "/Delete", "/TN", task_name, "/F"])
        if proc.returncode != 0:
            print(proc.stderr or proc.stdout, file=sys.stderr)
            return proc.returncode
        print(f"Removed AI Usage Dashboard daemon: {task_name}")
        return 0
    if action == "start":
        proc = run_checked(["schtasks", "/Run", "/TN", task_name])
        if proc.returncode != 0:
            print(proc.stderr or proc.stdout, file=sys.stderr)
            return proc.returncode
        print(f"Started AI Usage Dashboard daemon: {task_name}")
        return 0
    if action == "stop":
        proc = run_checked(["schtasks", "/End", "/TN", task_name])
        if proc.returncode != 0:
            print(proc.stderr or proc.stdout, file=sys.stderr)
            return proc.returncode
        print(f"Stopped AI Usage Dashboard daemon: {task_name}")
        return 0
    if action == "restart":
        run_checked(["schtasks", "/End", "/TN", task_name])
        proc = run_checked(["schtasks", "/Run", "/TN", task_name])
        if proc.returncode != 0:
            print(proc.stderr or proc.stdout, file=sys.stderr)
            return proc.returncode
        print(f"Restarted AI Usage Dashboard daemon: {task_name}")
        return 0
    if action == "status":
        proc = run_checked(["schtasks", "/Query", "/TN", task_name, "/FO", "LIST", "/V"])
        if proc.returncode != 0:
            print(f"stopped {task_name} http://127.0.0.1:{port}")
            return 1
        print(f"running {task_name} http://127.0.0.1:{port}")
        return 0
    if action == "print-config":
        print(json.dumps({"platform": "windows", "taskName": task_name, "runner": str(runner), "url": f"http://127.0.0.1:{port}"}, ensure_ascii=False, indent=2))
        return 0
    if action == "run":
        command = python_command_for_runner(home_dir / "scripts" / "dashboard_daemon.py", home_dir, home_dir)
        return subprocess.call(command)
    return 1


def plist_content(label: str, home_dir: Path, port: int) -> str:
    daemon_script = home_dir / "scripts" / "dashboard_daemon.py"
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
      <string>{sys.executable}</string>
      <string>{daemon_script}</string>
      <string>--source-dir</string>
      <string>{home_dir}</string>
      <string>--home</string>
      <string>{home_dir}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
      <key>AI_USAGE_DASHBOARD_HOME</key>
      <string>{home_dir}</string>
      <key>AI_USAGE_DASHBOARD_PORT</key>
      <string>{port}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>{home_dir}</string>
    <key>StandardOutPath</key>
    <string>{home_dir / "launch-agent.out.log"}</string>
    <key>StandardErrorPath</key>
    <string>{home_dir / "launch-agent.err.log"}</string>
  </dict>
</plist>
"""


def manage_macos(action: str, home_dir: Path, port: int) -> int:
    label = f"com.csevav.ai-usage-dashboard.daemon.{port}"
    plist_path = Path.home() / "Library" / "LaunchAgents" / f"{label}.plist"
    plist_path.parent.mkdir(parents=True, exist_ok=True)
    if action == "print-config":
        print(plist_content(label, home_dir, port))
        return 0
    if action in {"install", "start", "restart"} and not plist_path.exists():
        plist_path.write_text(plist_content(label, home_dir, port), encoding="utf-8")
    if action == "install":
        run_checked(["launchctl", "bootout", f"gui/{os.getuid()}", str(plist_path)])
        proc = run_checked(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist_path)])
        if proc.returncode != 0:
            print(proc.stderr or proc.stdout, file=sys.stderr)
            return proc.returncode
        run_checked(["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{label}"])
        print(f"Installed AI Usage Dashboard daemon at http://127.0.0.1:{port}")
        print(f"LaunchAgent: {plist_path}")
        return 0
    if action == "uninstall":
        run_checked(["launchctl", "bootout", f"gui/{os.getuid()}", str(plist_path)])
        plist_path.unlink(missing_ok=True)
        print(f"Removed AI Usage Dashboard daemon: {label}")
        return 0
    if action == "start":
        proc = run_checked(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist_path)])
        if proc.returncode != 0 and "already loaded" not in ((proc.stderr or "") + (proc.stdout or "")).lower():
            print(proc.stderr or proc.stdout, file=sys.stderr)
            return proc.returncode
        run_checked(["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{label}"])
        print(f"Started AI Usage Dashboard daemon: {label}")
        return 0
    if action == "stop":
        run_checked(["launchctl", "bootout", f"gui/{os.getuid()}", str(plist_path)])
        print(f"Stopped AI Usage Dashboard daemon: {label}")
        return 0
    if action == "restart":
        run_checked(["launchctl", "bootout", f"gui/{os.getuid()}", str(plist_path)])
        proc = run_checked(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist_path)])
        if proc.returncode != 0:
            print(proc.stderr or proc.stdout, file=sys.stderr)
            return proc.returncode
        run_checked(["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{label}"])
        print(f"Restarted AI Usage Dashboard daemon: {label}")
        return 0
    if action == "status":
        proc = run_checked(["launchctl", "print", f"gui/{os.getuid()}/{label}"])
        if proc.returncode == 0:
            print(f"running {label} http://127.0.0.1:{port}")
            return 0
        print(f"stopped {label} http://127.0.0.1:{port}")
        return 1
    if action == "run":
        return subprocess.call(python_command_for_runner(home_dir / "scripts" / "dashboard_daemon.py", home_dir, home_dir))
    return 1


def linux_service_name(port: int) -> str:
    return f"ai-usage-dashboard-daemon-{port}.service"


def linux_service_content(home_dir: Path, port: int) -> str:
    daemon_script = home_dir / "scripts" / "dashboard_daemon.py"
    return f"""[Unit]
Description=AI Usage Dashboard daemon ({port})
After=network.target

[Service]
Type=simple
ExecStart={sys.executable} {daemon_script} --source-dir {home_dir} --home {home_dir}
WorkingDirectory={home_dir}
Restart=always
Environment=AI_USAGE_DASHBOARD_HOME={home_dir}
Environment=AI_USAGE_DASHBOARD_PORT={port}

[Install]
WantedBy=default.target
"""


def systemd_user_dir() -> Path:
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return config_home / "systemd" / "user"


def manage_linux(action: str, home_dir: Path, port: int) -> int:
    if shutil.which("systemctl") is None:
        print("Linux daemon management requires systemctl --user.", file=sys.stderr)
        return 1
    service_name = linux_service_name(port)
    service_dir = systemd_user_dir()
    service_path = service_dir / service_name
    if action == "print-config":
        print(linux_service_content(home_dir, port))
        return 0
    if action in {"install", "start", "restart"}:
        service_dir.mkdir(parents=True, exist_ok=True)
        service_path.write_text(linux_service_content(home_dir, port), encoding="utf-8")
    if action == "install":
        run_checked(["systemctl", "--user", "daemon-reload"])
        proc = run_checked(["systemctl", "--user", "enable", "--now", service_name])
        if proc.returncode != 0:
            print(proc.stderr or proc.stdout, file=sys.stderr)
            return proc.returncode
        print(f"Installed AI Usage Dashboard daemon at http://127.0.0.1:{port}")
        print(f"systemd user service: {service_path}")
        return 0
    if action == "uninstall":
        run_checked(["systemctl", "--user", "disable", "--now", service_name])
        service_path.unlink(missing_ok=True)
        run_checked(["systemctl", "--user", "daemon-reload"])
        print(f"Removed AI Usage Dashboard daemon: {service_name}")
        return 0
    if action == "start":
        proc = run_checked(["systemctl", "--user", "start", service_name])
        if proc.returncode != 0:
            print(proc.stderr or proc.stdout, file=sys.stderr)
            return proc.returncode
        print(f"Started AI Usage Dashboard daemon: {service_name}")
        return 0
    if action == "stop":
        proc = run_checked(["systemctl", "--user", "stop", service_name])
        if proc.returncode != 0:
            print(proc.stderr or proc.stdout, file=sys.stderr)
            return proc.returncode
        print(f"Stopped AI Usage Dashboard daemon: {service_name}")
        return 0
    if action == "restart":
        proc = run_checked(["systemctl", "--user", "restart", service_name])
        if proc.returncode != 0:
            print(proc.stderr or proc.stdout, file=sys.stderr)
            return proc.returncode
        print(f"Restarted AI Usage Dashboard daemon: {service_name}")
        return 0
    if action == "status":
        proc = run_checked(["systemctl", "--user", "is-active", service_name])
        if proc.returncode == 0 and (proc.stdout or "").strip() == "active":
            print(f"running {service_name} http://127.0.0.1:{port}")
            return 0
        print(f"stopped {service_name} http://127.0.0.1:{port}")
        return 1
    if action == "run":
        return subprocess.call(python_command_for_runner(home_dir / "scripts" / "dashboard_daemon.py", home_dir, home_dir))
    return 1


def main() -> int:
    args = parse_args()
    source_dir = Path(args.source_dir).expanduser().resolve()
    home_dir = Path(args.home).expanduser().resolve()
    port = int(os.environ.get("AI_USAGE_DASHBOARD_PORT", "46327"))
    system = platform.system()
    if system == "Windows":
        return manage_windows(args.action, source_dir, home_dir, port)
    if system == "Darwin":
        return manage_macos(args.action, home_dir, port)
    if system == "Linux":
        return manage_linux(args.action, home_dir, port)
    if args.action == "run":
        return subprocess.call(python_command_for_runner(home_dir / "scripts" / "dashboard_daemon.py", home_dir, home_dir))
    print("Background daemon management is currently supported on macOS, Windows, and Linux systemd user sessions.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
