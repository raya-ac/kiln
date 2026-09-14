# security gate

## included protections

Strict bounded JSON with duplicate-key and unknown-field rejection; parameterized
SQL; output-escaped HTML with no scripts; no cookies/CORS; bearer tokens in
headers only;30-day fixed session expiry,10-session cap and credential-change
revocation; one-time random256-bit user-kept recovery; pinned Argon2id password
work; same invalid-credential responses and expensive work on absent accounts;
durable cross-process rate budgets; current consent checked again under the
write transaction; unique account+event ID with canonical mismatch detection.

Profile handles are immutable, so URLs are stable. Only profile text is public.
Private events contain opaque IDs, harness, model identifier, UTC timestamp and
four independently nullable measured counts. No arbitrary context fields or
credential-bearing URLs are accepted. Counts are not verified against upstream
provider billing, so the service calls them client-reported measurements, not
an authoritative billing ledger. Provider/model identifiers must still be
selected from genuine source data by the native client, not user-entered secrets.

Retained events are capped at100,000/account. At capacity, reject new data
explicitly without truncating or purging history. PostgreSQL account/profile/
new-usage writes pause at a1GiB measured database admission budget. Existing
history, logout, consent revocation, password/recovery revocation and health
remain available. Auth rate limits still apply; active rate keys are capped
at10,000. This is not a filesystem quota on shared PostgreSQL data/WAL. Host
autovacuum is enabled, max_wal_size1GiB, no replication slots, archive_mode off;
those are existing host settings, not changes made by Kiln.

## test coverage

Unit/storage and real2-worker Gunicorn socket tests cover registration, login,
missing vs wrong credentials, hashing, session expiry/logout/password revocation,
one-time/concurrent recovery, account isolation, concurrent idempotency and quota,
mismatch409, null and explicit-zero counts, SQL/content injection, public HTML,
immutable handles, body/query bounds, forwarded-header spoofing, durable rate
limits, PostgreSQL capacity admission, backup/restore, migration refusal/down,
consent revocation, and absence of test secrets from server logs.

Tests use intentionally low-cost Argon2 in isolated unit fixtures for speed;
a dedicated production-parameter test and real HTTP workers use64MiB/time3.
No real user account fixture is retained. Public acceptance has a separate
exact-ID/handle/password-ownership checked cleanup path in tools/live_smoke.py.

## explicit remaining limits

- No email, MFA, recovery-code regeneration, account deletion/export API, or
  password breach lookup in this slice. Lost replacement recovery code is a
  known support limitation. Do not advertise account deletion or email recovery.
- Side-channel behavior has comparable work, not exact wall-clock equivalence.
  Public handle existence is intentionally exposed through public profiles.
- Layerline does not establish trusted forwarded-client-IP identity. The shared
  peer signup5/hour cap limits availability; header trust remains disabled.
- Off-host encrypted database backup is NOT configured. Local rollback and
  restore checks are not a claim of host-loss disaster recovery.
- New certificate renewal config does not persist suppression of global
  directory hooks. Future scheduled renewal may restart shared Layerline;
  separately review that lifecycle, without silently editing unrelated hooks.
- Browser account sign-in/signup is not implemented. Native real-client
  acceptance is owned by the main task and separate from backend test success.

The server uses a real psycopg3 PostgreSQL connection, native parameterized SQL,
schema migrations and advisory transaction locks. SQLite preservation tools and
historical SQL are under legacy locations and are never imported by the server.
Bounded write-lock backpressure returns503/unavailable with Retry-After5. A lock
timeout under an earlier parallel local test load was retained as a failed
acceptance observation, not treated as a clean concurrency pass.
