# independent PostgreSQL acceptance

Status: FINAL LOCAL POSTGRESQL GATE PASS. 20/20 tests, zero skips, 73.987s on
the final frozen core, including the backup-helper correction. No unresolved
blocking finding remains in the tested API concurrency/capacity scope.
Scope is only this document and
`tests/test_postgres_concurrency.py`; no service, database, migration, deployment,
Swift, or other agent files are owned by this review.

## execution boundary

Read-only control-plane audit performed before project execution: ancestor and
project instructions, local/global Git configuration and hooks, project `.codex`
and environment loaders, shell startup files, account requirements and virtualenv
executable symlinks/startup hooks, root Makefile, service/database imports,
migration SQL, Gunicorn settings, deployment units and packaging script.
No active project Git hooks, `.codex`, `.envrc`, Python `.pth`, sitecustomize or
usercustomize files were found in the account service. The root Makefile invokes
Swift and packaging tasks; it is not executed. Shell activation/startup scripts,
dependency installation, deployment scripts and Git credential helpers are not
executed by this review. No project poisoning found in this scoped inspection.

The owner chose local installed PostgreSQL 17, an isolated cluster under
`account-service/.test-pg`, Unix socket `.test-pg/socket`, port 55449, database
`kiln_accounts_test`, role `kiln_test`. No production connection or data mutation
is authorized or needed. The owner controls cluster startup/shutdown.

The test requires an explicit test DSN and `KILN_POSTGRES_ACCEPT_DISPOSABLE=1`,
rejects SQLite, implicit libpq service selection and unmarked database names,
verifies PostgreSQL server identity, and creates a UUID-named schema per test.
Cleanup drops only that schema. All account/session/usage mutations go through
the exact public `Service.__call__` WSGI API. There are no mocked connections,
SQLite substitutes, monkeypatched transaction internals or direct SQL state
fixtures. Independent spawned OS processes initialize their own Service and
connections before a shared start barrier. Real Argon2 uses an explicitly
injected low-cost test configuration; this is not a production hash-cost or
resource-exhaustion benchmark. API time is injected for exact window expiry.

## acceptance matrix

- Eight simultaneous identical event inserts: one 201, seven 200 duplicates,
  one retained event and one contribution to aggregate counts.
- Eight conflicting payloads for one event ID: one 201, seven documented 409s,
  unchanged winning payload and successful canonical retry.
- Eight distinct inserts at quota two: two 201s, six quota 409s, retries retained.
- Same event IDs across accounts: independent histories/aggregates, cursor
  pagination, profile and consent isolation, forged owner fields rejected.
- PostgreSQL null/zero semantics and JSON integer totals over signed 32-bit.
- Eight simultaneous uses of one recovery code: one winner, old sessions/code
  invalid, new password/code usable after the rate window.
- Password change racing six old-password logins: no old-password session
  remains valid after change acknowledgment.
- Six simultaneous password changes: one winner, revoked token cannot be reused.
- Ten simultaneous logins at the same timestamp: ten-device cap, oldest evicted,
  cross-worker idempotent logout, unrelated session intact, exact expiry denied.
- Sixteen attempts from distinct peers: exactly ten credential checks then six
  rate 429s; new workers preserve the budget; expiry boundary resets it.
- Forty distinct-handle attempts from eight workers: shared peer ceiling of 30,
  separate peer not blocked.
- Eight same-handle registrations: one account, seven public 409s, no leaked
  PostgreSQL unique-violation 500 or silent case normalization.
- Disable-consent race: overlapping inserts may precede the disable; all
  requests started after its response, including identical retries, must fail.
  Retained history stays unchanged; opting in restores canonical retry.
- Enable-consent race: no success completed before enable starts; accepted
  events match aggregate state and subsequent upload succeeds.
- Shared account budget: the production topology of two synchronous workers
  issues 320 reads, exactly 300 succeed and 20 are rate limited; new workers
  preserve it and the exact window resets it.
- Separate eight-worker overload burst: at most 300 successful reads; only
  documented 429 or bounded, sanitized 503/Retry-After5 permitted otherwise.
  New workers still see the exhausted budget after backoff. This test does not
  claim eight-worker saturation has zero transient failures.
- Actual PostgreSQL database larger than its configured admission budget:
  new usage and registration blocked while logout, consent disable, password
  change and one-use recovery revoke access across workers. No disk fill and
  no mocked database-size function; the injected budget is 1MiB.
- Deliberately held real Kiln advisory lock: own-schema API returns bounded,
  sanitized 503 with Retry-After; another isolated Kiln schema keeps working;
  normal API access resumes when the lock is released.

## findings and SQL differences

