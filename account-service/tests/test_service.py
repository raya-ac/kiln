import io
import json
import os
from pathlib import Path
import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo
import tempfile
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

from argon2 import PasswordHasher

from db import backup, connect, migrate, schema_version, pg_environment
from service import COUNTS, Service

ROOT = Path(__file__).resolve().parents[1]
NOW = 1789365600
PASSWORD = "a long private password"
NEW_PASSWORD = "another long private password"


def request(app, method, path, data=None, token=None, peer="192.0.2.1", **extra):
    raw = json.dumps(data if data is not None else {}).encode()
    path, _, query = path.partition("?")
    env = {"REQUEST_METHOD": method, "PATH_INFO": path, "QUERY_STRING": query,
           "CONTENT_TYPE": "application/json", "CONTENT_LENGTH": str(len(raw)),
           "REMOTE_ADDR": peer, "wsgi.input": io.BytesIO(raw)}
    if token:
        env["HTTP_AUTHORIZATION"] = "Bearer " + token
    env.update(extra)
    receipt = {}

    def start(status, headers):
        receipt.update(status=int(status[:3]), headers=dict(headers))

    raw = b"".join(app(env, start))
    body = json.loads(raw) if receipt["headers"]["Content-Type"].startswith("application/json") else raw.decode()
    return receipt["status"], body, receipt["headers"]


