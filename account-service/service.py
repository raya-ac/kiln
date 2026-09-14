"""Kiln account API. WSGI only; Gunicorn owns the production HTTP parser."""

from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import hmac
from html import escape
from http import HTTPStatus
import ipaddress
import json
import logging
import os
from pathlib import Path
import re
import secrets
import psycopg
import time
import unicodedata
from urllib.parse import parse_qs
import uuid

from argon2 import PasswordHasher
from argon2.exceptions import VerificationError, InvalidHashError

from db import CapacityError, SCHEMA_VERSION, check_capacity, connect, schema_version, write_transaction

PREFIX = "/api/v1"
ORIGIN = "https://kiln.raya.ac"
MAX_BODY = 8192
SESSION_SECONDS = 30 * 86400
COUNTS = {
    "inputTokens": "input_tokens",
    "outputTokens": "output_tokens",
    "cachedInputTokens": "cached_input_tokens",
    "reasoningOutputTokens": "reasoning_output_tokens",
}
HANDLE = re.compile(r"[a-z0-9_]{3,24}\Z", re.ASCII)
OPAQUE = re.compile(r"[a-zA-Z0-9_-]{16,128}\Z", re.ASCII)
IDENTIFIER = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9._:/-]{0,95}\Z", re.ASCII)
RESERVED = {"admin", "root", "support", "kiln", "api", "auth", "settings", "system"}
PROVIDERS = {"codex", "opencode"}


class APIError(Exception):
    def __init__(self, status, code, message, retry=None):
        self.status, self.code, self.message, self.retry = status, code, message, retry


def invalid():
    raise APIError(400, "invalid_request", "Request does not match the v1 contract.")


def fields(data, required=(), optional=()):
    if not isinstance(data, dict) or set(data) - set(required) - set(optional):
        invalid()
    if set(required) - set(data):
        invalid()


def bounded_text(value, maximum, minimum=0):
    if not isinstance(value, str) or not minimum <= len(value) <= maximum:
        invalid()
    if any(unicodedata.category(c).startswith("C") for c in value):
        invalid()
    return value


def handle(value):
    if not isinstance(value, str) or not HANDLE.fullmatch(value) or value in RESERVED:
        invalid()
    return value


