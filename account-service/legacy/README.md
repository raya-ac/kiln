# held SQLite prototype

These SQL files and ../legacy_sqlite.py preserve the stopped pre-public prototype.
The account server imports only ../db.py, which uses psycopg/PostgreSQL and
../migrations/postgres. No automatic SQLite fallback or migration is provided.

The held host database contains zero accounts, sessions and usage events and one
health rate-limit row. It and its integrity-checked backup remain intact. See
docs/DEPLOYMENT.md for exact paths/hash; do not run destructive down migrations
against that preserved database.