Initial SQLite `BEGIN IMMEDIATE` globally serialized writes. The reviewed
PostgreSQL implementation uses an actual transaction advisory lock keyed by
database, schema and `kiln-write`, not a process-local mutex or a database-wide
unqualified lock. A deliberately held lock blocks only the matching namespace;
another schema's API still works. Credential verification/hash work remains
outside the lock, with current credential/session/consent revalidation inside.

Verified SQL differences:

| SQLite prototype | Reviewed PostgreSQL behavior |
| --- | --- |
| `PRAGMA user_version` | Transactional `schema_migrations` table |
| `?`, SQLite rows | `%s`, real psycopg `dict_row` connections |
| scalar `MIN` | `LEAST` for capped rate-counter increments |
| `rowid`, `LIMIT -1` | Session identity sequence and PostgreSQL `OFFSET` |
| `AUTOINCREMENT` | BIGINT identity event sequence; pagination requires ordering, not contiguous IDs |
| SQLite integrity error | PostgreSQL `UniqueViolation` mapped to 409 with rollback |
| permissive aggregate typing | Integer columns summed as JSON integers; 4,000,000,000 verified |
| integer consent storage | Explicit 0/1 CHECK retained; API values remain actual JSON booleans |
| page/WAL limits | `pg_database_size` growth admission, not a physical quota |

Sessions initially used random token-hash order for equal timestamps. The owner
replaced that with an identity sequence before final acceptance; ten same-time
logins now evict the oldest registration session deterministically.

Packaging finding reported to owner before execution: the initial
`tools/package_release.py` exclusion set omitted `.test-pg`. Its recursive scan
would include disposable cluster files/test data in an artifact. The owner must
exclude the cluster from both release packaging and Git tracking before release.
This is an ordinary packaging defect, not detected project poisoning. The owner
added `.test-pg` to both exclusions; read-back confirmed that change before tests.

Resolved security blocker identified by the parent: initial `write_transaction` applied
the capacity check to every transaction, including the rate counter before
logout, password/recovery revocation and consent disable. A full admission
budget would prevent users reducing access. The owner moved admission to new
registration, profile edits and fresh usage inserts; rate keys are bounded to
10,000 active rows and sessions to ten/account. The real at-cap tests passed for
logout, consent disable, password change and single-use recovery. The tests do
not artificially exempt auth/rate checks or patch the capacity function.

Reserve boundary: this is admission-cap acceptance with actual disk space still
available, not an ENOSPC test. Security/rate/session maintenance can exceed the
growth budget. The host owner must verify and monitor physical disk/WAL/vacuum
headroom; a 1GiB admission budget is not a guarantee of revocation on a physically
full filesystem. The 10,000-row limit bounds live rate keys, not total historical
table bloat. Host reserve/restore evidence is outside this local review.

## run evidence

Initial harness-only attempt: PostgreSQL rejected reserved `pg_` schema names;
all 14 setup errors occurred before service mutations. Corrected test schema
prefix to `kiln_accept_`.

First full run: PostgreSQL 17.9 Homebrew arm64, 14 tests in 219.273s, 13 case
passes, one consent-disable failure (statuses 200x1, 201x3, 403x3, 503x1), plus
the source-freeze guard failed because the owner changed backend files during
the run. Disposable cluster `server.log:53` at 2026-09-14 15:59:55.240 ACST
confirmed PostgreSQL lock timeout for that 503. It was bounded fail-closed
backpressure, not observed consent bypass, but the strict normal-race test
remains failed. No final acceptance was claimed. The deliberate contention
case separately verifies the expected unavailable/retry contract.

This gate reports backend source SHA256s, PostgreSQL version, test count,
worker/status receipts, elapsed time, failures and schema cleanup. It is local
real-PostgreSQL API concurrency acceptance, not proof of the
hosted deployment, reverse proxy, backup/restore, Gunicorn resource limits or
native macOS client behavior. Those remain separate owner/parent release gates.

Second run: frozen core, 19 tests in 148.527s, 18 passes. All capacity and
credential/consent/duplicate tests passed. The eight-worker sustained account
burst produced 300x200, 18x429 and 2x503, confirmed lock timeouts at
`server.log:77,79` (16:04:03 ACST). The original exact-all-429 assertion failed.
Core was not changed or weakened to suppress this. In coordination with the
owner, exact-count sustained acceptance now uses the production topology of two
sync workers, while a separate eight-worker stress case explicitly validates
bounded unavailable/retry responses and the non-bypass ceiling. Short races
remain at 4-16 spawned workers. All at-cap cases use real measured sizes of
9,533,107 or 9,549,491 bytes against a configured 1,048,576-byte budget.

