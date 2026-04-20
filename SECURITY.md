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
- The PreToolUse hook surface.

Out of scope:

- Claude Code itself — report those to Anthropic.
- Sparkle — report to the [Sparkle project](https://sparkle-project.org/).
- Attacks that require a malicious `claude` binary, a root-level attacker on
  the Mac, or physical access.
- Self-hosted warden-tunnel-server instances — the report should go to
  whoever runs that instance.

## Hardening notes (non-binding)

- The remote server binds to loopback by default; LAN and Tailscale are
  opt-in.
- Bearer tokens are compared in constant time and rate-limited on failure
  (10 fails/60s → 60s lockout).
- Auto-updates are EdDSA-signed via Sparkle. The public key is embedded in
  the bundle Info.plist; the private key only lives on GitHub Actions.