@unittest.skipUnless(os.environ.get("KILN_TEST_DATABASE_URL"), "real disposable PostgreSQL DSN required")
class ServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / ".test-tmp").mkdir(exist_ok=True)
        cls.fast_hasher = PasswordHasher(time_cost=1, memory_cost=1024, parallelism=1)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT / ".test-tmp")
        self.addCleanup(self.tmp.cleanup)
        self.base_dsn = os.environ["KILN_TEST_DATABASE_URL"]
        self.schema = "baseline_" + uuid.uuid4().hex
        with connect(self.base_dsn) as db:
            db.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(self.schema)))
        self.addCleanup(self.drop_schema)
        self.path = make_conninfo(self.base_dsn, options="-csearch_path=" + self.schema)
        migrate(self.path)
        self.now = NOW
        self.app = Service(self.path, clock=lambda: self.now, hasher=self.fast_hasher)
        self.alice = self.register("alice")
        self.token = self.alice["session"]["token"]

    def drop_schema(self):
        with connect(self.base_dsn) as db:
            db.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(self.schema)))

    def call(self, method, route, data=None, token=None, **kwargs):
        return request(self.app, method, "/api/v1" + route, data, token, **kwargs)

    def register(self, name, **kwargs):
        status, body, _ = self.call("POST", "/auth/register", {"handle": name, "password": PASSWORD}, **kwargs)
        self.assertEqual(status, 201, body)
        return body

    def consent(self, token=None, enabled=True):
        status, body, _ = self.call("PATCH", "/settings", {"usageSharingEnabled": enabled}, token or self.token)
        self.assertEqual(status, 200, body)

    def event(self, **kwargs):
        return {"eventId": "event-00000000000001", "sessionId": "session-00000000001",
                "provider": "codex", "model": "gpt-5.5", "timestamp": "2026-09-14T06:00:00Z",
                "inputTokens": 42, "outputTokens": 7, **kwargs}

    def ingest(self, data=None, token=None):
        return self.call("POST", "/usage/events", data or self.event(), token or self.token)

    def test_registration_private_defaults_and_hashed_secrets(self):
        self.assertFalse(self.alice["account"]["usageSharingEnabled"])
        with connect(self.path) as db:
            account = dict(db.execute("SELECT * FROM accounts").fetchone())
            session = dict(db.execute("SELECT * FROM sessions").fetchone())
        self.assertTrue(account["password_hash"].startswith("$argon2id$"))
        stored = json.dumps([account, session])
        for secret in (PASSWORD, self.token, self.alice["recoveryCode"]):
            self.assertNotIn(secret, stored)
        with connect(self.path) as db:
            self.assertGreaterEqual(db.info.server_version, 160000)

    def test_production_argon2_parameters(self):
        production = Service(self.path)
        self.assertEqual(production.hasher.memory_cost, 65536)
        self.assertEqual(production.hasher.time_cost, 3)
        self.assertTrue(production.verify(production.hasher.hash(PASSWORD), PASSWORD))

    def test_login_and_me_isolation(self):
        bob = self.register("bobby")
        status, body, _ = self.call("POST", "/auth/login", {"handle": "alice", "password": PASSWORD})
        self.assertEqual(status, 200)
        _, me, headers = self.call("GET", "/me", token=bob["session"]["token"])
        self.assertEqual(me["account"]["id"], bob["account"]["id"])
        self.assertNotEqual(me["account"]["id"], body["account"]["id"])
        self.assertEqual(headers["Cache-Control"], "no-store")

    def test_unknown_and_wrong_credentials_same_response_and_work(self):
        with patch.object(self.app, "verify", wraps=self.app.verify) as verify:
            a = self.call("POST", "/auth/login", {"handle": "alice", "password": NEW_PASSWORD})
            b = self.call("POST", "/auth/login", {"handle": "nobody", "password": NEW_PASSWORD})
        self.assertEqual(a, b)
        self.assertEqual(verify.call_count, 2)

    def test_logout_idempotent_and_no_effect_on_other_sessions(self):
        _, login, _ = self.call("POST", "/auth/login", {"handle": "alice", "password": PASSWORD})
        for _ in range(2):
            self.assertEqual(self.call("POST", "/auth/logout", {}, self.token)[0], 200)
        self.assertEqual(self.call("GET", "/me", token=self.token)[0], 401)
        self.assertEqual(self.call("GET", "/me", token=login["session"]["token"])[0], 200)

    def test_expiry_and_missing_token(self):
        self.assertEqual(self.call("GET", "/me")[0], 401)
        self.now += 30 * 86400
        self.assertEqual(self.call("GET", "/me", token=self.token)[0], 401)

    def test_password_change_revokes_all_sessions(self):
        _, login, _ = self.call("POST", "/auth/login", {"handle": "alice", "password": PASSWORD})
        code = self.alice["recoveryCode"]
        status, changed, _ = self.call("POST", "/auth/password", {"currentPassword": PASSWORD, "newPassword": NEW_PASSWORD}, self.token)
        self.assertEqual(status, 200)
        for token in (self.token, login["session"]["token"]):
            self.assertEqual(self.call("GET", "/me", token=token)[0], 401)
        self.assertEqual(self.call("GET", "/me", token=changed["session"]["token"])[0], 200)
        self.assertEqual(self.call("POST", "/auth/login", {"handle": "alice", "password": PASSWORD})[0], 401)
        self.assertEqual(self.call("POST", "/auth/recover", {"handle": "alice", "recoveryCode": code, "newPassword": PASSWORD})[0], 200)

    def test_wrong_password_cannot_change_password(self):
        self.assertEqual(self.call("POST", "/auth/password", {"currentPassword": NEW_PASSWORD, "newPassword": NEW_PASSWORD}, self.token)[0], 401)
        self.assertEqual(self.call("GET", "/me", token=self.token)[0], 200)

    def test_recovery_rotates_code_and_revokes_sessions(self):
        data = {"handle": "alice", "recoveryCode": self.alice["recoveryCode"], "newPassword": NEW_PASSWORD}
        status, result, _ = self.call("POST", "/auth/recover", data)
        self.assertEqual(status, 200)
        self.assertNotEqual(result["recoveryCode"], data["recoveryCode"])
        self.assertEqual(self.call("POST", "/auth/recover", data)[0], 401)
        self.assertEqual(self.call("GET", "/me", token=self.token)[0], 401)
        self.assertEqual(self.call("GET", "/me", token=result["session"]["token"])[0], 200)

    def test_recovery_unknown_and_wrong_code_constant_response(self):
        with patch.object(self.app, "hasher", wraps=self.fast_hasher) as hasher:
            a = self.call("POST", "/auth/recover", {"handle": "alice", "recoveryCode": "wrong", "newPassword": NEW_PASSWORD})
            b = self.call("POST", "/auth/recover", {"handle": "nobody", "recoveryCode": "wrong", "newPassword": NEW_PASSWORD})
            self.assertEqual(hasher.hash.call_count, 2)
        self.assertEqual(a, b)

    def test_concurrent_recovery_one_winner(self):
        data = {"handle": "alice", "recoveryCode": self.alice["recoveryCode"], "newPassword": NEW_PASSWORD}
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.call("POST", "/auth/recover", data), range(2)))
        self.assertEqual(sorted(r[0] for r in results), [200, 401])

    def test_concurrent_login_cannot_bypass_password_revocation(self):
        original = self.app.verify

        def verify_and_change(encoded, candidate):
            result = original(encoded, candidate)
            with connect(self.path) as db:
                db.execute("UPDATE accounts SET password_hash=%s WHERE handle='alice'", (self.fast_hasher.hash(NEW_PASSWORD),))
            return result

        with patch.object(self.app, "verify", side_effect=verify_and_change):
            self.assertEqual(self.call("POST", "/auth/login", {"handle": "alice", "password": PASSWORD})[0], 401)

    def test_handle_uniqueness_and_immutability(self):
        self.assertEqual(self.call("POST", "/auth/register", {"handle": "alice", "password": PASSWORD})[0], 409)
        self.assertEqual(self.call("POST", "/auth/register", {"handle": "Alice", "password": PASSWORD})[0], 400)
        bob = self.register("bobby")
        self.assertEqual(self.call("PATCH", "/profile", {"handle": "bobby"}, self.token)[0], 400)
        self.assertEqual(self.call("PATCH", "/profile", {"handle": "alice_new"}, self.token)[0], 400)
        status, updated, _ = self.call("PATCH", "/profile", {"displayName": "A new name"}, self.token)
        self.assertEqual(status, 200)
        self.assertEqual(updated["account"]["id"], self.alice["account"]["id"])
        self.assertEqual(updated["account"]["profileURL"], "https://kiln.raya.ac/u/alice")
        self.assertEqual(request(self.app, "GET", "/u/alice")[0], 200)
        self.assertEqual(bob["account"]["handle"], "bobby")

    def test_root_brand_entry(self):
        status, html, _ = request(self.app, "GET", "/")
        self.assertEqual(status, 200)
        self.assertIn('<h1>Kiln</h1>', html)
        self.assertIn('src="/logo.png"', html)
        self.assertIn("macOS app", html)

    def test_public_page_escapes_content_and_never_exposes_usage(self):
        self.consent()
        self.ingest()
        malicious = '<script>alert("x")</script>'
        self.call("PATCH", "/profile", {"displayName": malicious, "bio": "<img src=x onerror=alert(1)>"}, self.token)
        status, html, headers = request(self.app, "GET", "/u/alice")
        self.assertEqual(status, 200)
        self.assertNotIn("<script>", html)
        self.assertIn("&lt;script&gt;", html)
        for forbidden in (self.token, self.alice["account"]["id"], "inputTokens", "gpt-5.5", "usageSharingEnabled"):
            self.assertNotIn(forbidden, html)
        self.assertIn("default-src 'none'", headers["Content-Security-Policy"])

    def test_sql_and_path_injection(self):
        for name in ("alice' OR 1=1--", "../alice", "admin", "alice\n"):
            self.assertEqual(self.call("POST", "/auth/login", {"handle": name, "password": PASSWORD})[0], 400)
            self.assertEqual(request(self.app, "GET", "/u/" + name)[0], 404)
        self.call("PATCH", "/profile", {"bio": "'); DROP TABLE accounts; --"}, self.token)
        self.assertEqual(self.call("GET", "/me", token=self.token)[0], 200)

    def test_usage_consent_off_and_revocation_blocks_retry(self):
        self.assertEqual(self.ingest()[0], 403)
        self.consent()
        self.assertEqual(self.ingest()[0], 201)
        self.consent(enabled=False)
        self.assertEqual(self.ingest()[0], 403)
        status, history, _ = self.call("GET", "/usage/history", token=self.token)
        self.assertEqual(status, 200)
        self.assertEqual(len(history["events"]), 1)

    def test_idempotency_and_duplicate_mismatch(self):
        self.consent()
        self.assertEqual(self.ingest()[0], 201)
        status, body, _ = self.ingest(self.event(cachedInputTokens=None))
        self.assertEqual((status, body["duplicate"]), (200, True))
        for changed in (self.event(inputTokens=43), self.event(outputTokens=None), self.event(model="other")):
            self.assertEqual(self.ingest(changed)[0], 409)
        _, aggregate, _ = self.call("GET", "/usage/aggregate", token=self.token)
        self.assertEqual(aggregate["eventCount"], 1)

    def test_concurrent_ingest_exactly_once(self):
        self.consent()
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.ingest(), range(8)))
        self.assertEqual(sorted(r[0] for r in results), [200] * 7 + [201])

    def test_retained_quota_keeps_history_and_allows_exact_retries(self):
        self.app.event_quota = 1
        self.consent()
        self.assertEqual(self.ingest()[0], 201)
        self.assertEqual(self.ingest()[0], 200)
        status, body, _ = self.ingest(self.event(eventId="event-00000000000002"))
        self.assertEqual((status, body["error"]["code"]), (409, "usage_quota_exceeded"))
        _, history, _ = self.call("GET", "/usage/history", token=self.token)
        self.assertEqual(len(history["events"]), 1)

    def test_concurrent_quota_cannot_overflow(self):
        self.app.event_quota = 1
        self.consent()
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda i: self.ingest(self.event(eventId=f"event-{i:016d}")), range(2)))
        self.assertEqual(sorted(r[0] for r in results), [201, 409])

    def test_postgres_capacity_admission_and_readback(self):
        self.consent()
        self.ingest()
        with patch.dict("os.environ", {"KILN_DATABASE_MAX_BYTES": "1048576"}):
            status, body, _ = self.ingest(self.event(eventId="event-00000000000002"))
            self.assertEqual((status, body["error"]["code"]), (503, "storage_capacity"))
            self.assertEqual(self.ingest()[0], 200)
            self.assertEqual(self.call("GET", "/me", token=self.token)[0], 200)
            self.assertEqual(self.call("GET", "/usage/history", token=self.token)[0], 200)
            self.assertEqual(request(self.app, "GET", "/healthz")[0], 200)
            self.consent(enabled=False)
            self.assertEqual(self.ingest()[0], 403)
            self.assertEqual(self.call("POST", "/auth/logout", {}, self.token)[0], 200)
            self.assertEqual(self.call("GET", "/me", token=self.token)[0], 401)

    def test_capacity_does_not_bypass_auth_limits_or_revocation(self):
        with patch.dict("os.environ", {"KILN_DATABASE_MAX_BYTES": "1048576"}):
            status, body, _ = self.call("POST", "/auth/password", {"currentPassword": PASSWORD, "newPassword": NEW_PASSWORD}, self.token)
            self.assertEqual(status, 200)
            self.assertEqual(self.call("GET", "/me", token=self.token)[0], 401)
            self.assertEqual(self.call("GET", "/me", token=body["session"]["token"])[0], 200)
            for _ in range(10):
                self.assertEqual(self.call("POST", "/auth/login", {"handle": "nobody", "password": PASSWORD})[0], 401)
            self.assertEqual(self.call("POST", "/auth/login", {"handle": "nobody", "password": PASSWORD})[0], 429)

    def test_capacity_error_sanitized_no_silent_data_deletion(self):
        from db import CapacityError
        with patch.object(self.app, "limit", side_effect=CapacityError("private-path")):
            status, body, headers = self.call("GET", "/me", token=self.token)
        self.assertEqual((status, body["error"]["code"]), (503, "storage_capacity"))
        self.assertNotIn("private-path", json.dumps(body))
        self.assertEqual(headers["Retry-After"], "3600")
        self.assertEqual(self.call("GET", "/me", token=self.token)[0], 200)

    def test_usage_account_isolation_and_same_event_id(self):
        bob = self.register("bobby")
        bob_token = bob["session"]["token"]
        self.consent()
        self.consent(bob_token)
        self.ingest()
        self.assertEqual(self.ingest(self.event(inputTokens=99), bob_token)[0], 201)
        _, aggregate, _ = self.call("GET", "/usage/aggregate", token=bob_token)
        self.assertEqual(aggregate["counts"]["inputTokens"]["knownTotal"], 99)
        _, history, _ = self.call("GET", "/usage/history?before=999", token=self.token)
        self.assertEqual(len(history["events"]), 1)
        self.assertEqual(history["events"][0]["inputTokens"], 42)
        self.assertEqual(self.ingest(self.event(accountId=bob["account"]["id"]))[0], 400)

    def test_unknown_usage_never_fabricates_zero(self):
        self.consent()
        _, empty, _ = self.call("GET", "/usage/aggregate", token=self.token)
        self.assertEqual(empty["eventCount"], 0)
        self.assertTrue(all(c["knownTotal"] is None for c in empty["counts"].values()))
        self.ingest(self.event(**dict.fromkeys(COUNTS)))
        self.ingest(self.event(eventId="event-00000000000002", inputTokens=0, outputTokens=None))
        _, result, _ = self.call("GET", "/usage/aggregate", token=self.token)
        self.assertEqual(result["counts"]["inputTokens"], {"knownTotal": 0, "knownEvents": 1, "unknownEvents": 1})
        self.assertEqual(result["counts"]["outputTokens"], {"knownTotal": None, "knownEvents": 0, "unknownEvents": 2})
        self.assertNotIn("cost", json.dumps(result))

    def test_partial_counts_subsets_preserved_without_summing(self):
        self.consent()
        self.ingest(self.event(inputTokens=None, outputTokens=None, cachedInputTokens=3, reasoningOutputTokens=8))
        _, result, _ = self.call("GET", "/usage/history", token=self.token)
        event = result["events"][0]
        self.assertIsNone(event["inputTokens"])
        self.assertIsNone(event["outputTokens"])
        self.assertEqual((event["cachedInputTokens"], event["reasoningOutputTokens"]), (3, 8))

    def test_pagination_no_leak_or_duplicates(self):
        self.consent()
        for index in range(3):
            self.ingest(self.event(eventId=f"event-{index:016d}"))
        _, first, _ = self.call("GET", "/usage/history?limit=2", token=self.token)
        _, second, _ = self.call("GET", f"/usage/history?limit=2&before={first['nextBefore']}", token=self.token)
        self.assertEqual(len(first["events"]), 2)
        self.assertEqual(len(second["events"]), 1)
        self.assertIsNone(second["nextBefore"])
        self.assertTrue(first["events"][-1]["sequence"] > second["events"][0]["sequence"])

    def test_reject_bad_counts_identifiers_timestamps_and_content(self):
        self.consent()
        bad = [{"inputTokens": v} for v in (-1, True, 1.5, 1000000001, "42")]
        bad += [{"timestamp": v} for v in ("2026-02-30T00:00:00Z", "1999-01-01T00:00:00Z", "2099-01-01T00:00:00Z", "now", None)]
        bad += [{"sessionId": "/Users/ari/project"}, {"eventId": "short"}, {"provider": "invented"}, {"model": "x" * 97}]
        bad += [{k: "sensitive"} for k in ("path", "content", "messages", "credentials", "price", "title")]
        for values in bad:
            with self.subTest(values=values):
                self.assertEqual(self.ingest(self.event(**values))[0], 400)

    def test_validation_nonobjects_duplicate_keys_and_nan(self):
        for raw in (b'[]', b'null', b'{"handle":"alice","handle":"bobby","password":"longpassword"}', b'{"x":NaN}', b'{'):
            status, _, _ = self.call("POST", "/auth/login", **{"wsgi.input": io.BytesIO(raw), "CONTENT_LENGTH": str(len(raw))})
            self.assertEqual(status, 400)

    def test_request_size_media_origin_and_queries(self):
        self.assertEqual(self.call("POST", "/auth/login", CONTENT_LENGTH="99999")[0], 413)
        self.assertEqual(self.call("POST", "/auth/login", CONTENT_TYPE="text/plain")[0], 415)
        self.assertEqual(self.call("GET", "/me", token=self.token, HTTP_ORIGIN="https://evil.example")[0], 403)
        for suffix in ("?limit=0", "?limit=101", "?limit=1&limit=2", "?before=-1", "?accountId=alice", "?before=1 OR 1=1"):
            self.assertEqual(self.call("GET", "/usage/history" + suffix, token=self.token)[0], 400)
        self.assertEqual(self.call("GET", "/me?token=secret", token=self.token)[0], 400)
        self.assertEqual(self.call("DELETE", "/me", token=self.token)[0], 405)

    def test_login_rate_limit_persists_across_instances(self):
        for _ in range(10):
            self.call("POST", "/auth/login", {"handle": "nobody", "password": PASSWORD})
        self.app = Service(self.path, clock=lambda: self.now, hasher=self.fast_hasher)
        status, body, headers = self.call("POST", "/auth/login", {"handle": "nobody", "password": PASSWORD}, peer="192.0.2.2")
        self.assertEqual((status, body["error"]["code"]), (429, "rate_limited"))
        self.assertEqual(headers["Retry-After"], "900")
        self.now += 900
        self.assertEqual(self.call("POST", "/auth/login", {"handle": "nobody", "password": PASSWORD})[0], 401)

    def test_registration_rate_and_forwarded_header_spoof(self):
        for index in range(4):
            self.register(f"test{index}")
        status, _, _ = self.call("POST", "/auth/register", {"handle": "more", "password": PASSWORD}, HTTP_X_FORWARDED_FOR="192.0.2.99", HTTP_CF_CONNECTING_IP="192.0.2.98")
        self.assertEqual(status, 429)

    def test_account_request_limit(self):
        with connect(self.path) as db:
            from service import digest
            db.execute("INSERT INTO rate_limits VALUES (%s,%s,%s,%s)", (digest("account:" + self.alice["account"]["id"]), NOW, 300, NOW + 60))
        self.assertEqual(self.call("GET", "/me", token=self.token)[0], 429)

    def test_recovery_cannot_cross_accounts(self):
        self.register("bobby")
        status, _, _ = self.call("POST", "/auth/recover", {"handle": "bobby", "recoveryCode": self.alice["recoveryCode"], "newPassword": NEW_PASSWORD})
        self.assertEqual(status, 401)

    def test_migration_idempotent_and_schema_version(self):
        migrate(self.path)
        with connect(self.path) as db:
            self.assertEqual(schema_version(db), 1)
            self.assertEqual(db.execute("SELECT COUNT(*) AS total FROM accounts").fetchone()["total"], 1)

    def test_backup_environment_expands_dsn_without_argv_secrets(self):
        with patch.dict("os.environ", {"PGHOST": "wrong-host", "PGDATABASE": "wrong-db", "PGPASSWORD": "unrelated-secret"}):
            env = pg_environment("host=/var/run/postgresql dbname=kiln_accounts_test user=kiln_test")
        self.assertEqual(env["PGHOST"], "/var/run/postgresql")
        self.assertEqual(env["PGDATABASE"], "kiln_accounts_test")
        self.assertEqual(env["PGUSER"], "kiln_test")
        self.assertNotIn("PGPASSWORD", env)
        self.assertNotIn("host=", env["PGDATABASE"])

    def test_future_schema_refused(self):
        with connect(self.path) as db:
            db.execute("INSERT INTO schema_migrations(version) VALUES (2)")
        with self.assertRaisesRegex(RuntimeError, "refuse downgrade"):
            migrate(self.path)
        with self.assertRaisesRegex(RuntimeError, "schema mismatch"):
            Service(self.path, hasher=self.fast_hasher)

    def test_migration_failure_atomic_and_down_for_disposable_db(self):
        with connect(self.path) as db:
            down = (ROOT / "migrations/postgres/001_down.sql").read_text()
            with db.transaction():
                db.execute(down, prepare=False)
            self.assertEqual(schema_version(db), 0)
        with patch.object(Path, "read_text", return_value="CREATE TABLE rollback_probe(id integer); SELECT missing_function();"):
            with self.assertRaises(psycopg.Error):
                migrate(self.path)
        with connect(self.path) as db:
            self.assertIsNone(db.execute("SELECT to_regclass('rollback_probe') AS table_name").fetchone()["table_name"])
        migrate(self.path)
        with connect(self.path) as db:
            self.assertEqual(db.execute("SELECT count(*) AS total FROM accounts").fetchone()["total"], 0)


if __name__ == "__main__":
    unittest.main()
