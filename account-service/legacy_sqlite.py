"""Held pre-production SQLite preservation only, not the service backend."""

import argparse
import os
from pathlib import Path
import sqlite3

SCHEMA_VERSION = 1
DEFAULT_MAX_BYTES = 1024 * 1024 * 1024
WAL_ADMISSION_BYTES = 64 * 1024 * 1024


class CapacityError(sqlite3.OperationalError):
    pass


def connect(path):
    db = sqlite3.connect(path, timeout=5, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("PRAGMA busy_timeout=5000")
    db.execute("PRAGMA synchronous=FULL")
    maximum = int(os.environ.get("KILN_DATABASE_MAX_BYTES", DEFAULT_MAX_BYTES))
    if not 1024 * 1024 <= maximum <= 4 * DEFAULT_MAX_BYTES:
        db.close()
        raise RuntimeError("database budget must be 1MiB..4GiB")
    page_size = db.execute("PRAGMA page_size").fetchone()[0]
    maximum_pages = maximum // page_size
    actual = db.execute(f"PRAGMA max_page_count={maximum_pages}").fetchone()[0]
    if actual > maximum_pages:
        db.close()
        raise CapacityError("existing database exceeds configured capacity")
    db.execute("PRAGMA journal_size_limit=16777216")
    db.execute("PRAGMA wal_autocheckpoint=256")
    return db


def backup(source, destination):
    destination = Path(destination)
    # Exclusive creation refuses accidental overwrite of rollback evidence.
    fd = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    with sqlite3.connect(f"file:{Path(source).resolve()}?mode=ro", uri=True) as src:
        with sqlite3.connect(destination) as dst:
            src.backup(dst)
            if dst.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise RuntimeError("backup integrity check failed")


def migrate(path, backup_path=None):
    path = Path(path)
    exists = path.exists()
    if exists:
        with connect(path) as db:
            version = db.execute("PRAGMA user_version").fetchone()[0]
        if version == SCHEMA_VERSION:
            return
        if version != 0:
            raise RuntimeError("unsupported schema version; refuse downgrade")
        if not backup_path:
            raise RuntimeError("existing database requires --backup before migration")
        backup(path, backup_path)
    else:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
    db = connect(path)
    try:
        db.execute("PRAGMA journal_mode=WAL")
        sql = (Path(__file__).parent / "legacy/migrations/001_initial.sql").read_text()
        db.executescript("BEGIN IMMEDIATE;\n" + sql + "\nCOMMIT;")
    finally:
        db.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["migrate", "backup", "check", "prune"])
    parser.add_argument("database")
    parser.add_argument("--backup")
    args = parser.parse_args()
    if args.command == "migrate":
        migrate(args.database, args.backup)
    elif args.command == "backup":
        if not args.backup:
            parser.error("--backup is required")
        backup(args.database, args.backup)
    else:
        if not Path(args.database).is_file():
            parser.error("database does not exist")
        db = connect(args.database)
        try:
            if args.command == "check":
                assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
                assert db.execute("PRAGMA user_version").fetchone()[0] == SCHEMA_VERSION
                assert not db.execute("PRAGMA foreign_key_check").fetchall()
            else:
                db.execute("BEGIN IMMEDIATE")
                db.execute("DELETE FROM sessions WHERE expires_at <= unixepoch()")
                db.execute("DELETE FROM rate_limits WHERE expires_at <= unixepoch()")
                db.commit()
        finally:
            db.close()


if __name__ == "__main__":
    main()
