"""Independent PostgreSQL acceptance through the public WSGI Service API.

Requires KILN_TEST_DATABASE_URL naming an explicitly disposable PostgreSQL DB
and KILN_POSTGRES_ACCEPT_DISPOSABLE=1. Never falls back to SQLite or skips.
Each test owns a random schema; spawned workers use separate real connections.
"""

import hashlib
from contextlib import contextmanager
import io
import json
import multiprocessing
import os
from pathlib import Path
import time
import unittest
import uuid

from argon2 import PasswordHasher
import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo

from db import connect, migrate
from service import Service


ROOT = Path(__file__).resolve().parents[1]
NOW = 1789365600
PASSWORD = "disposable acceptance password"
NEW_PASSWORD = "replacement acceptance password"
COUNTS = ("inputTokens", "outputTokens", "cachedInputTokens", "reasoningOutputTokens")


def service(dsn, now=NOW, quota=100000):
    # Real Argon2, reduced cost only to avoid parallel test memory pressure.
    return Service(dsn, clock=lambda: now, event_quota=quota,
                   hasher=PasswordHasher(time_cost=1, memory_cost=1024, parallelism=1))


def request(app, method, route, data=None, token=None, peer="192.0.2.100"):
    raw = json.dumps({} if data is None else data).encode("utf-8")
    path, _, query = route.partition("?")
    env = {"REQUEST_METHOD": method, "PATH_INFO": "/api/v1" + path,
           "QUERY_STRING": query, "CONTENT_TYPE": "application/json",
           "CONTENT_LENGTH": str(len(raw)), "REMOTE_ADDR": peer,
           "wsgi.input": io.BytesIO(raw)}
    if token is not None:
        env["HTTP_AUTHORIZATION"] = "Bearer " + token
    result = {}

    def start_response(status, headers):
        result.update(status=int(status.split(" ", 1)[0]), headers=dict(headers))

    result["started"] = time.monotonic_ns()
    body = b"".join(app(env, start_response))
    result["finished"] = time.monotonic_ns()
    result["body"] = json.loads(body)
    result["pid"] = os.getpid()
    return result


def worker(dsn, now, quota, jobs, gate, output):
    try:
        app = service(dsn, now, quota)
        gate.wait(timeout=45)
        output.send({"results": [request(app, **job) for job in jobs]})
    except BaseException as exc:
        # Never send DSNs, request bodies or exception strings to test logs.
        output.send({"worker_error": type(exc).__name__})
    finally:
        output.close()


def job(method, route, data=None, token=None, peer="192.0.2.100"):
    return dict(method=method, route=route, data=data, token=token, peer=peer)


def event(index=1, **changes):
    return {"eventId": f"acceptance-event-{index:016d}",
            "sessionId": "acceptance-session-00000001", "provider": "codex",
            "model": "gpt-5.5", "timestamp": "2026-09-14T06:00:00.000Z",
            "inputTokens": 42, "outputTokens": 7, **changes}


def source_hashes():
    paths = [ROOT / "service.py", ROOT / "db.py", *sorted((ROOT / "migrations").rglob("*.sql"))]
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


class PostgresConcurrencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.environ.get("KILN_POSTGRES_ACCEPT_DISPOSABLE") != "1":
            raise RuntimeError("Explicit disposable PostgreSQL authorization is required")
        dsn = os.environ.get("KILN_TEST_DATABASE_URL", "")
        if not dsn or dsn.startswith(("sqlite:", "/")):
            raise RuntimeError("KILN_TEST_DATABASE_URL must be an explicit PostgreSQL DSN")
        config = conninfo_to_dict(dsn)
        database = config.get("dbname", "")
        if not any(word in database.lower() for word in ("test", "disposable")):
            raise RuntimeError("Refusing DB name without test/disposable marker")
        if not config.get("host") or not config.get("user") or config.get("service"):
            raise RuntimeError("Explicit host/user required; libpq service indirection is refused")
        cls.base_dsn = make_conninfo(dsn, options="-c search_path=pg_catalog", connect_timeout="5")
        with psycopg.connect(cls.base_dsn) as db:
            version, actual = db.execute("SELECT version(), current_database()").fetchone()
            if not version.startswith("PostgreSQL ") or actual != database:
                raise RuntimeError("Disposable PostgreSQL identity mismatch")
            print("POSTGRES_ACCEPTANCE " + json.dumps({"server": version, "database": actual}), flush=True)
        cls.initial_hashes = source_hashes()
        print("POSTGRES_SOURCE " + json.dumps(cls.initial_hashes, sort_keys=True), flush=True)

    @classmethod
    def tearDownClass(cls):
        if source_hashes() != cls.initial_hashes:
            raise AssertionError("Backend source changed during acceptance; rerun frozen source")

    def setUp(self):
        self.schema = "kiln_accept_" + uuid.uuid4().hex
        with psycopg.connect(self.base_dsn, autocommit=True) as db:
            db.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(self.schema)))
        self.addCleanup(self.drop_schema)
        self.dsn = make_conninfo(self.base_dsn, options=f"-c search_path={self.schema},pg_catalog")
        migrate(self.dsn)
        with connect(self.dsn) as db:
            self.assertIsInstance(db, psycopg.Connection)
            self.assertGreaterEqual(db.info.server_version, 160000)
        with psycopg.connect(self.dsn) as db:
            self.assertEqual(db.execute("SELECT current_schema()").fetchone()[0], self.schema)
        self.now = NOW
        self.app = service(self.dsn)
        self.alice = self.register("accept_alice")
        self.token = self.alice["session"]["token"]

    def drop_schema(self):
        self.drop_named_schema(self.schema)

    def drop_named_schema(self, schema):
        with psycopg.connect(self.base_dsn, autocommit=True) as db:
            db.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(schema)))

    @contextmanager
    def admission_cap(self):
        with psycopg.connect(self.dsn) as db:
            used = db.execute("SELECT pg_database_size(current_database())").fetchone()[0]
        maximum = 1024 * 1024
        self.assertGreater(used, maximum)
        print("POSTGRES_CAPACITY " + json.dumps({"test": self._testMethodName,
              "measured_database_bytes": used, "admission_budget_bytes": maximum}), flush=True)
        previous = os.environ.get("KILN_DATABASE_MAX_BYTES")
        os.environ["KILN_DATABASE_MAX_BYTES"] = str(maximum)
        try:
            yield
        finally:
            if previous is None:
                os.environ.pop("KILN_DATABASE_MAX_BYTES", None)
            else:
                os.environ["KILN_DATABASE_MAX_BYTES"] = previous

    def call(self, method, route, data=None, token=None, peer="192.0.2.100"):
        return request(self.app, method, route, data, token, peer)

    def check(self, result, status, code=None):
        self.assertEqual(result["status"], status, result["body"].get("error", {}))
        self.assertEqual(result["headers"]["Cache-Control"], "no-store")
        if code is not None:
            self.assertEqual(result["body"]["error"]["code"], code)
        return result["body"]

    def register(self, handle):
        return self.check(self.call("POST", "/auth/register",
                                    {"handle": handle, "password": PASSWORD}), 201)

    def consent(self, enabled=True, token=None):
        return self.check(self.call("PATCH", "/settings", {"usageSharingEnabled": enabled},
                                    token or self.token), 200)

    def aggregate(self, token=None):
        return self.check(self.call("GET", "/usage/aggregate", token=token or self.token), 200)

    def race(self, jobs, *, now=None, quota=100000, batches=False):
        batches = jobs if batches else [[item] for item in jobs]
        context = multiprocessing.get_context("spawn")
        gate = context.Barrier(len(batches) + 1)
        workers, receivers, results = [], [], []
        try:
            for batch in batches:
                receiver, sender = context.Pipe(duplex=False)
                process = context.Process(target=worker,
                                          args=(self.dsn, self.now if now is None else now,
                                                quota, batch, gate, sender))
                receivers.append(receiver)
                process.start()
                sender.close()
                workers.append(process)
            gate.wait(timeout=45)
            deadline = time.monotonic() + 90
            for receiver in receivers:
                self.assertTrue(receiver.poll(max(0, deadline - time.monotonic())), "Worker timed out")
                message = receiver.recv()
                self.assertNotIn("worker_error", message, message.get("worker_error"))
                results.extend(message["results"])
            for process in workers:
                process.join(timeout=10)
                self.assertEqual(process.exitcode, 0, "Worker did not exit cleanly")
            self.assertEqual(len({r["pid"] for r in results}), len(workers))
            self.assertNotIn(os.getpid(), {r["pid"] for r in results})
            print("POSTGRES_RACE " + json.dumps({"test": self._testMethodName,
                  "workers": len(workers), "requests": len(results),
                  "statuses": {str(s): sum(r["status"] == s for r in results)
                               for s in sorted({r["status"] for r in results})}}), flush=True)
            return results
        finally:
            for process in workers:
                if process.is_alive():
                    process.terminate()
                process.join(timeout=10)
                if process.is_alive():
                    process.kill()
                    process.join(timeout=10)
            for receiver in receivers:
                receiver.close()

    def test_duplicate_event_is_exactly_once_across_processes(self):
        self.consent()
        results = self.race([job("POST", "/usage/events", event(), self.token)] * 8)
        self.assertEqual(sorted(r["status"] for r in results), [200] * 7 + [201])
        for result in results:
            body = self.check(result, result["status"])
            self.assertEqual(body, {"eventId": event()["eventId"], "duplicate": result["status"] == 200})
        self.assertEqual(self.aggregate()["eventCount"], 1)
        self.assertEqual(self.aggregate()["counts"]["inputTokens"]["knownTotal"], 42)

    def test_conflicting_duplicate_keeps_only_winning_payload(self):
        self.consent()
        results = self.race([job("POST", "/usage/events", event(inputTokens=100 + i), self.token)
                             for i in range(8)])
        self.assertEqual(sorted(r["status"] for r in results), [201] + [409] * 7)
        winner = next(i for i, r in enumerate(results) if r["status"] == 201)
        for result in results:
            if result["status"] == 409:
                self.check(result, 409, "event_conflict")
        self.assertEqual(self.aggregate()["counts"]["inputTokens"]["knownTotal"], 100 + winner)
        self.check(self.call("POST", "/usage/events", event(inputTokens=100 + winner), self.token), 200)

    def test_concurrent_quota_never_overflows_and_retry_survives(self):
        self.consent()
        results = self.race([job("POST", "/usage/events", event(i), self.token) for i in range(8)], quota=2)
        self.assertEqual(sorted(r["status"] for r in results), [201] * 2 + [409] * 6)
        self.assertEqual(self.aggregate()["eventCount"], 2)
        winner = next(i for i, r in enumerate(results) if r["status"] == 201)
        for result in results:
            if result["status"] == 409:
                self.check(result, 409, "usage_quota_exceeded")
        retries = self.race([job("POST", "/usage/events", event(winner), self.token)] * 4, quota=2)
        self.assertTrue(all(r["status"] == 200 and r["body"]["duplicate"] for r in retries))

    def test_account_isolation_same_ids_cursors_profiles_and_consent(self):
        bob = self.register("accept_bobby")
        other = bob["session"]["token"]
        self.consent()
        self.consent(token=other)
        jobs = [job("POST", "/usage/events", event(i, inputTokens=1_000_000_000), self.token)
                for i in range(3)]
        jobs += [job("POST", "/usage/events", event(i, inputTokens=9), other) for i in range(3)]
        self.assertTrue(all(r["status"] == 201 for r in self.race(jobs)))
        self.assertEqual(self.aggregate()["counts"]["inputTokens"]["knownTotal"], 3_000_000_000)
        self.assertEqual(self.aggregate(other)["counts"]["inputTokens"]["knownTotal"], 27)
        for token, expected in ((self.token, 1_000_000_000), (other, 9)):
            page = self.check(self.call("GET", "/usage/history?limit=2", token=token), 200)
            tail = self.check(self.call("GET", f"/usage/history?limit=2&before={page['nextBefore']}", token=token), 200)
            rows = page["events"] + tail["events"]
            self.assertEqual(len(rows), 3)
            self.assertEqual(len({r["sequence"] for r in rows}), 3)
            self.assertEqual([r["sequence"] for r in rows], sorted((r["sequence"] for r in rows), reverse=True))
            self.assertTrue(all(r["inputTokens"] == expected for r in rows))
            self.assertIsNone(tail["nextBefore"])
        self.check(self.call("POST", "/usage/events", event(10, accountId=bob["account"]["id"]), self.token), 400)
        self.check(self.call("GET", "/usage/history?accountId=" + bob["account"]["id"], token=self.token), 400)
        self.check(self.call("PATCH", "/profile", {"bio": "only alice"}, self.token), 200)
        self.assertEqual(self.check(self.call("GET", "/me", token=other), 200)["account"]["bio"], "")
        self.consent(False)
        isolated = self.race([job("POST", "/usage/events", event(10), self.token),
                              job("POST", "/usage/events", event(10), other)])
        self.check(isolated[0], 403, "usage_sharing_disabled")
        self.check(isolated[1], 201)

    def test_postgres_null_zero_and_large_integer_aggregate(self):
        self.consent()
        self.assertTrue(all(c["knownTotal"] is None for c in self.aggregate()["counts"].values()))
        entries = [event(1, **dict.fromkeys(COUNTS)), event(2, inputTokens=0, outputTokens=None),
                   *[event(i, inputTokens=1_000_000_000, outputTokens=None) for i in range(3, 7)]]
        self.assertTrue(all(r["status"] == 201 for r in self.race(
            [job("POST", "/usage/events", entry, self.token) for entry in entries])))
        counts = self.aggregate()["counts"]
        self.assertEqual(counts["inputTokens"], {"knownTotal": 4_000_000_000, "knownEvents": 5, "unknownEvents": 1})
        self.assertEqual(counts["outputTokens"], {"knownTotal": None, "knownEvents": 0, "unknownEvents": 6})
        self.assertEqual(counts["cachedInputTokens"], counts["outputTokens"])
        self.check(self.call("POST", "/usage/events", event(2, inputTokens=0, outputTokens=None,
                                                           cachedInputTokens=None), self.token), 200)

    def test_recovery_code_has_one_winner_and_revokes_every_old_session(self):
        logged_in = self.check(self.call("POST", "/auth/login",
                              {"handle": "accept_alice", "password": PASSWORD}), 200)
        data = {"handle": "accept_alice", "recoveryCode": self.alice["recoveryCode"], "newPassword": NEW_PASSWORD}
        results = self.race([job("POST", "/auth/recover", data)] * 8)
        self.assertEqual(sorted(r["status"] for r in results), [200] + [401] * 7)
        winner = next(r["body"] for r in results if r["status"] == 200)
        self.assertNotEqual(winner["recoveryCode"], self.alice["recoveryCode"])
        old_tokens = [self.token, logged_in["session"]["token"]]
        revoked = self.race([job("GET", "/me", token=t) for t in old_tokens])
        for result in revoked:
            self.check(result, 401, "unauthorized")
        self.check(self.call("GET", "/me", token=winner["session"]["token"]), 200)
        self.check(self.call("POST", "/auth/recover", data), 401, "invalid_credentials")
        self.now += 901
        self.app = service(self.dsn, self.now)
        self.check(self.call("POST", "/auth/login", {"handle": "accept_alice", "password": PASSWORD}), 401)
        self.check(self.call("POST", "/auth/login", {"handle": "accept_alice", "password": NEW_PASSWORD}), 200)
        self.check(self.call("POST", "/auth/recover", {**data, "recoveryCode": winner["recoveryCode"]}), 200)

    def test_password_change_racing_login_leaves_no_old_password_session(self):
        self.consent()
        jobs = [job("POST", "/auth/password", {"currentPassword": PASSWORD, "newPassword": NEW_PASSWORD}, self.token)]
        jobs += [job("POST", "/auth/login", {"handle": "accept_alice", "password": PASSWORD})] * 6
        results = self.race(jobs)
        changed = self.check(results[0], 200)
        old_tokens = [self.token]
        for result in results[1:]:
            self.assertIn(result["status"], (200, 401))
            if result["status"] == 200:
                old_tokens.append(result["body"]["session"]["token"])
        revoked = self.race([job("POST", "/usage/events", event(i), token) for i, token in enumerate(old_tokens)])
        for result in revoked:
            self.check(result, 401, "unauthorized")
        self.check(self.call("GET", "/me", token=changed["session"]["token"]), 200)
        self.assertEqual(self.aggregate(changed["session"]["token"])["eventCount"], 0)

    def test_simultaneous_password_changes_cannot_reuse_revoked_session(self):
        results = self.race([job("POST", "/auth/password",
                                {"currentPassword": PASSWORD, "newPassword": NEW_PASSWORD + str(i)}, self.token)
                             for i in range(6)])
        self.assertEqual(sorted(r["status"] for r in results), [200] + [401] * 5)
        winner = next(i for i, r in enumerate(results) if r["status"] == 200)
        self.check(self.call("GET", "/me", token=self.token), 401)
        self.check(self.call("GET", "/me", token=results[winner]["body"]["session"]["token"]), 200)
        self.check(self.call("POST", "/auth/login", {"handle": "accept_alice", "password": NEW_PASSWORD + str(winner)}), 200)

    def test_session_cap_same_timestamp_and_logout_across_workers(self):
        results = self.race([job("POST", "/auth/login", {"handle": "accept_alice", "password": PASSWORD})] * 10)
        self.assertTrue(all(r["status"] == 200 for r in results))
        tokens = [r["body"]["session"]["token"] for r in results]
        self.check(self.call("GET", "/me", token=self.token), 401)
        self.assertTrue(all(r["status"] == 200 for r in self.race([job("GET", "/me", token=t) for t in tokens])))
        self.assertTrue(all(r["status"] == 200 for r in self.race([job("POST", "/auth/logout", {}, tokens[0])] * 4)))
        self.check(self.call("GET", "/me", token=tokens[0]), 401)
        self.check(self.call("GET", "/me", token=tokens[1]), 200)
        self.app = service(self.dsn, NOW + 30 * 86400)
        self.check(self.call("GET", "/me", token=tokens[1]), 401)

    def test_handle_rate_budget_persists_across_processes_and_resets_at_expiry(self):
        data = {"handle": "accept_alice", "password": NEW_PASSWORD}
        results = self.race([job("POST", "/auth/login", data, peer=f"192.0.2.{i + 1}") for i in range(16)])
        self.assertEqual(sorted(r["status"] for r in results), [401] * 10 + [429] * 6)
        for result in results:
            if result["status"] == 429:
                self.check(result, 429, "rate_limited")
                self.assertEqual(result["headers"]["Retry-After"], "900")
        restarted = self.race([job("POST", "/auth/login", {**data, "password": PASSWORD})] * 2, now=NOW + 899)
        for result in restarted:
            self.check(result, 429, "rate_limited")
            self.assertEqual(result["headers"]["Retry-After"], "1")
        results = self.race([job("POST", "/auth/login", {**data, "password": PASSWORD})] * 2, now=NOW + 900)
        self.assertTrue(all(r["status"] == 200 for r in results))

    def test_peer_rate_budget_combines_distinct_handles_across_workers(self):
        batches = [[job("POST", "/auth/login", {"handle": f"missing_{i}_{n}", "password": PASSWORD},
                        peer="198.51.100.42") for n in range(5)] for i in range(8)]
        results = self.race(batches, batches=True)
        self.assertEqual(sorted(r["status"] for r in results), [401] * 30 + [429] * 10)
        for result in results:
            if result["status"] == 429:
                self.assertEqual(result["headers"]["Retry-After"], "900")
        self.check(self.call("POST", "/auth/login", {"handle": "missing_fresh", "password": PASSWORD},
                            peer="198.51.100.43"), 401)

    def test_registration_unique_handle_is_not_internal_error(self):
        results = self.race([job("POST", "/auth/register", {"handle": "accept_unique", "password": PASSWORD},
                                peer=f"203.0.113.{i + 1}") for i in range(8)])
        self.assertEqual(sorted(r["status"] for r in results), [201] + [409] * 7)
        for result in results:
            if result["status"] == 409:
                self.check(result, 409, "handle_unavailable")
        self.check(self.call("POST", "/auth/register", {"handle": "ACCEPT_UNIQUE", "password": PASSWORD}), 400)

    def test_account_rate_budget_is_shared_by_production_two_workers(self):
        batches = [[job("GET", "/me", token=self.token, peer=f"198.51.100.{i + 1}")
                    for _ in range(160)] for i in range(2)]
        results = self.race(batches, batches=True)
        self.assertEqual(sorted(r["status"] for r in results), [200] * 300 + [429] * 20)
        for result in results:
            if result["status"] == 429:
                self.check(result, 429, "rate_limited")
                self.assertEqual(result["headers"]["Retry-After"], "60")
        restarted = self.race([job("GET", "/me", token=self.token)] * 2)
        for result in restarted:
            self.check(result, 429, "rate_limited")
        reset = self.race([job("GET", "/me", token=self.token)] * 2, now=NOW + 60)
        self.assertTrue(all(r["status"] == 200 for r in reset))

    def test_eight_worker_overload_is_bounded_and_never_bypasses_rate_limit(self):
        batches = [[job("GET", "/me", token=self.token, peer=f"198.51.100.{i + 1}")
                    for _ in range(40)] for i in range(8)]
        results = self.race(batches, batches=True)
        successes = sum(r["status"] == 200 for r in results)
        self.assertGreater(successes, 0)
        self.assertLessEqual(successes, 300)
        self.assertTrue(any(r["status"] == 429 for r in results))
        unavailable = []
        for result in results:
            self.assertIn(result["status"], (200, 429, 503))
            if result["status"] == 429:
                self.check(result, 429, "rate_limited")
                self.assertEqual(result["headers"]["Retry-After"], "60")
            elif result["status"] == 503:
                self.check(result, 503, "unavailable")
                self.assertEqual(result["headers"]["Retry-After"], "5")
                elapsed = (result["finished"] - result["started"]) / 1_000_000_000
                self.assertLess(elapsed, 15)
                unavailable.append(round(elapsed, 3))
        print("POSTGRES_OVERLOAD " + json.dumps({"successes": successes,
              "unavailable_seconds": unavailable, "unavailable_retry_after": 5}), flush=True)
        after_backoff = self.race([job("GET", "/me", token=self.token)] * 2, now=NOW + 5)
        for result in after_backoff:
            self.check(result, 429, "rate_limited")
            self.assertEqual(result["headers"]["Retry-After"], "55")

    def test_at_capacity_logout_and_consent_revoke_but_new_usage_is_denied(self):
        self.consent()
        self.check(self.call("POST", "/usage/events", event(), self.token), 201)
        login = self.check(self.call("POST", "/auth/login", {"handle": "accept_alice", "password": PASSWORD}), 200)
        other = login["session"]["token"]
        with self.admission_cap():
            blocked = self.race([job("POST", "/usage/events", event(i), self.token) for i in range(2, 6)])
            for result in blocked:
                self.check(result, 503, "storage_capacity")
                self.assertEqual(result["headers"]["Retry-After"], "3600")
            reduced = self.race([job("POST", "/auth/logout", {}, self.token),
                                 job("PATCH", "/settings", {"usageSharingEnabled": False}, other)])
            self.check(reduced[0], 200)
            self.assertIs(self.check(reduced[1], 200)["account"]["usageSharingEnabled"], False)
            self.check(self.call("GET", "/me", token=self.token), 401, "unauthorized")
            self.check(self.call("POST", "/auth/logout", {}, self.token), 200)
            self.check(self.call("POST", "/usage/events", event(), other), 403, "usage_sharing_disabled")
            self.assertEqual(self.aggregate(other)["eventCount"], 1)
            self.check(self.call("POST", "/auth/register", {"handle": "cap_new_account", "password": PASSWORD}),
                       503, "storage_capacity")

    def test_at_capacity_password_change_revokes_old_sessions(self):
        self.consent()
        login = self.check(self.call("POST", "/auth/login", {"handle": "accept_alice", "password": PASSWORD}), 200)
        with self.admission_cap():
            result = self.race([job("POST", "/auth/password",
                                    {"currentPassword": PASSWORD, "newPassword": NEW_PASSWORD}, self.token)])[0]
            changed = self.check(result, 200)
            for token in (self.token, login["session"]["token"]):
                self.check(self.call("GET", "/me", token=token), 401, "unauthorized")
            new_token = changed["session"]["token"]
            self.check(self.call("GET", "/me", token=new_token), 200)
            self.check(self.call("POST", "/usage/events", event(), new_token), 503, "storage_capacity")
            self.check(self.call("POST", "/auth/login", {"handle": "accept_alice", "password": PASSWORD}),
                       401, "invalid_credentials")

    def test_at_capacity_recovery_consumes_code_and_revokes_old_sessions(self):
        self.consent()
        data = {"handle": "accept_alice", "recoveryCode": self.alice["recoveryCode"], "newPassword": NEW_PASSWORD}
        with self.admission_cap():
            results = self.race([job("POST", "/auth/recover", data)] * 4)
            self.assertEqual(sorted(r["status"] for r in results), [200] + [401] * 3)
            recovered = next(r["body"] for r in results if r["status"] == 200)
            self.check(self.call("GET", "/me", token=self.token), 401, "unauthorized")
            self.check(self.call("POST", "/auth/recover", data), 401, "invalid_credentials")
            self.assertNotEqual(recovered["recoveryCode"], self.alice["recoveryCode"])
            new_token = recovered["session"]["token"]
            self.check(self.call("GET", "/me", token=new_token), 200)
            self.check(self.call("POST", "/usage/events", event(), new_token), 503, "storage_capacity")

    def test_scoped_lock_timeout_is_bounded_sanitized_and_recovers(self):
        other_schema = "kiln_accept_" + uuid.uuid4().hex
        with psycopg.connect(self.base_dsn, autocommit=True) as db:
            db.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(other_schema)))
        self.addCleanup(self.drop_named_schema, other_schema)
        other_dsn = make_conninfo(self.base_dsn, options=f"-c search_path={other_schema},pg_catalog")
        migrate(other_dsn)
        other_app = service(other_dsn)
        with psycopg.connect(self.dsn, autocommit=True) as holder:
            with holder.transaction():
                # Deliberate real DB contention, not a patched Service lock.
                holder.execute("SELECT pg_advisory_xact_lock(hashtextextended("
                               "current_database() || ':' || current_schema() || ':kiln-write',0))")
                self.check(request(other_app, "POST", "/auth/register",
                                   {"handle": "other_schema", "password": PASSWORD}), 201)
                denied = self.race([job("GET", "/me", token=self.token)])[0]
                self.check(denied, 503, "unavailable")
                self.assertEqual(denied["headers"]["Retry-After"], "5")
                self.assertEqual(denied["body"], {"error": {"code": "unavailable",
                                  "message": "Service temporarily unavailable."}})
                elapsed = (denied["finished"] - denied["started"]) / 1_000_000_000
                self.assertGreaterEqual(elapsed, 1)
                self.assertLess(elapsed, 15, "Lock backpressure was not bounded")
        self.check(self.call("GET", "/me", token=self.token), 200)

    def test_consent_disable_race_blocks_all_later_uploads_and_retries(self):
        self.consent()
        self.check(self.call("POST", "/usage/events", event(), self.token), 201)
        jobs = [job("PATCH", "/settings", {"usageSharingEnabled": False}, self.token)]
        jobs += [job("POST", "/usage/events", event(i), self.token) for i in range(2, 9)]
        results = self.race(jobs)
        disabled = results[0]
        self.check(disabled, 200)
        self.assertIs(disabled["body"]["account"]["usageSharingEnabled"], False)
        for result in results[1:]:
            self.assertIn(result["status"], (201, 403))
            if result["status"] == 403 or result["started"] >= disabled["finished"]:
                self.check(result, 403, "usage_sharing_disabled")
        expected = 1 + sum(r["status"] == 201 for r in results[1:])
        self.assertEqual(self.aggregate()["eventCount"], expected)
        later = self.race([job("POST", "/usage/events", event(), self.token),
                           job("POST", "/usage/events", event(99), self.token)] * 3)
        for result in later:
            self.check(result, 403, "usage_sharing_disabled")
        self.assertEqual(self.aggregate()["eventCount"], expected)
        self.consent()
        self.check(self.call("POST", "/usage/events", event(), self.token), 200)

    def test_consent_enable_race_never_accepts_before_enable_starts(self):
        self.check(self.call("POST", "/usage/events", event(), self.token), 403)
        jobs = [job("PATCH", "/settings", {"usageSharingEnabled": True}, self.token)]
        jobs += [job("POST", "/usage/events", event(i), self.token) for i in range(2, 9)]
        results = self.race(jobs)
        self.check(results[0], 200)
        self.assertIs(results[0]["body"]["account"]["usageSharingEnabled"], True)
        for result in results[1:]:
            self.assertIn(result["status"], (201, 403))
            if result["finished"] <= results[0]["started"]:
                self.check(result, 403, "usage_sharing_disabled")
        self.check(self.call("POST", "/usage/events", event(99), self.token), 201)
        self.assertEqual(self.aggregate()["eventCount"], 1 + sum(r["status"] == 201 for r in results[1:]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
