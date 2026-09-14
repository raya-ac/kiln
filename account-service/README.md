# kiln accounts

Kiln's account backend uses PostgreSQL through psycopg3, with Argon2id passwords,
expiring bearer sessions, user-kept one-time recovery codes, stable public
profiles and private measured token history. This directory is the deployable
service. SQLite is not a production backend; the held prototype preservation
tool exists only to retain its pre-activation database.

Sign-in happens in the native app. Public pages use Kiln's existing brand asset
and escaped profile text. Handles are permanent; display names and bios can
change. Usage sharing starts off. Unknown counts stay null. The service has no
chat-content upload, email sender, price estimates or upstream API credentials.

## run and test

Python3.12+, PostgreSQL16+, a dedicated database/role, and a private Unix socket
or independently verified TLS connection. Production uses the existing host's
PostgreSQL16 through Unix peer authentication, with no database password stored
in an application file.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install --only-binary=:all: -r requirements.txt
export KILN_DATABASE_URL='host=/var/run/postgresql dbname=kiln_account user=kiln-account'
.venv/bin/python db.py migrate
.venv/bin/python db.py check
.venv/bin/gunicorn --config gunicorn.conf.py 'service:create_app()'
```

Gunicorn binds127.0.0.1:27480; Layerline terminates HTTPS. No startup auto-migration
and no fallback to SQLite. For tests, set `KILN_TEST_DATABASE_URL` to an explicitly
disposable PostgreSQL database and `KILN_POSTGRES_ACCEPT_DISPOSABLE=1`, then run:

```sh
.venv/bin/python -m unittest discover -s tests -v
```

Tests create randomly named owned schemas and remove only those schemas. They
exercise real PostgreSQL, real Gunicorn HTTP workers and independent processes;
no SQLite shim or mocked driver. Never point the test DSN at production.

- [API v1](docs/API.md): native contract, stable URLs, consent and retries.
- [deployment and rollback](docs/DEPLOYMENT.md): PostgreSQL operations and
  Layerline activation, with the exact held-prototype disposition.
- [host evidence](docs/HOST_EVIDENCE.md): certificate/route/reload observations.
- [security gate](docs/SECURITY.md): protections and explicitly remaining limits.

Passwords use pinned [argon2-cffi](https://argon2-cffi.readthedocs.io/en/25.1.0/api.html)
Argon2id64MiB/time3/lanes4. Session/recovery secrets are random256-bit values with
only SHA256 digests stored. Short mutation transactions use a schema-scoped
PostgreSQL advisory transaction lock to keep capacity, quotas, consent and
revocation atomic across workers; password hashing runs outside that lock.
This serializes writes intentionally and should be measured before high traffic.

Retained events are capped at100,000/account with explicit rejection, not silent
purging. Database writes pause at a configured1GiB admission budget. PostgreSQL
WAL, vacuum and physical storage are shared-cluster concerns, not falsely covered
by a SQLite page limit. The current proxy does not sanitize forwarded client IP,
so its shared peer signup5/hour cap stays conservative. Off-host encrypted
backup is not configured; verified local restore is not disaster recovery.