Third run: 20/20 PASS in 128.035s, zero skips, source-freeze guard passed.
Both the two-worker and eight-worker 320-request tests returned exactly 300x200
and 20x429. At-cap database sizes were 9,721,523, 9,696,947 and 9,705,139 bytes.
All credential/consent/event races passed. The intentionally held lock returned
the expected bounded 503 while the other schema remained available; subsequent
access recovered. Post-run read-only PostgreSQL checks reported zero remaining
`kiln_accept_<uuid>` schemas and zero `kiln-account` service connections.

Runtime: Python 3.14.4, psycopg/psycopg-binary 3.3.5, argon2-cffi 25.1.0;
PostgreSQL 17.9 Homebrew on arm64 macOS. Third-run source SHA256s:

```text
service.py f74ff8fc349d3a430b416314c611dcda4c5b55ed33f3af6901f1eca2fa881505
db.py 236dfeca19f872d5b9b83c31b3980f255150d86930f752c42bda12e558ac5c75
migrations/postgres/001_initial.sql f9634761d2c6a0cc214a1e64d02827901c342740c918a88e02079a227b383363
migrations/postgres/001_down.sql b7b42dfa0e86dcf43e91771fa7a3a147515d7c2bd75a3dd145a26f7aa7a3dc50
tests/test_postgres_concurrency.py edfeadf3de60bcf3dae6a4ee18b6d80a5b76189d195417fae7e683a3eb217d1a
```

The host owner subsequently reported a separate `db.backup` DSN expansion defect
in their real restore gate. That helper is not invoked by this concurrency suite.
The owner corrected it using native libpq environment metadata and structured
DSN parsing, stripping inherited connection settings, keeping credentials out
of argv, and bounding dump lock wait/process time. Read-only re-audit confirmed
the diff was confined to the new helper/import and backup invocation; runtime
connection/transaction/migration behavior and service/schema hashes stayed fixed.
Actual dump/restore verification remains the owner's separate gate.

## final receipt

2026-09-14, after the backup-helper correction: full 20/20 PASS in 73.987s,
exit 0, zero skips, source-freeze guard passed. The test file was unchanged from
the previous 20-case run. Final `db.py` SHA256:

```text
efbf1be9cb57713b3b588d3c61df2756a476e891fb3b1552f0c96cae164da431
```

All other third-run hashes above match the final run. PostgreSQL 17.9 remained
the same disposable local socket cluster. Key final receipts:

- Two-worker 320 reads: 300x200, 20x429; restarted workers 429; exact expiry 200.
- Eight-worker 320 reads: 300x200, 20x429; no unexpected 503 on this final run;
  the exhausted budget remained 429 after a five-second logical backoff.
- Duplicate events: 1x201, 7x200. Conflicting events: 1x201, 7x409.
- Quota two: 2x201, 6x409; four canonical retries all 200.
- Recovery race: 1x200, 7x401. Concurrent password changes: 1x200, 5x401.
  Password-change/login race issued six old-password login sessions before
  revocation; all seven old tokens were subsequently rejected with 401.
- Consent disable race: 1 settings 200, 5 inserts 201, 2 inserts 403; all six
  post-acknowledgment new/duplicate attempts were 403 and history was retained.
- At-cap PostgreSQL measured 9,508,531 or 9,533,107 bytes against 1,048,576:
  all four fresh uploads 503/storage_capacity; logout and consent disable 200;
  old token 401; history readable; new registration 503. Password change 200;
  at-cap recovery race 1x200/3x401; revoked credentials stayed invalid.
- Deliberately held scoped lock: bounded 503/unavailable, Retry-After5;
  other-schema registration 201; after release, normal own-schema access 200.
- Cleanup verified through read-only PostgreSQL queries: zero acceptance
  schemas and zero `kiln-account` service connections. All spawned workers
  joined/exited. Owner retains responsibility for disposable cluster shutdown.

The backend owner received the final hash/result before any release decision.
No claim is made here about hosted PostgreSQL 16, production peer-role grants,
physical reserve headroom, hosted dump/restore, reverse proxy or native client
acceptance. Those require the owner's independent release evidence.

Run from the account-service directory, only after the read-only control-plane
audit and explicit disposable-database selection:

```sh
env -i HOME=/Users/ari PATH=/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 \
  KILN_POSTGRES_ACCEPT_DISPOSABLE=1 \
  KILN_TEST_DATABASE_URL='host=/Users/ari/projects/kiln-app/account-service/.test-pg/socket port=55449 dbname=kiln_accounts_test user=kiln_test' \
  /Users/ari/projects/kiln-app/account-service/.venv/bin/python \
  -m unittest discover -s tests -p test_postgres_concurrency.py -v
```

Do not substitute a production DSN. Missing authorization/DSN is a hard failure,
never a skipped or SQLite-backed green result. All edits remain in the two
assigned new files; no commits, Swift builds or production commands were run.