def password(value):
    bounded_text(value, 128, 12)
    if len(value.encode("utf-8")) > 128:
        invalid()
    return value


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def iso(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            invalid()
        result[key] = value
    return result


class Service:
    def __init__(self, database, *, clock=time.time, hasher=None, session_seconds=SESSION_SECONDS,
                 event_quota=100000):
        self.database = str(database)
        self.clock = clock
        self.session_seconds = session_seconds
        self.event_quota = event_quota
        self.hasher = hasher or PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4)
        self.dummy_hash = self.hasher.hash(secrets.token_urlsafe(32))
        with self.connection() as db:
            if schema_version(db) != SCHEMA_VERSION:
                raise RuntimeError("schema mismatch: explicit migration required")

    @contextmanager
    def connection(self):
        db = connect(self.database)
        try:
            yield db
        finally:
            db.close()

    @contextmanager
    def transaction(self):
        with self.connection() as db:
            with write_transaction(db):
                yield db

    def limit(self, scopes):
        now = int(self.clock())
        denied = 0
        with self.transaction() as db:
            db.execute("DELETE FROM rate_limits WHERE expires_at <= %s", (now,))
            for scope, maximum, seconds in scopes:
                key = digest(scope)
                row = db.execute("SELECT * FROM rate_limits WHERE key=%s", (key,)).fetchone()
                if row is None:
                    if db.execute("SELECT COUNT(*) AS total FROM rate_limits").fetchone()["total"] >= 10000:
                        denied = max(denied, 60)
                        continue
                    db.execute("INSERT INTO rate_limits VALUES (%s,%s,1,%s)", (key, now, now + seconds))
                else:
                    if row["hits"] >= maximum:
                        denied = max(denied, row["expires_at"] - now)
                    db.execute("UPDATE rate_limits SET hits=LEAST(hits+1,1000000) WHERE key=%s", (key,))
        if denied:
            raise APIError(429, "rate_limited", "Too many requests. Try again later.", denied)

    def account_json(self, account):
        return {"id": account["id"], "handle": account["handle"],
                "displayName": account["display_name"], "bio": account["bio"],
                "profileURL": ORIGIN + "/u/" + account["handle"],
                "usageSharingEnabled": bool(account["usage_sharing_enabled"]),
                "createdAt": account["created_at"]}

    def authenticate(self, db, token):
        row = db.execute("SELECT a.* FROM accounts a JOIN sessions s ON s.account_id=a.id "
                         "WHERE s.token_hash=%s AND s.expires_at>%s", (digest(token), int(self.clock()))).fetchone()
        if row is None:
            raise APIError(401, "unauthorized", "A valid session is required.")
        return row

    def new_session(self, db, account_id):
        now = int(self.clock())
        db.execute("DELETE FROM sessions WHERE expires_at <= %s", (now,))
        # Retain at most ten devices; a new login evicts the oldest one.
        old = db.execute("SELECT token_hash FROM sessions WHERE account_id=%s "
                         "ORDER BY created_at DESC, sequence DESC OFFSET 9", (account_id,)).fetchall()
        for row in old:
            db.execute("DELETE FROM sessions WHERE token_hash=%s", (row["token_hash"],))
        token = secrets.token_urlsafe(32)
        db.execute("INSERT INTO sessions (token_hash,account_id,created_at,expires_at) VALUES (%s,%s,%s,%s)", (digest(token), account_id, now, now + self.session_seconds))
        return {"token": token, "expiresAt": iso(now + self.session_seconds)}

    def verify(self, encoded, candidate):
        try:
            return self.hasher.verify(encoded, candidate)
        except (VerificationError, InvalidHashError):
            return False

    def auth(self, route, data, token, peer):
        if route == "/auth/logout":
            fields(data)
            with self.transaction() as db:
                db.execute("DELETE FROM sessions WHERE token_hash=%s", (digest(token),))
            return 200, {"ok": True}
        if route == "/auth/register":
            fields(data, ("handle", "password"), ("displayName",))
            name = handle(data["handle"])
            secret = password(data["password"])
            display = bounded_text(data.get("displayName", name), 80, 1)
            self.limit([("register-ip:" + peer, 5, 3600), ("register-global", 100, 3600)])
            encoded = self.hasher.hash(secret)
            recovery = secrets.token_urlsafe(32)
            with self.transaction() as db:
                check_capacity(db)
                account_id = str(uuid.uuid4())
                try:
                    db.execute("INSERT INTO accounts (id,handle,password_hash,recovery_hash,display_name,created_at) "
                               "VALUES (%s,%s,%s,%s,%s,%s)", (account_id, name, encoded, digest(recovery), display, iso(self.clock())))
                except psycopg.errors.UniqueViolation:
                    raise APIError(409, "handle_unavailable", "That public handle is unavailable.") from None
                session = self.new_session(db, account_id)
                row = db.execute("SELECT * FROM accounts WHERE id=%s", (account_id,)).fetchone()
            return 201, {"account": self.account_json(row), "session": session, "recoveryCode": recovery}
        if route in ("/auth/login", "/auth/recover"):
            recover = route == "/auth/recover"
            fields(data, ("handle", "recoveryCode", "newPassword") if recover else ("handle", "password"))
            name = handle(data["handle"])
            secret = password(data["newPassword"] if recover else data["password"])
            if recover:
                bounded_text(data["recoveryCode"], 128, 1)
            self.limit([("auth-ip:" + peer, 30, 900), ("auth-handle:" + name, 10, 900),
                        ("auth-global", 300, 60)])
            with self.connection() as db:
                row = db.execute("SELECT * FROM accounts WHERE handle=%s", (name,)).fetchone()
            if recover:
                # Same expensive work on known/unknown handles and wrong/valid codes.
                encoded = self.hasher.hash(secret)
                valid = hmac.compare_digest(digest(data["recoveryCode"]), row["recovery_hash"] if row else "0" * 64)
            else:
                valid = self.verify(row["password_hash"] if row else self.dummy_hash, secret)
            if not valid or row is None:
                raise APIError(401, "invalid_credentials", "Invalid credentials.")
            with self.transaction() as db:
                current = db.execute("SELECT * FROM accounts WHERE id=%s", (row["id"],)).fetchone()
                if current is None or current["password_hash"] != row["password_hash"] or current["recovery_hash"] != row["recovery_hash"]:
                    raise APIError(401, "invalid_credentials", "Invalid credentials.")
                result = {}
                if recover:
                    recovery = secrets.token_urlsafe(32)
                    db.execute("UPDATE accounts SET password_hash=%s,recovery_hash=%s WHERE id=%s",
                               (encoded, digest(recovery), row["id"]))
                    db.execute("DELETE FROM sessions WHERE account_id=%s", (row["id"],))
                    result["recoveryCode"] = recovery
                result.update(account=self.account_json(current), session=self.new_session(db, row["id"]))
            return 200, result
        if route == "/auth/password":
            fields(data, ("currentPassword", "newPassword"))
            old, new = password(data["currentPassword"]), password(data["newPassword"])
            with self.connection() as db:
                row = self.authenticate(db, token)
            self.limit([("password-account:" + row["id"], 10, 900)])
            if not self.verify(row["password_hash"], old):
                raise APIError(401, "invalid_credentials", "Invalid credentials.")
            encoded = self.hasher.hash(new)
            with self.transaction() as db:
                current = self.authenticate(db, token)
                if current["password_hash"] != row["password_hash"]:
                    raise APIError(401, "invalid_credentials", "Invalid credentials.")
                db.execute("UPDATE accounts SET password_hash=%s WHERE id=%s", (encoded, row["id"]))
                db.execute("DELETE FROM sessions WHERE account_id=%s", (row["id"],))
                session = self.new_session(db, row["id"])
            return 200, {"account": self.account_json(current), "session": session}
        raise APIError(404, "not_found", "Not found.")

    def normalize_event(self, data):
        fields(data, ("eventId", "sessionId", "provider", "model", "timestamp"), COUNTS)
        for key in ("eventId", "sessionId"):
            if not isinstance(data[key], str) or not OPAQUE.fullmatch(data[key]):
                invalid()
        for key in ("provider", "model"):
            if not isinstance(data[key], str) or not IDENTIFIER.fullmatch(data[key]):
                invalid()
        if data["provider"] not in PROVIDERS:
            invalid()
        timestamp = data["timestamp"]
        if not isinstance(timestamp, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z", timestamp):
            invalid()
        try:
            parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00")).timestamp()
        except ValueError:
            invalid()
        if parsed < 1577836800 or parsed > self.clock() + 300:
            invalid()
        event = {k: data[k] for k in ("eventId", "sessionId", "provider", "model")}
        event["timestamp"] = iso(parsed)
        for key in COUNTS:
            value = data.get(key)
            if value is not None and (type(value) is not int or not 0 <= value <= 1_000_000_000):
                invalid()
            event[key] = value
        return event

    def private(self, method, route, data, token, query):
        with self.connection() as db:
            account = self.authenticate(db, token)
        self.limit([("account:" + account["id"], 300, 60)])
        if method == "GET" and route == "/me":
            return 200, {"account": self.account_json(account)}
        if method == "PATCH" and route in ("/profile", "/settings"):
            if route == "/profile":
                fields(data, (), ("displayName", "bio"))
                if not data:
                    invalid()
                updates = {}
                if "displayName" in data:
                    updates["display_name"] = bounded_text(data["displayName"], 80, 1)
                if "bio" in data:
                    updates["bio"] = bounded_text(data["bio"], 500)
            else:
                fields(data, ("usageSharingEnabled",))
                if type(data["usageSharingEnabled"]) is not bool:
                    invalid()
                updates = {"usage_sharing_enabled": int(data["usageSharingEnabled"])}
            with self.transaction() as db:
                self.authenticate(db, token)
                if route == "/profile":
                    check_capacity(db)
                try:
                    db.execute("UPDATE accounts SET " + ",".join(k + "=%s" for k in updates) + " WHERE id=%s",
                               (*updates.values(), account["id"]))
                except psycopg.errors.UniqueViolation:
                    raise APIError(409, "handle_unavailable", "That public handle is unavailable.") from None
                account = db.execute("SELECT * FROM accounts WHERE id=%s", (account["id"],)).fetchone()
            return 200, {"account": self.account_json(account)}
        if method == "POST" and route == "/usage/events":
            event = self.normalize_event(data)
            payload = json.dumps(event, sort_keys=True, separators=(",", ":"))
            with self.transaction() as db:
                account = self.authenticate(db, token)
                if not account["usage_sharing_enabled"]:
                    raise APIError(403, "usage_sharing_disabled", "Enable private usage sharing first.")
                previous = db.execute("SELECT payload FROM usage_events WHERE account_id=%s AND event_id=%s",
                                      (account["id"], event["eventId"])).fetchone()
                if previous:
                    if previous["payload"] != payload:
                        raise APIError(409, "event_conflict", "This event ID already has a different payload.")
                    return 200, {"eventId": event["eventId"], "duplicate": True}
                retained = db.execute("SELECT COUNT(*) AS total FROM usage_events WHERE account_id=%s", (account["id"],)).fetchone()["total"]
                if retained >= self.event_quota:
                    raise APIError(409, "usage_quota_exceeded", "Account usage storage is full. Existing history is retained.")
                check_capacity(db)
                db.execute("INSERT INTO usage_events (account_id,event_id,payload,timestamp," + ",".join(COUNTS.values()) +
                           ") VALUES (%s,%s,%s,%s,%s,%s,%s,%s)", (account["id"], event["eventId"], payload, event["timestamp"],
                                                        *(event[k] for k in COUNTS)))
            return 201, {"eventId": event["eventId"], "duplicate": False}
        if method == "GET" and route == "/usage/history":
            if set(query) - {"limit", "before"}:
                invalid()
            limit = self.query_integer(query, "limit", 50, 1, 100)
            before = self.query_integer(query, "before", 9223372036854775807, 1, 9223372036854775807)
            with self.connection() as db:
                rows = db.execute("SELECT sequence,payload FROM usage_events WHERE account_id=%s AND sequence<%s "
                                  "ORDER BY sequence DESC LIMIT %s", (account["id"], before, limit + 1)).fetchall()
            events = [dict(json.loads(r["payload"]), sequence=r["sequence"]) for r in rows[:limit]]
            return 200, {"events": events, "nextBefore": events[-1]["sequence"] if len(rows) > limit else None}
        if method == "GET" and route == "/usage/aggregate":
            columns = ",".join("SUM(" + c + ") AS " + c + ",COUNT(" + c + ") AS n_" + c for c in COUNTS.values())
            with self.connection() as db:
                row = db.execute("SELECT COUNT(*) AS total," + columns + " FROM usage_events WHERE account_id=%s",
                                 (account["id"],)).fetchone()
            return 200, {"eventCount": row["total"], "counts": {
                k: {"knownTotal": row[c], "knownEvents": row["n_" + c], "unknownEvents": row["total"] - row["n_" + c]}
                for k, c in COUNTS.items()}}
        raise APIError(404, "not_found", "Not found.")

    @staticmethod
    def query_integer(query, key, default, minimum, maximum):
        if key not in query:
            return default
        value = query[key]
        if len(value) != 1 or not re.fullmatch(r"[0-9]{1,19}", value[0]):
            invalid()
        number = int(value[0])
        if not minimum <= number <= maximum:
            invalid()
        return number

    def profile_html(self, name):
        if not HANDLE.fullmatch(name):
            raise APIError(404, "not_found", "Not found.")
        with self.connection() as db:
            row = db.execute("SELECT handle,display_name,bio FROM accounts WHERE handle=%s", (name,)).fetchone()
        if row is None:
            raise APIError(404, "not_found", "Not found.")
        return ("<!doctype html><html lang=\"en\"><meta charset=\"utf-8\">"
                "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
                "<meta name=\"robots\" content=\"noindex,nofollow\">"
                "<title>" + escape(row["display_name"]) + " | Kiln</title>"
                "<link rel=\"stylesheet\" href=\"/profile.css\">"
                "<link rel=\"icon\" href=\"/logo.png\">"
                "<body><header><a href=\"/\"><img src=\"/logo.png\" alt=\"\" width=\"32\" height=\"32\">Kiln</a></header><main>"
                "<h1>" + escape(row["display_name"]) + "</h1><p class=\"handle\">@" + escape(row["handle"]) +
                "</p><p class=\"bio\">" + escape(row["bio"]) + "</p></main></body></html>")

    def __call__(self, environ, start_response):
        content_type = "application/json; charset=utf-8"
        extra_headers = []
        try:
            method, path = environ.get("REQUEST_METHOD", ""), environ.get("PATH_INFO", "")
            if len(path) > 256 or len(environ.get("QUERY_STRING", "")) > 256:
                invalid()
            # Forwarding headers are deliberately ignored: the proxy peer gets a
            # conservative shared budget until a verified trusted-IP path exists.
            try:
                peer = str(ipaddress.ip_address(environ.get("REMOTE_ADDR", "127.0.0.1")))
            except ValueError:
                peer = "unknown"
            if not (method == "GET" and path == "/healthz"):
                self.limit([("request-ip:" + peer, 600, 60)])
            if method not in ("GET", "POST", "PATCH"):
                raise APIError(405, "method_not_allowed", "Method not allowed.")
            if environ.get("HTTP_ORIGIN") not in (None, "", ORIGIN):
                raise APIError(403, "origin_forbidden", "Origin is not permitted.")
            query = parse_qs(environ.get("QUERY_STRING", ""), keep_blank_values=True, max_num_fields=8)
            if query and (method != "GET" or path != PREFIX + "/usage/history"):
                invalid()
            if method == "GET" and path == "/healthz":
                with self.connection() as db:
                    if schema_version(db) != SCHEMA_VERSION:
                        raise APIError(503, "unavailable", "Service temporarily unavailable.")
                status, result = 200, {"ok": True, "apiVersion": "v1", "schemaVersion": SCHEMA_VERSION, "storage": "postgresql"}
            elif method == "GET" and path == "/":
                status, result = 200, HOME_HTML
                content_type = "text/html; charset=utf-8"
            elif method == "GET" and path == "/logo.png":
                status, result = 200, (Path(__file__).parent / "static/logo.png").read_bytes()
                content_type = "image/png"
            elif method == "GET" and path == "/profile.css":
                status, result = 200, PROFILE_CSS
                content_type = "text/css; charset=utf-8"
            elif method == "GET" and path.startswith("/u/"):
                status, result = 200, self.profile_html(path[3:])
                content_type = "text/html; charset=utf-8"
            elif path.startswith(PREFIX + "/"):
                data = {}
                if method in ("POST", "PATCH"):
                    if environ.get("CONTENT_TYPE", "").lower() not in ("application/json", "application/json; charset=utf-8"):
                        raise APIError(415, "unsupported_media_type", "Use application/json.")
                    length = environ.get("CONTENT_LENGTH", "")
                    if not re.fullmatch(r"[0-9]{1,6}", length):
                        invalid()
                    if int(length) > MAX_BODY:
                        raise APIError(413, "request_too_large", "Request is too large.")
                    raw = environ["wsgi.input"].read(int(length))
                    if len(raw) != int(length):
                        invalid()
                    data = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                                      parse_constant=lambda _: invalid())
                    fields(data, (), data.keys() if isinstance(data, dict) else ())
                auth = environ.get("HTTP_AUTHORIZATION", "")
                token = auth[7:] if auth.startswith("Bearer ") and OPAQUE.fullmatch(auth[7:]) else ""
                route = path[len(PREFIX):]
                if route.startswith("/auth/"):
                    if method != "POST":
                        raise APIError(405, "method_not_allowed", "Method not allowed.")
                    status, result = self.auth(route, data, token, peer)
                else:
                    status, result = self.private(method, route, data, token, query)
            else:
                raise APIError(404, "not_found", "Not found.")
        except APIError as exc:
            status, result = exc.status, {"error": {"code": exc.code, "message": exc.message}}
            if exc.retry:
                extra_headers.append(("Retry-After", str(exc.retry)))
        except (ValueError, UnicodeError, RecursionError):
            status, result = 400, {"error": {"code": "invalid_request", "message": "Request does not match the v1 contract."}}
        except CapacityError:
            status, result = 503, {"error": {"code": "storage_capacity", "message": "Storage capacity reached. Writes are paused."}}
            extra_headers.append(("Retry-After", "3600"))
        except psycopg.Error as exc:
            if isinstance(exc, psycopg.errors.DiskFull):
                status, result = 503, {"error": {"code": "storage_capacity", "message": "Storage capacity reached. Writes are paused."}}
                extra_headers.append(("Retry-After", "3600"))
            else:
                status, result = 503, {"error": {"code": "unavailable", "message": "Service temporarily unavailable."}}
                extra_headers.append(("Retry-After", "5"))
        except Exception:
            # Never include request bodies, credentials, paths, or SQL values in logs.
            logging.error("account service internal error")
            status, result = 500, {"error": {"code": "internal_error", "message": "Service error."}}
        if isinstance(result, dict):
            content_type = "application/json; charset=utf-8"
            body = json.dumps(result, ensure_ascii=True, separators=(",", ":")).encode()
        elif isinstance(result, bytes):
            body = result
        else:
            body = result.encode("utf-8")
        headers = [("Content-Type", content_type), ("Content-Length", str(len(body))),
                   ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"),
                   ("Referrer-Policy", "no-referrer"), ("X-Frame-Options", "DENY"),
                   ("Content-Security-Policy", "default-src 'none'; style-src 'self'; img-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"),
                   ("Permissions-Policy", "camera=(), microphone=(), geolocation=()")]
        start_response(str(status) + " " + HTTPStatus(status).phrase, headers + extra_headers)
        return [body]


