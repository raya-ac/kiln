# PostgreSQL deployment and rollback

Production: psycopg3/PostgreSQL16, dedicated `kiln_account` database owned by
non-superuser login role `kiln-account`, matching the dedicated OS service user.
Use `/var/run/postgresql` peer auth already configured on the host. Do not change
pg_hba.conf, existing roles/databases, global PostgreSQL settings or passwords.
Application paths remain `/opt/kiln-account/releases/<release-id>` and atomic
`/opt/kiln-account/current`. No native SQLite outbox changes.

## held SQLite prototype

The prototype was never publicly activated. Its loopback service was stopped and
disabled at the architecture correction. Counts:0accounts,0sessions,0usageevents,
1ephemeral health rate row. The database remains untouched at
`/var/lib/kiln-account/accounts.sqlite3`, with integrity-checked backup
`/opt/kiln-account/backups/20260914-account-v1-2888e0c143fe/sqlite-held.sqlite3`,
SHA256 `ab7d347626652a2af96e00289d8168388768880a89a90630ba1381d7addd32cf`.
No user rows require import; the health counter remains in the preserved backup.
Do not restart the SQLite release or delete the retained database. Its domain
file was moved to that backup directory as `kiln.raya.ac.held.conf` before any
Layerline reload. Active Layerline diff returned no changes; PID1688792 unchanged.

## prerequisites and gates

Host PostgreSQL16.15 and local peer auth were inspected read-only. Existing
application databases include music, rhythm, zigcho and others; none is Kiln.
Create only the dedicated role/database, never reuse another application's role.
Role: LOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE, NOREPLICATION, connection limit16.
Revoke PUBLIC CONNECT/TEMP on the dedicated production database and public-schema
CREATE. Native connection string is server configuration, not client data.

Before production, run all baseline/HTTP tests and independent multi-process
tests on a separate test-marked PostgreSQL database, using isolated schemas.
Keep .test-pg, .venv, .test-tmp, dumps and caches out of source transfers.
`tools/package_release.py` emits source manifest/archive; compare SHA256 after
transfer, install pinned binary wheels in the new release venv, retain wheel
hash receipt, run pip check and tests under host PostgreSQL16.

All mutations use an explicit PostgreSQL transaction and a database+schema-scoped
advisory lock, with statement10s/lock5s/idle-transaction10s limits. The per-account
100,000event cap is race-safe. A per-transaction pg_database_size admission check
pauses new account/profile/usage writes at1GiB; logout, consent-off, credential
revocation, reads and health remain available, with durable auth limits and a
10,000active-rate-key ceiling. It is NOT a physical filesystem quota or a bound on shared
cluster WAL. Inspect existing autovacuum, WAL limits and filesystem headroom;
monitor database size and503 storage_capacity. Do not silently purge history.

## certificate and Layerline

Approved scoped HTTP-01 proof passed and was removed. Existing Certbot account
issued kiln.raya.ac only, no new TOS/provider/DNS/global renewals. SANhostname and
chain validate, expiry2026-12-13T05:10:25Z. See HOST_EVIDENCE for fingerprints.
Keep `/etc/letsencrypt/live/kiln.raya.ac/{fullchain,privkey}.pem` in the domain file;
never reuse the invalid self-issued raya.ac certificate.

Certbot did NOT retain directory_hooks=false in the new renewal config. Future
global renewal may call its pre-existing shared-restart hook. This remains an
explicit follow-up, not an authorization to rewrite global hooks. Current
activation uses the verified Unix-socket in-memory reload only:

```sh
python tools/layerline_admin.py validate
python tools/layerline_admin.py diff
python tools/layerline_admin.py reload
```

The expected diff is exactly `+ domain.kiln-raya-ac names=kiln.raya.ac`.
Recheck28original config hashes and original Layerline PID before/after. Do not
use systemctl reload/restart Layerline. Existing DNS already resolves through
Cloudflare. HTTPS200 fallback is not success: verify health.storage=postgresql,
branded root/PNG, profile CSP, private401 and HTTP/1.1 plus HTTP/2 behavior.

## activation sequence

1. Snapshot current release target, Kiln units/domain absence, original Layerline
   config hashes, PID and public music/raya/kai200 baselines. Preserve all held
   prototype assets. Stage new immutable PostgreSQL release, verify source/wheels.
2. Provision only the isolated test-marked database/role first. Run all real
   PostgreSQL tests, plus pg_dump/pg_restore into a NEW disposable database with
   stored account/session/usage readback. Remove only exact owned fixtures/DBs.
3. Create the production database only after gates pass, with its dedicated role.
   Run explicit migrations under the service OS user using KILN_DATABASE_URL.
   `db.py migrate` refuses nonempty unversioned/future schemas. Existing versioned
   databases require a verified pg_dump and reviewed migration before upgrade.
4. Atomically switch current, install only Kiln systemd units, daemon-reload,
   enable/start Kiln. Confirm peer-auth PostgreSQL identity, limits, loopback27480
   only, health.storage=postgresql. No public test before this gate passes.
5. Stage only the Kiln domain file, validate/diff, recheck original hashes, then
   admin-socket reload. Verify trusted direct-origin HTTPS with --resolve and
   normal edge HTTPS, unchanged Layerline PID and unrelated public statuses.
6. Run tools/live_smoke.py on the host as kiln-account with KILN_DATABASE_URL set
   and --base=https://kiln.raya.ac. This temporarily creates two test accounts,
   exercises auth/consent/idempotency/isolation/nulls/recovery, then deletes only
   their exact IDs+handles after password-ownership verification. Cleanup must
   cascade sessions/events and public URLs must404. Never delete by prefix.
7. Main may then run the native account fixture and supply its exact authenticated
   ID for separately authorized cleanup. Off-host encrypted backup remains
   unconfigured; no host-loss durability claim. Enable only Kiln maintenance.

## backup and rollback

`KILN_DATABASE_URL=... python db.py backup --backup /private/path/unique.dump`
uses pg_dump custom format with exclusive0600 creation, no credentials in argv,
and pg_restore catalog validation. Confirm actual restore with pg_restore into
a NEW isolated database before relying on it. Keep bounded private local copies;
off-host encryption/retention remains a separately reviewed operation.

On app-only failure with compatible schema, stop ONLY Kiln, atomically switch to
a known-good PostgreSQL release and restart Kiln. Never roll back to the held
SQLite prototype. On first public activation failure, remove only the newly
added domain file and use validate/diff/reload to return to the previous public
route state; retain DB, cert and failed release for investigation.

On schema failure, pg_dump the current state first for reconciliation. Restore
the pre-migration dump into a NEW database, verify schema/account/event counts,
nulls and authenticated readback, then explicitly switch the Kiln connection
configuration while stopped. Keep original production DB intact. Snapshot
rollback loses later writes unless reconciled; document the interval rather
than silently discarding usage. Never DROP/RESET a real existing database.
`migrations/postgres/001_down.sql` is disposable-schema-only, not production rollback.
