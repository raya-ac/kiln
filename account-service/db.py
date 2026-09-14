"""Production PostgreSQL store and explicit migration/backup operations."""
from contextlib import contextmanager
import argparse
import os
from pathlib import Path
import subprocess

import psycopg
from psycopg.conninfo import conninfo_to_dict
from psycopg.rows import dict_row

SCHEMA_VERSION = 1
DEFAULT_MAX_BYTES = 1024 * 1024 * 1024


class CapacityError(Exception):
    pass


def connect(dsn):
    if not dsn or str(dsn).endswith(".sqlite3"):
        raise RuntimeError("PostgreSQL connection information is required")
    db = psycopg.connect(dsn, autocommit=True, row_factory=dict_row,
                         connect_timeout=5, application_name="kiln-account")
    db.execute("SET statement_timeout = '10s'")
    db.execute("SET lock_timeout = '5s'")
    db.execute("SET idle_in_transaction_session_timeout = '10s'")
    return db


def schema_version(db):
    if db.execute("SELECT to_regclass('schema_migrations') AS relation").fetchone()["relation"] is None:
        return 0
    return db.execute("SELECT COALESCE(MAX(version),0) AS version FROM schema_migrations").fetchone()["version"]


def check_capacity(db):
    maximum = int(os.environ.get("KILN_DATABASE_MAX_BYTES", DEFAULT_MAX_BYTES))
    if not 1024 * 1024 <= maximum <= 4 * DEFAULT_MAX_BYTES:
        raise RuntimeError("database write budget must be 1MiB..4GiB")
    used = db.execute("SELECT pg_database_size(current_database()) AS bytes").fetchone()["bytes"]
    if used >= maximum:
        raise CapacityError("database write-admission budget reached")


@contextmanager
def write_transaction(db, *, enforce_capacity=False):
    with db.transaction():
        # Serialize short writes across processes for atomic capacity/consent/
        # revocation accounting. Password hashing happens outside this lock.
        db.execute("SELECT pg_advisory_xact_lock(hashtextextended(current_database() || ':' || current_schema() || ':kiln-write',0))")
        if enforce_capacity:
            check_capacity(db)
        yield db


def migrate(dsn):
    with connect(dsn) as db:
        with write_transaction(db):
            version = schema_version(db)
            if version == SCHEMA_VERSION:
                return
            if version != 0:
                raise RuntimeError("unsupported schema version; refuse downgrade")
            tables = db.execute("SELECT tablename FROM pg_tables WHERE schemaname=current_schema()").fetchall()
            if tables:
                raise RuntimeError("nonempty unversioned schema: migration refused")
            script = (Path(__file__).parent / "migrations/postgres/001_initial.sql").read_text()
            db.execute(script, prepare=False)


def pg_environment(dsn):
    variables = {option.keyword.decode(): option.envvar.decode()
                 for option in psycopg.pq.Conninfo.get_defaults() if option.envvar}
    environment = {key: value for key, value in os.environ.items() if key not in variables.values()}
    for key, value in conninfo_to_dict(dsn).items():
        if key not in variables:
            raise RuntimeError("connection option cannot be represented for PostgreSQL tools")
        environment[variables[key]] = value
    environment.setdefault("PGCONNECT_TIMEOUT", "5")
    return environment


def backup(dsn, destination):
    environment = pg_environment(dsn)
    fd = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "wb") as output:
        result = subprocess.run(["pg_dump", "--format=custom", "--no-owner", "--no-acl", "--lock-wait-timeout=10s"],
                                env=environment, stdout=output, stderr=subprocess.PIPE, timeout=300)
        if result.returncode:
            raise RuntimeError("pg_dump failed; partial backup retained for inspection")
    check = subprocess.run(["pg_restore", "--list", str(destination)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if check.returncode:
        raise RuntimeError("backup archive validation failed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["migrate", "backup", "check", "prune"])
    parser.add_argument("--backup")
    args = parser.parse_args()
    dsn = os.environ.get("KILN_DATABASE_URL", "")
    if args.command == "migrate":
        migrate(dsn)
    elif args.command == "backup":
        if not args.backup:
            parser.error("--backup is required")
        backup(dsn, args.backup)
    else:
        with connect(dsn) as db:
            if args.command == "check":
                if schema_version(db) != SCHEMA_VERSION:
                    raise RuntimeError("schema mismatch")
                print("PostgreSQL schema check: PASS")
            else:
                with write_transaction(db, enforce_capacity=False):
                    db.execute("DELETE FROM sessions WHERE expires_at <= EXTRACT(EPOCH FROM now())::bigint")
                    db.execute("DELETE FROM rate_limits WHERE expires_at <= EXTRACT(EPOCH FROM now())::bigint")


if __name__ == "__main__":
    main()
