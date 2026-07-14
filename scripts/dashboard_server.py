#!/usr/bin/env python3
import argparse
import hmac
import json
import os
import subprocess
import sys
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class DashboardHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, directory=None, token_file=None, server_port=None, **kwargs):
        self.token_file = token_file
        self.server_port = server_port
        super().__init__(*args, directory=directory, **kwargs)

    def do_GET(self):
        if self.path == "/__health__":
            self._write_json(HTTPStatus.OK, {"ok": True, "refreshAuth": "token"})
            return
        super().do_GET()

    def do_OPTIONS(self):
        self.send_response(HTTPStatus.FORBIDDEN)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        if self.path != "/__refresh__":
            self._write_json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "Not found"})
            return
        if not self._authorized_refresh():
            self._write_json(HTTPStatus.FORBIDDEN, {"ok": False, "error": "Forbidden"})
            return
        build_path = os.path.join(self.directory, "scripts", "build_dashboard.py")
        try:
            proc = subprocess.run(
                [sys.executable, build_path, "--source-dir", self.directory, "--home", self.directory, "--no-open", "--no-summary", "--from-server"],
                cwd=self.directory,
                capture_output=True,
                text=True,
                timeout=180,
                check=False,
            )
        except Exception as exc:
            self._write_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"ok": False, "error": str(exc)})
            return

        if proc.returncode != 0:
            self._write_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {
                    "ok": False,
                    "error": (proc.stderr or proc.stdout or f"build exited with {proc.returncode}").strip(),
                },
            )
            return

        self._write_json(HTTPStatus.OK, {"ok": True})

    def log_message(self, fmt, *args):
        sys.stderr.write("[dashboard-server] " + (fmt % args) + "\n")

    def _write_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _authorized_refresh(self):
        expected = self._read_token()
        if not expected:
            return False
        origin = self.headers.get("Origin")
        if origin and origin not in self._allowed_origins():
            return False
        supplied = self.headers.get("X-Dashboard-Token", "")
        return hmac.compare_digest(supplied, expected)

    def _allowed_origins(self):
        port = self.server_port or self.server.server_port
        return {f"http://127.0.0.1:{port}", f"http://localhost:{port}"}

    def _read_token(self):
        if not self.token_file:
            return ""
        try:
            with open(self.token_file, "r", encoding="utf-8") as fh:
                return fh.read().strip()
        except OSError:
            return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--token-file", required=True)
    args = parser.parse_args()

    server = ThreadingHTTPServer(
        ("127.0.0.1", args.port),
        lambda *a, **kw: DashboardHandler(
            *a,
            directory=args.dir,
            token_file=args.token_file,
            server_port=args.port,
            **kw,
        ),
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
