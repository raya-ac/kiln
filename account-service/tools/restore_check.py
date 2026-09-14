"""Real pg_dump/restore readback, restricted to two explicitly disposable DBs."""
import hashlib
import io
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from psycopg.conninfo import conninfo_to_dict
from db import backup, connect, migrate, pg_environment
from service import Service


def call(app, method, route, data=None, token=None):
    raw = json.dumps(data or {}).encode()
    env = {"REQUEST_METHOD": method, "PATH_INFO": "/api/v1" + route, "QUERY_STRING": "",
           "CONTENT_TYPE": "application/json", "CONTENT_LENGTH": str(len(raw)),
           "REMOTE_ADDR": "192.0.2.199", "wsgi.input": io.BytesIO(raw)}
    if token:
        env["HTTP_AUTHORIZATION"] = "Bearer " + token
    status = []
    result = json.loads(b"".join(app(env, lambda code, _: status.append(int(code[:3])))))
    if status[0] not in (200, 201):
        raise RuntimeError("restore fixture API failed with status " + str(status[0]))
    return result


def main():
    source = os.environ["KILN_RESTORE_SOURCE_URL"]
    target = os.environ["KILN_RESTORE_TARGET_URL"]
    destination = Path(os.environ["KILN_RESTORE_DUMP"])
    src, dst = conninfo_to_dict(source), conninfo_to_dict(target)
    if src.get("dbname") == dst.get("dbname"):
        raise RuntimeError("source and destination must differ")
    for config in (src, dst):
        if "restorecheck" not in config.get("dbname", ""):
            raise RuntimeError("only restorecheck-marked disposable databases permitted")
    for dsn in (source, target):
        with connect(dsn) as db:
            if db.execute("SELECT COUNT(*) AS total FROM pg_tables WHERE schemaname='public'").fetchone()["total"]:
                raise RuntimeError("restore check databases must initially be empty")
    migrate(source)
    app = Service(source)
    account = call(app, "POST", "/auth/register", {"handle": "restore_" + secrets.token_hex(6), "password": secrets.token_urlsafe(24)})
    token = account["session"]["token"]
    call(app, "PATCH", "/settings", {"usageSharingEnabled": True}, token)
    event = {"eventId": str(uuid.uuid4()), "sessionId": str(uuid.uuid4()), "provider": "codex", "model": "restore-fixture",
             "timestamp": "2026-09-14T06:00:00Z", "inputTokens": 0, "outputTokens": None, "cachedInputTokens": 3}
    call(app, "POST", "/usage/events", event, token)
    before = call(app, "GET", "/usage/history", token=token)
    backup(source, destination)
    environment = pg_environment(target)
    restored = subprocess.run(["pg_restore", "--exit-on-error", "--single-transaction", "--no-owner", "--no-acl",
                               "--dbname", dst["dbname"], str(destination)], env=environment,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if restored.returncode:
        raise RuntimeError("PostgreSQL restore failed; archive retained")
    app = Service(target)
    assert call(app, "GET", "/me", token=token)["account"]["id"] == account["account"]["id"]
    assert call(app, "GET", "/usage/history", token=token) == before
    assert call(app, "POST", "/usage/events", event, token)["duplicate"]
    print("PASS: real PostgreSQL backup/restore preserved account, hashed session auth, event identity, nullable counts and idempotency")
    print("dump SHA256 " + hashlib.sha256(destination.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
