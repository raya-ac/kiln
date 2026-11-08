# Security policy

## Supported versions

Kiln is pre-1.0 and moves fast. I only support the most recent release — if
you're on an older tag, upgrade first.

| Version           | Supported |
| ----------------- | --------- |
| Latest GitHub release | ✅ |
| Anything older        | ❌ |

## Reporting a vulnerability

**Please do not file public issues for security bugs.** Send an email to
**security@raya.li**. If you want to encrypt it, ask and I'll send a PGP key.

Include:

- A description of the issue and why you think it's a problem.
- Steps to reproduce, or a minimal PoC if you have one.
- Which version / commit you hit it on.
- Whether it's already public (sometimes people have already tweeted about
  it — that's fine, just tell me).

## What to expect

- I'll acknowledge receipt within **72 hours**.
- I'll confirm or reject it as a security issue within **7 days** and tell
  you which.
- If confirmed, I'll give you a rough timeline for a fix. For anything
  actively exploitable, that's measured in days; for less serious issues,
  the next normal release.
- I'll credit you in the release notes unless you'd rather I didn't.

## Scope

In scope:

- The Kiln app itself (binary, bundle, entitlements).
- The remote-control HTTP server (`RemoteControlServer`) — auth bypasses,
  rate-limit escapes, request smuggling, info leaks through error paths.
- The update path (Sparkle config, appcast signing, our release workflow).
- The native computer broker, MCP helper, approval panel, and per-turn grants.

Out of scope:

- The provider CLIs themselves; report those to their maintainers.
- Sparkle — report to the [Sparkle project](https://sparkle-project.org/).
- Attacks that require a malicious provider binary, a root-level attacker on
  the Mac, or physical access.
- Self-hosted warden-tunnel-server instances — the report should go to
  whoever runs that instance.

## Hardening notes (non-binding)

- The remote server binds to loopback by default; LAN and Tailscale are
  opt-in, and those binds refuse to start without a token.
- Bearer tokens live in the Keychain, are compared in constant time, and are
  rate-limited on failure (10 fails/60s → 60s lockout). Query-string tokens
  are not accepted. A public tunnel is treated as off-machine even though
  its packets arrive on loopback.
- Remote responses do not allow cross-origin reads. Header, body, time, and
  in-flight caps fail closed.
- Auto-updates are EdDSA-signed via Sparkle. The public key is embedded in
  the bundle Info.plist; the private key only lives on GitHub Actions.
- Computer access is nonpersistent and off by default. Sharing binds one window
  and model to a native chat. Every input action has a separate approval with a
  55-second deadline; Bypass does not skip it. Stop, interrupt, model changes,
  permission loss, window changes, and expired captures fail closed.
- The computer helper uses a loopback-only, bounded HTTP broker with ephemeral
  per-turn bearer tokens passed through the child environment, not arguments.
  Browser origins, ambiguous framing, and oversized requests are rejected.
  Remote sends cannot inherit native grants and there is no remote approval API.
- Screenshot payloads and proposed computer typing are removed from Kiln's run
  events. The active preview stays in memory. Backend sessions may still retain
  model inputs and outputs; this is not a provider-side retention guarantee.
- Computer input targets the selected process and requires a matching focused
  window. Secure or unidentified typing targets and clipboard shortcuts are
  blocked. This is not a sandbox: reviewed input can still have real effects.
