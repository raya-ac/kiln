# Changelog

All notable changes to Kiln land here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Dates are
YYYY-MM-DD, versions follow [SemVer](https://semver.org/).

## [1.4.2] — 2026-04-21

Everything-under-the-sun edition for the editor. If you can name it, Kiln
probably colors it now.

### Added
- **~45 more languages with syntax highlighting**, covering the weird, the
  old, and the experimental — each with a minimal Monarch tokenizer so
  keywords, strings, comments, and numbers render correctly:
  - Systems & new-wave: D, Ada, Pony, Hare, Chapel, Roc, Mojo, Jakt,
    Carbon, Wren, Squirrel, Haxe, GDScript.
  - Historical: COBOL, Forth, Rexx, Smalltalk, APL, Erlang.
  - Functional / ML family: SML, ReasonML, ReScript, PureScript, Common
    Lisp, Racket, Fennel, Janet, Hy, Prolog.
  - Theorem provers: Coq, Lean, Agda, Idris, Isabelle, F\*, Dafny, TLA+.
  - Shell / scripting: Fish, Nushell, AWK, SED, AutoHotkey, AppleScript.
  - Hardware & low-level: VHDL, x86/ARM assembly, WebAssembly text, LLVM IR.
  - Shaders: GLSL, HLSL, Metal, CUDA.
  - Infra / config: HCL (Terraform), Nginx, Apache, Caddy, systemd units,
    dotenv, Starlark/Bazel, Ninja, Meson, Just, Robot Framework.
  - Blockchain: Vyper, Move, Cadence, Clarity.
  - Docs / typesetting: LaTeX, AsciiDoc, BibTeX, Org, Typst.
  - Scientific / stats: MATLAB, Wolfram, Stata, SAS.
  - DSL / niche: Pine Script, Groovy.
- **Graceful passthrough** for unknown language ids — the editor hands
  whatever the filename suggests straight to Monaco. Registered languages
  color; unregistered ones render as plaintext instead of getting
  intercepted and funneled to "plaintext" on the Swift side.

## [1.4.1] — 2026-04-21

A follow-up patch — stability, session persistence, and the editor gets
a wider vocabulary.

### Added
- **Syntax highlighting for a dozen more languages** — Zig, Nim, Odin,
  Elm, Haskell, OCaml, Fortran, Nix, Makefile, CMake, Gleam, Crystal.
  Monaco doesn't ship tokenizers for these, so Kiln now registers a
  minimal Monarch grammar (keywords, strings, comments, numbers) at
  editor init — enough to make the file read as code instead of a wall
  of identical foreground bytes.

### Fixed
- **Active session persists across restarts** — the session you were
  last working in is restored on launch instead of dropping back to a
  fresh "New Session" pane.
- **Claude CLI resume IDs persist** — the `claude --resume <id>` tie
  now survives a quit, so continuing a conversation after reopening
  Kiln actually continues, instead of starting a brand-new chat.
- **Diff viewer for new files** — captures the pre-edit content before
  the streaming Write clobbers it, so the left column shows the real
  original instead of matching the right column.
- **Diff viewer fills the pane** — no longer centered/squeezed into a
  narrow column when the editor is wide.
- **Interrupt banner** — stops falsely claiming a session was
  interrupted after a clean restart.

## [1.4.0] — 2026-04-21

A meaty milestone release — a batch of session-management and composer
quality-of-life features, plus a model-lineup trim. The ambition of
"a hundred features" was politely refused: shipping a pile of broken
polish is worse than a tight, solid batch. So this one is a real 1.4.

### Added
- **Color filter** in the sidebar header — narrow the list to sessions
  wearing a specific color label, or "Any color" to turn it off. Sits
  next to the sort menu; stays out of your way when you don't need it.
- **Bulk color** and **Bulk merge** in the multi-select toolbar.
  Color-stamps every selected session in one shot, or collapses them
  into the oldest — messages are concatenated in chronological order
  and the absorbed sessions are deleted.
- **Context menu merge** — "Merge into active session" on any sidebar
  row uses the bulk path to keep logic single-sourced.
- **Copy kiln:// link** (`⌘⇧L`, context menu, `/link`) — puts a
  `kiln://session/<id>` URL on the clipboard for deep-linking back
  into the app from notes, Linear, or another Kiln window.
- **Reload from disk** (`⌘⌥R`, `/reload`) — re-reads every session
  file. Useful when an external tool or the remote control API edits
  state behind the window's back.
- **Session age badge** in sidebar rows — shows "N days old" once a
  session passes seven days, so long-lived workhorses read distinct
  from sessions spun up today.
- **Composer clear-draft button** — one-click `×` on the hint strip
  wipes the input when you want to start over.
- **Token estimate in the composer** — rough `~N tok` alongside the
  existing char / word count. Four-chars-per-token heuristic; close
  enough to gauge prompt cost before you send.
- **New slash commands** — `/reload`, `/color <name>`, `/merge`,
  `/link`, `/rename <new name>`. All documented in the shortcuts
  overlay.

### Changed
- **Model lineup trimmed** — Opus 4.6 retired from the picker. Opus
  4.7 is now the sole flagship tier; Sonnet 4.6 and Haiku 4.5 remain.
  Existing Opus 4.6 sessions will need to be reassigned via `⌘⇧M` or
  the header picker on next use.

## [1.3.6] — 2026-04-21

### Added
- **Session color labels** — right-click a session → Color to tag it
  with one of six fixed presets (red, amber, green, blue, purple,
  pink). A small dot appears next to the name in the sidebar for
  at-a-glance grouping. Chose fixed presets over arbitrary hex so the
  dots stay legible against both light and dark row backgrounds.
- **Duplicate with messages** — new sidebar context menu entry that
  forks a session, carrying over the full message history, tags,
  session instructions, and color. The original is untouched. The
  existing "Duplicate (empty)" stays for when you only want the config.
- **Cycle Model shortcut** (`⌘⇧M`) — rotates the active session
  through the available Claude models without opening the picker.
  Handy for retrying the last prompt on a stronger model.
- **Composer character / word count** — subtle monospaced counter on
  the right edge of the composer hint strip. Only rendered while the
  draft is non-empty so it stays out of the way.

## [1.3.5] — 2026-04-21

### Added
- **Bottom status bar** — persistent one-line strip across the window
  footer. Shows active model, workdir basename (click to reveal in
  Finder), last-turn token totals with compact k/M formatting, a busy
  indicator while Claude is working, an engram on/off pill (click to
  open Settings), and the total session count.
- **Sidebar session sort** — new menu in the sidebar header with four
  modes: Manual (pinned-first, then list order), Recent activity, Name
  (A–Z), and Created. Pinned sessions always surface first regardless
  of sort. The choice persists across launches.
- **Inline tag editor** in the Session Info sheet — existing tags render
  as removable chips in a wrapping flow layout; a free-text field
  commits new tags on Return. Tags feed the sidebar filter.
- **Archive / Unarchive shortcut** (`⌘⌥A`) — toggles archive state on
  the active session without hunting for the menu item.

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
