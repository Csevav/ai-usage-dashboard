import json
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from dashboard_server import DashboardHandler  # noqa: E402


def _serve(directory, token_file):
    server = ThreadingHTTPServer(
        ("127.0.0.1", 0),
        lambda *args, **kwargs: DashboardHandler(
            *args,
            directory=str(directory),
            token_file=str(token_file),
            server_port=0,
            **kwargs,
        ),
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def _post(url, token=None):
    headers = {}
    if token is not None:
        headers["X-Dashboard-Token"] = token
    req = urllib.request.Request(url, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5) as res:
            return res.status, json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        with exc:
            return exc.code, json.loads(exc.read().decode("utf-8"))


class DashboardServerTest(unittest.TestCase):
    def test_refresh_requires_token_and_accepts_valid_token(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            token_file = directory / ".refresh-token"
            marker = directory / "refreshed"
            scripts_dir = directory / "scripts"
            token_file.write_text("secret-token", encoding="utf-8")
            scripts_dir.mkdir()
            build = scripts_dir / "build_dashboard.py"
            build.write_text(
                "from pathlib import Path\n"
                "Path('refreshed').touch()\n",
                encoding="utf-8",
            )

            server = _serve(directory, token_file)
            try:
                url = f"http://127.0.0.1:{server.server_port}/__refresh__"

                status, body = _post(url)
                self.assertEqual(status, 403)
                self.assertFalse(body["ok"])
                self.assertFalse(marker.exists())

                status, body = _post(url, "secret-token")
                self.assertEqual(status, 200)
                self.assertTrue(body["ok"])
                self.assertTrue(marker.exists())
            finally:
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    unittest.main()
