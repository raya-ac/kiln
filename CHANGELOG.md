# Changelog

All notable changes to Kiln land here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Dates are
YYYY-MM-DD, versions follow [SemVer](https://semver.org/).

## [1.3.4] — 2026-04-21

### Added
- **Focus Mode** (`⌘⌥F` or `/focus`) — hides both side panels for a
  distraction-free chat column. Restores exactly what was open when you
  toggle back out.
- **Session Info** sheet (`⌘I`) — compact "about this session" popup:
  model, workdir, message count, tool call count, created / last-active
  timestamps, tokens from the current turn, fork lineage, tags. Session
  ID is one click away for scripts.
- `/memory` slash command — opens the engram dashboard
  (http://127.0.0.1:8420) in your default browser.
- Onboarding's engram step now lets you pick the binary path manually
  via a "Pick path…" file picker. Useful when engram lives in a custom
  venv, a mise/asdf shim, or a dev checkout outside the usual pip-install
  locations. The pick is persisted to `settings.engramPath` and the probe
  honors it ahead of the auto-detect candidates.
- Settings → Memory gains an "Engram binary" row exposing the same path
  override, with Pick / Clear buttons. Enabling engram while the system
  prompt is blank now auto-applies the engram primer so you don't have
  to copy it from docs.
- Keyboard shortcuts overlay lists the new bindings and slash commands.

## [1.3.3] — 2026-04-21

### Changed
- Engram (the optional cognitive memory system) is now **off by default**
  for new installs. Existing settings files preserve their current value.
- Default system prompt is empty for new users. The engram-primer prompt
  now lives in a separate constant and is only applied when a user opts in.

### Added
- Onboarding gains a fifth step dedicated to Engram: an in-depth
  explanation of what it actually does (memory storage, 5-channel hybrid
  recall, entity graph, decision/error tracking, local-first), the
  trade-offs, a detector for whether `engram` is installed, copy-
  pasteable install commands, and a toggle that wires the engram system
  prompt into settings on opt-in. Skippable with a single click.

## [1.3.2] — 2026-04-21

### Added
- Quick Open (⌘P) fuzzy file finder — BFS scanner with subsequence scoring,
  keyboard-nav, skip-list for `node_modules`/`.git`/build artifacts.
- Per-file git status markers in the file tree (M/A/D/U/?) with directory
  roll-up showing the strongest nested state.
- Branch pill + dirty-file count in the workdir header.
- "Show Diff vs HEAD" context-menu action on modified files — side-by-side
  LCS diff loaded from `git show HEAD:<path>`.
- "Ask Claude About This File" context-menu action on file rows — seeds the
  composer with a prefilled reference.
- Editor breadcrumbs: clickable path segments in the editor header replace
  the plain filename; last segment reveals in Finder.
- Live-tinted Dock icon: runtime-renders the Kiln mark using the user's
  accent color, re-renders on accent or appearance change. Dark-mode
  variant uses a near-black tile with the accent driving the flame.
- "What's New" popup: on first launch after an update, Kiln shows the
  release notes for the new version, read from the bundled CHANGELOG.

### Fixed
- Stale launch-recovery banner: sessions interrupted more than 4 hours ago
  no longer pester on relaunch. Banner now shows relative time ("3 hours
  ago") instead of a generic "last run" string.
- Dock icon size parity with neighbor apps — added a 10% canvas inset to
  match Apple's icon grid.

## [1.3.1] — 2026-04-20

### Added
- Onboarding flow for first launch — walks through CLI path, accent color,
  and permission primer.
- Live editor sync: external edits to an open file are picked up and
  merged without stomping in-flight unsaved changes.
- Accent-aware theme across the whole UI — sidebars, chips, selection
  highlights all re-tint when the accent color changes.
- Inline diff view for Claude edits — side-by-side LCS diff rendered in
  the editor.
- Editor keyboard shortcuts: save, close-tab, next/previous tab, reveal
  in finder.
- Claude edit Accept / Revert banner overlaid on modified files after
  an assistant edit.

### Fixed
- Settings toggles now re-render live instead of needing a reopen.
- File-tree context menu actions are reachable on nested rows.

## [1.3.0] — 2026-04-20

### Added
- Promotable editor: the file preview panel can promote to a full editor
  view with tabs, inline diffs, and keyboard-driven navigation.
- Claude brand avatar in the chat transcript.

### Fixed
- App bundle is now sealed (ad-hoc signed) even when no Developer ID is
  configured, so Gatekeeper stops complaining on first launch.

## [1.2.0] — 2026-04-20

### Added
- Embedded Monaco editor (the VS Code engine) via `WKWebView`, with Kiln's
  theme bridged in and file content routed through a local `kiln-host://`
  scheme handler.
- Git branch badge on each session row.
- "New Session Here" action in the file-tree context menu.
- Light mode across the whole UI.
- Session import / export.
- Web UI parity with the native sidebar — same session list, same actions.

### Fixed
- Bundle's `Frameworks` rpath is added explicitly so Sparkle loads inside
  signed builds.
- Monaco host page load is deferred until the web view is attached, and
  no longer relies on a private KVC path that tripped App Store review
  style checks.

## [0.1.0] — 2026-04-20

First tagged baseline. Everything below shipped pre-1.0 as part of getting
the repo into a publishable shape.

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
- Sparkle auto-updater with per-architecture builds (Apple Silicon + Intel).
- Unified tunnels view in Settings.
- Reconnect-with-backoff for warden tunnels.
- LICENSE, CODE_OF_CONDUCT, CONTRIBUTING, SECURITY, and issue/PR templates.
- Dependabot auto-merge workflow for patch/minor action bumps on green CI.

### Changed
- CI now runs `swift test` after `swift build`.

### Fixed
- Remote Control port field now commits on submit / focus loss and rebinds
  the listener if the server is already running.
- Tunnel listener rebinds on live config edits instead of needing a restart.

### Removed
- Old Iran briefing easter egg and the 21 MB video that shipped with it.
- Release-drafter (redundant with `generate_release_notes: true`).
