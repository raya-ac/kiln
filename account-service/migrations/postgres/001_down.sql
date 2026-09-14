-- Disposable schemas only. Production rollback uses pg_dump restored into a
-- NEW database followed by an explicit connection switch.
DROP TABLE usage_events, sessions, rate_limits, accounts, schema_migrations;
