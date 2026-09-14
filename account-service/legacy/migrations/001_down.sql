-- HISTORICAL SQLITE ONLY. DESTRUCTIVE: only for a disposable installation.
-- The held prototype is preserved; production now uses PostgreSQL.
-- Historical rollback restores
-- the pre-migration SQLite backup while the service is stopped (see DEPLOYMENT).
DROP TABLE usage_events;
DROP TABLE sessions;
DROP TABLE rate_limits;
DROP TABLE accounts;
PRAGMA user_version=0;
