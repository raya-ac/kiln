# kiln account api v1

Origin: `https://kiln.raya.ac`. API prefix: `/api/v1`.
All requests/responses use JSON and camelCase. Send `Content-Type: application/json`
and a content length for POST/PATCH, including `{}` for logout. Maximum body 8192
bytes. Unknown fields, duplicate JSON keys, NaN, booleans in integer fields,
invalid types and extra query parameters are rejected. No cookies, CORS, email,
password reset links, OAuth, chat upload, pricing, or unauthenticated usage API.

Private routes use `Authorization: Bearer <session.token>`. Store the token in
Keychain. Never put it in URLs, logs, analytics, or profile fields. HTTPS is
mandatory outside isolated local tests. Errors are always:

```json
{"error":{"code":"invalid_credentials","message":"Invalid credentials."}}
```

## account and session

```json
{
  "account": {
    "id": "a43d88ec-0a50-4080-804e-e2bfb0f397fc",
    "handle": "example",
    "displayName": "Example",
    "bio": "",
    "profileURL": "https://kiln.raya.ac/u/example",
    "usageSharingEnabled": false,
    "createdAt": "2026-09-14T06:00:00.000Z"
  },
  "session": {
    "token": "opaque-bearer-secret",
    "expiresAt": "2026-10-14T06:00:00.000Z"
  }
}
```

`id` and handle never change. Handle is lowercase ASCII `[a-z0-9_]{3,24}`; reserved:
admin, root, support, kiln, api, auth, settings, system. No silent normalization.
Display name: 1..80 Unicode characters. Bio: 0..500. Control characters,
surrogates and format/bidi controls are rejected. These are public plain text,
not Markdown/HTML. Passwords: 12..128 Unicode characters AND at most 128 UTF-8
bytes, no control/format characters; no truncation or whitespace normalization.

Sessions expire after 30 days, non-sliding. Maximum ten sessions per account;
the oldest is evicted on the eleventh login. There is no refresh token.

| Method | Path | Body | Result |
| --- | --- | --- | --- |
| POST | `/auth/register` | `{handle,password,displayName?}` | 201 `{account,session,recoveryCode}` |
| POST | `/auth/login` | `{handle,password}` | 200 `{account,session}` |
| POST | `/auth/logout` | `{}` | 200 `{ok:true}`, idempotent even expired/missing token |
| GET | `/me` | none | 200 `{account}` |
| PATCH | `/profile` | any nonempty subset `{displayName,bio}` | 200 `{account}` |
| PATCH | `/settings` | `{usageSharingEnabled:Bool}` | 200 `{account}` |
| POST | `/auth/password` | `{currentPassword,newPassword}` | 200 `{account,session}` |
| POST | `/auth/recover` | `{handle,recoveryCode,newPassword}` | 200 `{account,session,recoveryCode}` |

Changing a password revokes ALL sessions including the caller and returns a new
one. It preserves the user-kept recovery code. Recovery consumes the old code,
changes the password, revokes ALL sessions and returns a replacement code once.
Concurrent use of one code can succeed only once. A wrong code, wrong password,
or nonexistent valid handle returns identical 401 `invalid_credentials` and
comparable password-hashing work. Exact wall-clock timing is not guaranteed.
Handle availability is intentionally public (409 `handle_unavailable`).

There is no recovery-code lookup or email recovery. The client must ask the user
to retain the registration/recovery code outside Kiln and clearly explain loss.
If a password/recovery response is lost, log in with the new password. If the
rotated recovery code was lost, no replacement-code operation exists in v1;
this is a known support limitation, not an email fallback.

`GET /u/<handle>` outside the API prefix renders escaped HTML with a restrictive
CSP. Only handle/displayName/bio are public. No account IDs, timestamps, consent,
usage, sessions or provider/model identifiers appear there. Handles are immutable
after registration and cannot be reassigned through the API, so `profileURL`
remains stable across display-name and bio edits. There is no rename API.
`GET /` is a branded service entry linking the native app release page; browser
signup/sign-in is deliberately not implemented. `GET /logo.png` serves the
existing Kiln brand asset, bundled without external tracking or font requests.

## private measured usage

Consent defaults to false. Ingest requires current server-side consent. Turning
sharing off blocks subsequent inserts AND retries, but does not erase history.
The client must bind consent and durable outbox items to immutable account ID,
pause on logout/revocation/consent-off, and never replay one account's items into
another account. Authentication, not a body field, selects the owner. Capture
only when explicitly opted in; do not upload historical logs on first opt-in.

`POST /usage/events` accepts one immutable, non-overlapping measured request/turn
snapshot, not a cumulative session total or an evolving partial snapshot:

```json
{
  "eventId": "84965847-2cc3-4d9f-bcb3-155511fa6fc3",
  "sessionId": "a9811efb-741d-4061-bd4b-9aa96e23d859",
  "provider": "codex",
  "model": "gpt-5.5",
  "timestamp": "2026-09-14T06:00:00.000Z",
  "inputTokens": 42,
  "outputTokens": 12,
  "cachedInputTokens": null,
  "reasoningOutputTokens": null
}
```

- `eventId`, `sessionId`: ASCII `[A-Za-z0-9_-]{16,128}`. Random UUIDs or hex
  digests of locally scoped opaque identifiers work. Never send raw paths,
  session titles, prompts, completions, credentials or upstream session content.
- `provider`: codex or opencode (the actual supported harness). OpenCode vendor
  remains in its model identifier. Do not substitute a guessed provider.
- `model`: ASCII `[A-Za-z0-9][A-Za-z0-9._:/-]{0,95}` (1..96 chars). A model
  identifier, never a user-entered description or credential-bearing URL.
- `timestamp`: UTC RFC3339 with literal `Z`, seconds plus optional 1..6 fraction
  digits; >=2020-01-01 and <=server time+5 minutes. Stored at millisecond precision.
- All four counts independently optional/null or integer 0..1,000,000,000.
  Omitted and null are equivalent. Explicit measured zero remains zero.
  All-unknown events are allowed and remain unknown. Cached/reasoning counts are
  provider-defined subsets, never added to input/output to invent a total.
- No body `accountId` is accepted. No arbitrary metadata or price/cost fields.

201 `{eventId,duplicate:false}` on first insert; 200 `{eventId,duplicate:true}`
on canonical-identical retries. The unique key is `(authenticated account,eventId)`.
409 `event_conflict` for a changed canonical payload, even a null becoming known.
Persist the original outbound payload and retry it unchanged; never amend an
acknowledged event or send the same measurement again under a new ID. Mismatches
are permanent errors needing inspection, not retry loops.

Each account retains at most100,000 events. New distinct events at the quota
return409 `usage_quota_exceeded`; unchanged retries still succeed while opted in.
No history is silently purged, replaced, or converted to zero. Pause that outbox
and present the storage limit. PostgreSQL writes pause when the dedicated
database reaches its configured1GiB admission budget; this is not a filesystem
quota on the shared PostgreSQL cluster. Capacity exhaustion returns503
`storage_capacity` with Retry-After3600. It needs
operator attention, not aggressive retries. Existing history, exact retries,
logout, consent-off and password/recovery revocation remain available at this
admission budget. Authentication attempts still count against durable rate
limits, whose active key table is independently bounded at10,000 rows. Actual
host disk failure can still make any database operation unavailable.

`GET /usage/history?limit=50&before=123` returns:

```json
{"events":[{"sequence":122,"eventId":"...","sessionId":"...","provider":"codex","model":"gpt-5.5","timestamp":"2026-09-14T06:00:00.000Z","inputTokens":42,"outputTokens":12,"cachedInputTokens":null,"reasoningOutputTokens":null}],"nextBefore":122}
```

Newest ingestion sequence first. Limit 1..100 (default50); before is exclusive,
positive integer. `nextBefore` is null when exhausted. Events always contain all
four count keys, preserving nulls. Cursors are not authorization credentials.

`GET /usage/aggregate` returns `{eventCount,counts}`. Counts has each of the four
keys with `{knownTotal:Int?,knownEvents:Int,unknownEvents:Int}`. `knownTotal` is
the sum ONLY of known values, null when no event has that count. With mixed
known/unknown events it is a partial sum, not a complete total. Empty history is
`eventCount:0`, all knownTotal null, knownEvents/unknownEvents zero. No prices,
no cost estimates, no inferred counts, no cross-account grouping.

## errors and limits

400 invalid_request; 401 unauthorized/invalid_credentials; 403 origin_forbidden
or usage_sharing_disabled; 404 not_found; 405 method_not_allowed;
409 handle_unavailable/event_conflict; 413 request_too_large;
415 unsupported_media_type; 429 rate_limited with integer Retry-After;
503 unavailable with retry; 500 internal_error (generic, no exception details).

Persisted fixed-window budgets: all requests600/min/peer; authenticated
requests300/min/account; login+recovery30/15min/peer and10/15min/handle,
300/min/service; registration5/hour/peer and100/hour/service;
password change10/15min/account. Attempts count equally for existing/missing
accounts. Never retry before Retry-After. Back off transient failures, stop on
401, consent403, validation4xx or mismatch409.

The app ignores all forwarded-IP headers. With the proposed Layerline proxy,
the loopback peer budget is service-wide. This is a deliberate fail-closed
launch limit; do not enable public signup at scale until verified proxy header
sanitization supports distinct client-IP budgets. Limits persist across workers
and restarts. IP keys are SHA256 digests, not anonymous against enumeration;
short-lived rate rows expire after their window.

Health: `GET /healthz` -> `{ok:true,apiVersion:"v1",schemaVersion:1}`.
The production health response also includes `storage:"postgresql"`.