PROFILE_CSS = """*{box-sizing:border-box}body{margin:0;background:#fafafa;color:#242424;
font:18px/1.6 system-ui,sans-serif;letter-spacing:0}header{border-bottom:1px solid #ddd;
padding:20px 6%}a{color:#295d48;text-decoration:none;font-weight:650}header a{display:inline-flex;
align-items:center;gap:12px}main{max-width:720px;
margin:64px auto;padding:0 24px}h1{font-size:36px;line-height:1.2;margin:0;overflow-wrap:anywhere}
.handle{color:#666;margin:12px 0 32px}.bio{white-space:pre-wrap;overflow-wrap:anywhere}
.brand{display:block;width:96px;height:96px;margin:0 0 28px}.entry p{max-width:44ch}
@media(max-width:480px){main{margin:40px auto}h1{font-size:28px}}"""

HOME_HTML = """<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Kiln</title>
<link rel="stylesheet" href="/profile.css"><link rel="icon" href="/logo.png">
<body><header><a href="/"><img src="/logo.png" alt="" width="32" height="32">Kiln</a></header>
<main class="entry"><img class="brand" src="/logo.png" alt="Kiln flame" width="96" height="96">
<h1>Kiln</h1><p>Account sign-in is available in the macOS app.</p>
<p><a href="https://github.com/raya-ac/kiln/releases">Kiln for macOS</a></p>
</main></body></html>"""


def create_app():
    dsn = os.environ.get("KILN_DATABASE_URL", "")
    if not dsn:
        raise RuntimeError("KILN_DATABASE_URL is required; PostgreSQL only")
    return Service(dsn)
