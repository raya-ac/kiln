# deployed account backend

Verified2026-09-14. Public `https://kiln.raya.ac` is PostgreSQL-backed, not SQLite.
The native application's local outbox remains independent of this backend.

## exact deployed state

- Release `/opt/kiln-account/releases/20260914-account-pg-v1-9dca1159d5aa`, current
  symlink activated to that release. Source archive31files, SHA256
  `6552c6ffabf59abaacb10867a19eefd46f09b7314a3af3f928f8aa707aec117c`.
- service.py SHA256 `f74ff8fc349d3a430b416314c611dcda4c5b55ed33f3af6901f1eca2fa881505`;
  db.py `efbf1be9cb57713b3b588d3c61df2756a476e891fb3b1552f0c96cae164da431`;
  PostgreSQL initial migration `f9634761d2c6a0cc214a1e64d02827901c342740c918a88e02079a227b383363`.
- Host PostgreSQL16.15, dedicated databasekiln_account and rolekiln-account.
  Peer auth over/var/run/postgresql; role has no superuser/createDB/createRole/
  replication rights,16connection cap. No DB password file or upstream tokens.
- Gunicorn2sync workers,127.0.0.1:27480 only; service userkiln-account,
  ProtectSystem=strict, NoNewPrivileges,512MiB cap, outbound network denied except
  loopback. Kiln maintenance timer enabled; oneshot prune Result=success.
- Layerline activation diff contained only the new Kiln domain. Admin-socket
  reload succeeded; originalPID1688792 stayed unchanged. All28original config
  hashes unchanged. Existing music.raya.ac/raya.ac/kai.ovh remained200.
- Trusted direct-origin TLS (--resolve, no insecure flag), edge HTTP/1.1 and
  edge HTTP/2 all returned health `{ok:true,apiVersion:v1,schemaVersion:1,
  storage:postgresql}`. No DNS or global proxy restart occurred.

## tests and player-visible path

Host final source:60tests,0failures,0skips in93.306s on PostgreSQL16.15. This includes
40owner baseline/HTTP tests and20independent concurrency tests. Separate final
independent20/20 passed in73.987s on local PostgreSQL17.9, with source hashes
unchanged. These are repeated cross-platform checks, not80distinct tests.

Both2worker and8worker320-request budget probes produced exactly300successes and
20429s on the final host run. Credential/recovery/consent/idempotency/quota races,
nullable/large-integer totals, and at-cap security operations passed. Earlier
local timeout observations remain documented in postgres-review.md; saturation
can intentionally return bounded503/unavailable with Retry-After5.

The public two-account smoke exercised real TLS, registration/login/me/profile,
consent-off/on, exact retries and mismatch409, account isolation, nulls,
password/session revocation and one-use recovery. Both exact owned accounts were
deleted with verified cascade cleanup and public profile404. Production counts
immediately afterward were0accounts/0sessions/0usageevents.

Main subsequently reported the native Swift URLSession production roundtrip
passed9.048s, including nullable aggregate, consent, replay and recovery. For its
exact authenticated fixture06ef897f-a8f2-4050-810c-64551f37f41e, this task queried
only public handlenative_b1b9c99f867c and inspected that profile in a real browser.
Desktop and390px mobile rendered the actual Kiln brand, display name and bio with
no horizontal overflow. Root page also passed visual/loaded-image checks.
Native fixture cleanup was subsequently explicitly approved and completed in a
PostgreSQL advisory-locked transaction matching BOTH that exact ID and handle.
Exactly one account was deleted; scoped account/session/usage counts afterward
were all zero. A server-side aggregate fingerprint of every other account row
was identical before/after; no other account content was returned. The exact
public profile returnedHTTP404 after commit. No second account was registered.

QA screenshots were displayed inline by the browser tool, not exported to
filesystem files. The browser session became unavailable after interruption;
there are no saved screenshot paths to claim or deliver. The desktop/mobile
observations above are the actual pre-cleanup visual verification, not a newly
recreated fixture or a fabricated screenshot artifact.

## restore and cleanup

Real pg_dump16.15/pg_restore16.15 into a NEW disposable database preserved
1account/1session/1usageevent, authenticated with the same bearer, matched exact
history/nulls and returned duplicate200 on the restored event.
Private root0600 backup directory:
`/opt/kiln-account/backups/20260914-account-pg-v1-9dca1159d5aa`.

- restore-probe.dump SHA256 `bc3fa7e3243e2bcf22b594a4a55ab32cee16768d8a08c071b48ff31a73ba8c9c`.
- pg-before-activation.dump `a7aab78eb7ea1444aad25414f872b86f3ad12fd7c63093f3cc8d3ac68feffb1f`.
- pg-activated.dump `f20230f59bd105a8efa19b818a056c787d47a7d56d02a3740b82e3d62415255c`.

The first dump attempt exposed that PGDATABASE does not expand an entire DSN;
the corrected helper maps parsed options through libpq's environment metadata,
strips unrelated inherited PG settings, and was regression-tested and re-reviewed
before the final gate. No production activation relied on the failed dump.

All five exact disposable host databases were removed after checking their
ownership and zero active connections. Only productionkiln_account remains.
Independent/baseline schemas were cleaned; local private test cluster stopped.
The never-public SQLite prototype and its verified backup remain preserved with
zero account/session/usage rows; see DEPLOYMENT.md for its disposition and hash.

## remaining boundaries

Off-host encrypted backup is NOT configured. Local restore does not cover host
loss. Forwarded-IP headers remain untrusted; signup5/hour peer cap is shared
behind the current proxy. The1GiB PostgreSQL setting is write admission, not a
physical quota or ENOSPC/WAL guarantee; host108GiBheadroom/autovacuum/WAL settings
were checked without global changes. Certificate hostname/chain validates to
2026-12-13, but Certbot did not persist suppression of the existing global
restart hook for future renewals. Review that lifecycle separately, without
silently changing global hooks. No commits were made by this backend task.
