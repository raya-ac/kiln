-- Historical SQLite prototype only. Production uses migrations/postgres.
CREATE TABLE accounts (
    id TEXT PRIMARY KEY,
    handle TEXT NOT NULL UNIQUE COLLATE NOCASE,
    password_hash TEXT NOT NULL,
    recovery_hash TEXT NOT NULL,
    display_name TEXT NOT NULL,
    bio TEXT NOT NULL DEFAULT '',
    usage_sharing_enabled INTEGER NOT NULL DEFAULT 0 CHECK (usage_sharing_enabled IN (0,1)),
    created_at TEXT NOT NULL
);
CREATE TABLE sessions (
    token_hash TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);
CREATE INDEX sessions_account ON sessions(account_id);
CREATE INDEX sessions_expiry ON sessions(expires_at);
CREATE TABLE usage_events (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    event_id TEXT NOT NULL,
    payload TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    input_tokens INTEGER CHECK (input_tokens BETWEEN 0 AND 1000000000),
    output_tokens INTEGER CHECK (output_tokens BETWEEN 0 AND 1000000000),
    cached_input_tokens INTEGER CHECK (cached_input_tokens BETWEEN 0 AND 1000000000),
    reasoning_output_tokens INTEGER CHECK (reasoning_output_tokens BETWEEN 0 AND 1000000000),
    UNIQUE(account_id,event_id)
);
CREATE INDEX usage_account_sequence ON usage_events(account_id,sequence DESC);
CREATE TABLE rate_limits (
    key TEXT PRIMARY KEY,
    window_start INTEGER NOT NULL,
    hits INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);
CREATE INDEX rate_expiry ON rate_limits(expires_at);
PRAGMA user_version=1;
