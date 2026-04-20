# Changelog

All notable changes to Kiln land here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Dates are
YYYY-MM-DD, versions follow [SemVer](https://semver.org/).

## [Unreleased] — targeting 1.0.0

First major release. The repo is being polished for public consumption
in waves; each wave lands as a discrete commit on `main`.

### Added
- `VERSION` file at repo root as the single source of truth for the version
  string. Read by the Makefile, `make-app-bundle.sh`, and the About panel.
- Test target (`KilnTests`) + smoke tests for the version pipeline and
  internal model types. Wired into CI via `swift test`.
- About panel in Settings now reads `CFBundleShortVersionString` from the
  app bundle, with a dev fallback to the repo-root `VERSION` file when
  running uncompiled via `swift run`.
- "Copy Session ID" action in the sidebar context menu — useful for cross-
  referencing sessions in scripts, bug reports, and the remote-control API.
- `make version` and `make tag` targets.

### Changed
- CI now runs `swift test` after `swift build`.

## [0.1.0] — 2026-04-20

First tagged baseline. Everything below shipped pre-1.0 as part of getting
the repo into a publishable shape.

### Added
- Sparkle auto-updater with per-architecture builds (Apple Silicon + Intel).
- Unified tunnels view in Settings.
- Reconnect-with-backoff for warden tunnels.
- LICENSE, CODE_OF_CONDUCT, CONTRIBUTING, SECURITY, and issue/PR templates.
- Dependabot auto-merge workflow for patch/minor action bumps on green CI.

### Fixed
- Remote Control port field now commits on submit / focus loss and rebinds
  the listener if the server is already running.

### Removed
- Old Iran briefing easter egg and the 21 MB video that shipped with it.
- Release-drafter (redundant with `generate_release_notes: true`).
