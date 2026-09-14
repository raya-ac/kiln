"""Real Gunicorn socket acceptance; child processes and fixtures always removed."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from db import connect, migrate
from psycopg import sql
from psycopg.conninfo import make_conninfo

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get("KILN_TEST_DATABASE_URL"), "real disposable PostgreSQL DSN required")
class HTTPTests(unittest.TestCase):
    def test_real_http_vertical_slice(self):
        (ROOT / ".test-tmp").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT / ".test-tmp") as temporary:
            base_dsn = os.environ["KILN_TEST_DATABASE_URL"]
            schema = "http_" + uuid.uuid4().hex
            with connect(base_dsn) as db:
                db.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema)))
            def cleanup_schema():
                with connect(base_dsn) as db:
                    db.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(schema)))
            self.addCleanup(cleanup_schema)
            database = make_conninfo(base_dsn, options="-csearch_path=" + schema)
            migrate(database)
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            env = dict(os.environ, KILN_DATABASE_URL=database, KILN_BIND=f"127.0.0.1:{port}", TMPDIR=temporary)
            with open(Path(temporary) / "server.log", "w+") as log:
                process = subprocess.Popen([sys.executable, "-m", "gunicorn", "--config", "gunicorn.conf.py", "service:create_app()"],
                                           cwd=ROOT, env=env, stdout=log, stderr=log)
                try:
                    base = f"http://127.0.0.1:{port}"

                    def send(method, path, data=None, token=None):
                        headers = {"Content-Type": "application/json"}
                        if token:
                            headers["Authorization"] = "Bearer " + token
                        req = Request(base + path, data=json.dumps(data).encode() if data is not None else None,
                                      headers=headers, method=method)
                        try:
                            response = urlopen(req, timeout=15)
                        except HTTPError as error:
                            response = error
                        with response:
                            body = response.read()
                            if "application/json" in response.headers.get("Content-Type", ""):
                                body = json.loads(body)
                            return response.status, body, response.headers

                    for _ in range(100):
                        if process.poll() is not None:
                            self.fail("Gunicorn exited during startup")
                        try:
                            if send("GET", "/healthz")[0] == 200:
                                break
                        except URLError:
                            time.sleep(0.05)
                    else:
                        self.fail("Gunicorn readiness timeout")
                    self.assertEqual(send("GET", "/")[0], 200)
                    status, logo, headers = send("GET", "/logo.png")
                    self.assertEqual(status, 200)
                    self.assertEqual(headers["Content-Type"], "image/png")
                    self.assertEqual(logo[:8], b"\x89PNG\r\n\x1a\n")
                    status, account, _ = send("POST", "/api/v1/auth/register", {"handle": "http_fixture", "password": "private fixture password"})
                    self.assertEqual(status, 201)
                    token = account["session"]["token"]
                    event = {"eventId": "http-event-0000000001", "sessionId": "http-session-00000001", "provider": "codex", "model": "gpt-5.5", "timestamp": "2026-09-14T06:00:00Z", "inputTokens": 0}
                    self.assertEqual(send("POST", "/api/v1/usage/events", event, token)[0], 403)
                    self.assertEqual(send("PATCH", "/api/v1/settings", {"usageSharingEnabled": True}, token)[0], 200)
                    self.assertEqual(send("POST", "/api/v1/usage/events", event, token)[0], 201)
                    self.assertEqual(send("POST", "/api/v1/usage/events", event, token)[0], 200)
                    self.assertEqual(send("POST", "/api/v1/usage/events", dict(event, inputTokens=1), token)[0], 409)
                    _, aggregate, _ = send("GET", "/api/v1/usage/aggregate", token=token)
                    self.assertIsNone(aggregate["counts"]["outputTokens"]["knownTotal"])
                    self.assertEqual(send("GET", "/u/http_fixture")[0], 200)
                    self.assertEqual(send("PATCH", "/api/v1/settings", {"usageSharingEnabled": False}, token)[0], 200)
                    self.assertEqual(send("POST", "/api/v1/usage/events", event, token)[0], 403)
                    self.assertEqual(send("POST", "/api/v1/auth/logout", {}, token)[0], 200)
                    self.assertEqual(send("GET", "/api/v1/usage/history", token=token)[0], 401)
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                log.seek(0)
                logs = log.read()
                self.assertNotIn("private fixture password", logs)
                self.assertNotIn(token, logs)


if __name__ == "__main__":
    unittest.main()
