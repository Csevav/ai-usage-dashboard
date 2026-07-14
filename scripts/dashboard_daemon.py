#!/usr/bin/env python3
from __future__ import annotations

import argparse
import secrets
import sys
from pathlib import Path

from build_dashboard import Paths, path_config, sync_runtime


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--home")
    return parser.parse_args()


def ensure_token(token_file: Path) -> None:
    token_file.parent.mkdir(parents=True, exist_ok=True)
    if not token_file.exists() or token_file.stat().st_size == 0:
        token_file.write_text(secrets.token_hex(32), encoding="utf-8")


def build_if_missing(paths: Paths) -> None:
    if paths.out.exists():
        return
    from build_dashboard import main as build_main

    argv = sys.argv[:]
    try:
        sys.argv = [
            "build_dashboard.py",
            "--source-dir",
            str(paths.home_dir),
            "--home",
            str(paths.home_dir),
            "--no-open",
            "--no-summary",
            "--from-server",
        ]
        raise_code = build_main()
        if raise_code:
            raise SystemExit(raise_code)
    finally:
        sys.argv = argv


def main() -> int:
    args = parse_args()
    paths = path_config(
        argparse.Namespace(
            source_dir=args.source_dir,
            home=args.home,
            no_open=True,
            no_summary=True,
            from_server=True,
        )
    )
    sync_runtime(paths)
    ensure_token(paths.token_file)
    build_if_missing(paths)

    from dashboard_server import main as server_main

    argv = sys.argv[:]
    try:
        sys.argv = [
            "dashboard_server.py",
            "--dir",
            str(paths.home_dir),
            "--port",
            str(paths.server_port),
            "--token-file",
            str(paths.token_file),
        ]
        server_main()
    finally:
        sys.argv = argv
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
