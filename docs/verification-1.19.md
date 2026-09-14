# 1.19 verification

This file distinguishes source, tests, deployed services, and the installed app.
It is not a claim of complete T3 product parity.

| Area | Current evidence | Remaining gate |
| --- | --- | --- |
| Native cognitive transport | Persistent JSONL, version discovery, bounded input/output, timeouts, EOF cleanup and wrong-ID rejection tested | Installed app connection |
| Scope and assumptions | Real Swift client to installed Mythic and isolated initialized Engram: missing file, revise, explicit action hold, evidence publication, process restart, repair/proceed, stale/hold | Rendered native interaction |
| Routine chat | Final suite: 141 tests, ten opt-in skips, zero failures, including actual native cognitive services | Installed app verification |
| Native T3 adaptation | 15 projection tests passed; response-scoped tool IDs prevent cross-turn collisions; pinned MIT notice included | Installed keyboard and visual acceptance |
| Remote adaptation | Desktop/mobile fixture passed; prior remote and rich-link tests passed unchanged | Final live remote verification |
| Account client | Deterministic tests and native Swift production TLS round trip passed: auth, profile, consent, replay, unknown counts, recovery and revocation | Real-user sign-in remains user-owned |
| Hosted accounts | PostgreSQL live at kiln.raya.ac; 60 host tests, 20 independent concurrency tests, real dump/restore and public profile checks passed; test accounts removed | Off-host backup and renewal-hook follow-ups documented in backend receipt |
| Runtime | Existing 1.18.0 app preserved during implementation | Build, install and verify 1.19.0 |

## native evidence

The first integrated run compiled successfully and ran 137 tests, with ten
opt-in skips. Two assertions in one real native cognition test exposed a path
canonicalization defect; the other suites passed. Foundation removes the
`/private` prefix from macOS temporary paths, while Python's `Path.resolve()`
does not. Kiln now uses POSIX `realpath`, rather than weakening scope checks.

The corrected seven-test cognitive suite passed, including the actual native
Engram/Mythic process chain. Its data lives only in a dedicated initialized
Engram verification store, not the user's normal memory store. A further test
proves that a child which never reads stdin cannot defeat the request deadline.

The test captures and checks real observation receipts, but does not execute a
build or model request on the user's behalf. A supported check certifies only its
concrete `checked_claim`; it does not certify arbitrary prose in an assumption.

## deployment correction

The initial account prototype used SQLite by implementation choice, not by a
user requirement. PostgreSQL is the required shared account database. Before
the correction, the prototype had started only on loopback. The domain file was
staged but never activated in Layerline. It had zero accounts, zero sessions,
zero usage events, and one rate-limit row. It was stopped and disabled, and its
empty database and staged domain file were preserved in a verified backup.

The hostname-specific Let's Encrypt certificate was issued and validated without
restarting Layerline. Certificate issuance alone does not make the account
service live. Refer to account-service deployment receipts for subsequent
PostgreSQL activation and exact source/runtime identities.

## deliberately separate

- Provider authentication belongs to Codex/OpenCode; Kiln accounts do not receive provider credentials.
- Public profile fields are public. Token usage is private and opt-in.
- Native memory, evidence, chat contents, paths and attachments are not synchronized to the account service.
- Local usage outbox storage and Mythic's local runtime are not the hosted account database.
- No full T3 virtualization, minimap, proposed-plan approval flow, or T3 permission policy is claimed.
- A local app bundle is not a notarized public release or an updated GitHub download.
