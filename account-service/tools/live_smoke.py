"""Explicit public acceptance with exact-ID fixture cleanup; never prints secrets."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import secrets
import sys
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from db import connect
from argon2 import PasswordHasher


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True, choices=["https://kiln.raya.ac", "http://127.0.0.1:27480"])
    args = parser.parse_args()
    opener = build_opener(NoRedirect())
    owned = []

    def call(method, path, data=None, token=None, expected=200):
        headers = {"Content-Type": "application/json", "User-Agent": "KilnAccountAcceptance/1"}
        if token:
            headers["Authorization"] = "Bearer " + token
        req = Request(args.base + path, json.dumps(data).encode() if data is not None else None, headers, method=method)
        try:
            response = opener.open(req, timeout=15)
        except HTTPError as error:
            response = error
        with response:
            raw = response.read(1024 * 1024)
            if response.status != expected:
                raise RuntimeError(f"{method} {path} expected {expected}, got {response.status}")
            if response.headers.get_content_type() == "application/json":
                return json.loads(raw)
            return raw

    try:
        assert call("GET", "/healthz")["apiVersion"] == "v1"
        assert b"<h1>Kiln</h1>" in call("GET", "/")
        assert call("GET", "/logo.png").startswith(b"\x89PNG")
        accounts = []
        for _ in range(2):
            handle = "qa_" + secrets.token_hex(8)
            password = secrets.token_urlsafe(24)
            # Keep enough exact ownership evidence even if the response is lost.
            record = {"handle": handle, "passwords": [password], "id": None}
            owned.append(record)
            result = call("POST", "/api/v1/auth/register", {"handle": handle, "password": password}, expected=201)
            record["id"] = result["account"]["id"]
            accounts.append(result)
        alice, bob = accounts
        token = alice["session"]["token"]
        bob_token = bob["session"]["token"]
        assert not alice["account"]["usageSharingEnabled"]
        assert call("GET", "/api/v1/me", token=token)["account"]["id"] == owned[0]["id"]
        call("GET", "/api/v1/me", expected=401)
        event = {"eventId": str(uuid.uuid4()), "sessionId": str(uuid.uuid4()), "provider": "codex", "model": "acceptance-fixture",
                 "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
                 "inputTokens": 0, "outputTokens": None, "cachedInputTokens": 3, "reasoningOutputTokens": None}
        call("POST", "/api/v1/usage/events", event, token, expected=403)
        call("PATCH", "/api/v1/settings", {"usageSharingEnabled": True}, token)
        call("POST", "/api/v1/usage/events", event, token, expected=201)
        assert call("POST", "/api/v1/usage/events", event, token)["duplicate"]
        call("POST", "/api/v1/usage/events", dict(event, inputTokens=1), token, expected=409)
        assert call("GET", "/api/v1/usage/aggregate", token=bob_token)["eventCount"] == 0
        call("PATCH", "/api/v1/settings", {"usageSharingEnabled": True}, bob_token)
        call("POST", "/api/v1/usage/events", dict(event, inputTokens=9), bob_token, expected=201)
        aggregate = call("GET", "/api/v1/usage/aggregate", token=token)
        assert aggregate["counts"]["inputTokens"]["knownTotal"] == 0
        assert aggregate["counts"]["outputTokens"]["knownTotal"] is None
        assert len(call("GET", "/api/v1/usage/history", token=token)["events"]) == 1
        call("PATCH", "/api/v1/profile", {"displayName": "Kiln acceptance", "bio": '<script>never executes</script>'}, token)
        html = call("GET", "/u/" + owned[0]["handle"])
        assert b"&lt;script&gt;" in html and b"<script>" not in html
        assert b"acceptance-fixture" not in html
        call("PATCH", "/api/v1/settings", {"usageSharingEnabled": False}, token)
        call("POST", "/api/v1/usage/events", event, token, expected=403)
        changed_password = secrets.token_urlsafe(24)
        owned[0]["passwords"].append(changed_password)
        changed = call("POST", "/api/v1/auth/password", {"currentPassword": owned[0]["passwords"][0], "newPassword": changed_password}, token)
        call("GET", "/api/v1/me", token=token, expected=401)
        recovered_password = secrets.token_urlsafe(24)
        owned[0]["passwords"].append(recovered_password)
        recovery = {"handle": owned[0]["handle"], "recoveryCode": alice["recoveryCode"], "newPassword": recovered_password}
        recovered = call("POST", "/api/v1/auth/recover", recovery)
        call("POST", "/api/v1/auth/recover", recovery, expected=401)
        call("GET", "/api/v1/me", token=changed["session"]["token"], expected=401)
        logged_in = call("POST", "/api/v1/auth/login", {"handle": owned[0]["handle"], "password": recovered_password})
        call("POST", "/api/v1/auth/logout", {}, logged_in["session"]["token"])
        call("GET", "/api/v1/me", token=logged_in["session"]["token"], expected=401)
        call("GET", "/api/v1/me", token=recovered["session"]["token"])
        print("PASS: public TLS, branded root/logo, auth, isolation, consent, exact retry/conflict, nullable counts, escaped stable profile, password/session revocation, one-time recovery")
    finally:
        hasher = PasswordHasher()
        db = connect(os.environ["KILN_DATABASE_URL"])
        try:
            db.execute("BEGIN")
            for record in owned:
                row = db.execute("SELECT id,password_hash FROM accounts WHERE handle=%s", (record["handle"],)).fetchone()
                if row is None:
                    continue
                if record["id"] is not None and record["id"] != row["id"]:
                    raise RuntimeError("fixture identity changed: cleanup refused")
                verified = False
                for password in record["passwords"]:
                    try:
                        verified = hasher.verify(row["password_hash"], password)
                    except Exception:
                        continue
                    if verified:
                        break
                if not verified:
                    raise RuntimeError("fixture ownership unproven: cleanup refused")
                account_id = row["id"]
                db.execute("DELETE FROM accounts WHERE id=%s AND handle=%s", (account_id, record["handle"]))
                for table in ("sessions", "usage_events"):
                    assert db.execute(f"SELECT COUNT(*) AS total FROM {table} WHERE account_id=%s", (account_id,)).fetchone()["total"] == 0
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()
        for record in owned:
            call("GET", "/u/" + record["handle"], expected=404)
        print(f"PASS: exact authenticated fixture cleanup ({len(owned)} accounts), cascaded sessions/events absent, public profiles404")


if __name__ == "__main__":
    main()
