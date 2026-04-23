# Changelog

All notable changes to Kiln land here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Dates are
YYYY-MM-DD, versions follow [SemVer](https://semver.org/).

## [1.9.3] — 2026-04-24

### Added
- **Real GPT-5.4 Fast mode for ChatGPT-backed sessions.** Kiln's `Fast`
  button no longer swaps models or piggybacks on reasoning effort. For
  GPT-5.4 sessions it now maps to Codex's own fast mode settings, persists
  per session, and survives forks, clones, imports, and duplicates.

### Changed
- **Model branding now distinguishes Claude, ChatGPT, and Codex.** GPT
  models no longer inherit the generic Codex terminal treatment in the
  picker and chat chrome. Kiln now shows separate brand marks for Claude,
  ChatGPT, and Codex anywhere the active model is surfaced.
- **Assistant avatars now follow model brand instead of only provider.**
  ChatGPT-backed sessions look like ChatGPT sessions in the transcript and
  live response row instead of falling back to the same visual identity as
  Codex tool sessions.
- **Chat disclaimers now link to the right provider docs.** Claude sessions
  point to Anthropic's disclaimer page, while ChatGPT/Codex-backed sessions
  point to OpenAI's accuracy and limitations page.
- **Residual Claude-only UI copy was cleaned up again.** Remaining helper
  text in prompts, settings, shortcuts, and chat placeholders now uses
  provider-neutral assistant wording where the app is not specifically
  talking about Claude.

## [1.9.2] — 2026-04-22

### Changed
- **Codex sessions now respect Kiln's `Ask` permission mode more honestly.**
  Kiln passes Codex's own `on-request` approval policy through instead of
  silently treating most Codex sessions like bypass mode.
- **Codex resume no longer flips into `--full-auto` for plan sessions.**
  That behavior was backwards and could turn a read-only planning session
  into a more permissive execution mode after resume.
- **Codex `Deny` sessions now get an explicit no-tools instruction.**
  Read-only sandboxing was already in place, but the prompt now also tells
  Codex not to run shell commands or modify files.

## [1.9.1] — 2026-04-22

### Added
- **Codex edit-event bridging.** Codex `file_change` events now get mapped
  into Kiln's existing edit/tool runtime so changed files surface through
  the same editor flow Claude already uses for auto-open, pending edit,
  and diff/revert handling.

### Changed
- **Chat copy is more provider-neutral.** The main chat disclaimer now says
  `Kiln can make mistakes. Please double-check responses.` instead of
  claiming every session is Claude.
- **Codex sessions look like Codex sessions.** Provider-specific avatar and
  model icon treatment now show a terminal-style Codex mark instead of
  reusing Claude branding in the chat UI and model pill.
- **The remote control composer placeholder no longer says `Message Claude…`.**

## [1.9.0] — 2026-04-22

### Added
- **Codex CLI backend.** Kiln can now run Codex-backed sessions alongside
  the existing Claude ones instead of pretending every session is the same
  subprocess under the hood. Codex sessions use `codex exec --json`,
  persist their thread IDs for resume, and surface command executions in
  the same activity/timeline model Kiln already uses for tool calls.
- **Codex models in the picker.** `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.2`,
  and `gpt-5.3-codex-spark` are available anywhere Kiln chooses a model:
  defaults, new-session creation, template editing, and in-session model
  switching.
- **Provider-grouped model menus.** Model pickers now separate Claude and
  Codex into distinct sections instead of dumping every model into one flat
  row. It reads better, and it stops the UI from feeling like a pile of
  raw IDs once both backends exist.

### Changed
- **The app no longer overclaims that it is Claude-only.** The onboarding
  flow, stats hero copy, notifications, search results, markdown export,
  and key chat labels now use the active provider where it matters, and
  more neutral wording where it doesn't.
- **Workdir changes on Codex sessions now reset the saved thread mapping.**
  Claude transcripts can be migrated between workdirs because the resume
  files are path-scoped on disk. Codex resume threads are global, but the
  non-interactive resume flow doesn't expose a clean way to rebind cwd, so
  Kiln drops the mapping and starts fresh in the new directory instead of
  resuming under the wrong root.

### Notes
- **This is a first Codex pass, not full parity.** Codex `exec --json`
  doesn't stream token deltas the same way Claude does, so live text
  updates are coarser. Claude's PreToolUse approval flow also hasn't been
  ported across yet.

## [1.8.4] — 2026-04-21

### Fixed
- **Workdir migration now waits for the live subprocess to exit before
  copying** the CLI transcript. Previously `claude.kill` returned
  immediately while the child was still flushing writes to
  `<cliId>.jsonl`, so the copy at the destination could be truncated.
  Also migrates the sibling `<cliId>/` sidecar directory (subagent
  state, cached tool results) so agents don't lose their scratch data
  across a workdir move.
- **Migration refuses to clobber an existing destination transcript.**
  If `<cliId>.jsonl` already exists in the new workdir's project dir
  — say because a backup was restored — Kiln drops the mapping
  instead of silently resuming a different conversation. The next
  send starts a fresh CLI session in the new dir.
- **`/save` is now confined to the session's workdir.** Absolute paths
  (`/…` or `~/…`) and relative paths that climb above the workdir via
  `..` are rejected. The old behaviour would silently write anywhere
  the user could write, which combined with an untrusted code block
  was a real-world overwrite risk.
- **`lastCodeBlock` no longer drops content on an unterminated fence.**
  Interrupted or mid-stream replies often end without the closing
  ``` — `/save` and `/copycode` used to report "no code block" on
  visibly-present code. Now the open block is returned as the last
  one.
- **Slash commands that shell out now run off the main thread.** `/log`,
  `/branch`, `/checkout`, `/stash`, `/unstash`, `/blame`, `/find`,
  `/recent`, `/repo`, `/diffstat`, `/upstream`, `/changed` — all move
  to `Task.detached`. Previously they blocked the UI while `git` or
  `find` ran; on a large monorepo that was a visible beachball.
- **Translation polish.** Italian / Portuguese `forked` is now
  `biforcato` / `bifurcado` (was bare English `fork`). Korean
  `think` / `noThink` uses `생각` / `생각 안 함` instead of 사고
  (which reads as "accident"). Hindi time abbreviations gained the
  `पहले` suffix so they read as "N min *ago*". Russian `push`/`pull`
  now `Пуш`/`Пул` to match the translated `Коммит`. Taglines in
  Turkish, Polish, and Swedish dropped the anglicisms.

## [1.8.3] — 2026-04-21

### Added
- **Full UI translations for the ten new languages.** Italian,
  Portuguese, Russian, Korean, Dutch, Hindi, Arabic, Polish, Turkish,
  and Swedish now translate every label that German / Spanish /
  Chinese / French / Japanese already did — sidebar, composer,
  settings sections, git chips, activity panel, stats, relative
  timestamps, effort labels, the whole lot. Switching language in
  Settings now actually repaints the UI rather than only steering
  Claude's replies.

## [1.8.2] — 2026-04-21

### Added
- **Ten more languages** available in Settings → Language: Italian,
  Portuguese, Russian, Korean, Dutch, Hindi, Arabic, Polish, Turkish,
  Swedish. For these, Claude's chat output is steered into the chosen
  language via the system prompt; the Kiln UI stays in English (full
  UI translations only ship for the six previously supported locales).
  The settings description updates accordingly so it doesn't overclaim.
- **English flag is now 🇦🇺.** Because.

### Changed
- **Language picker is a native dropdown** instead of a scrolling pill
  row. The old layout squeezed each language name into a 40-pt pill
  and wrapped "English" into "Eng/lish" when the settings column was
  narrow. `Picker(.menu)` renders the selected flag + label at rest
  and drops a proper menu on click — same affordance as the model /
  mode / permissions rows above it.

## [1.8.1] — 2026-04-21

### Fixed
- **Changing a session's workdir no longer breaks the Claude CLI
  conversation.** Claude Code stores each conversation under
  `~/.claude/projects/<dashed-abs-path>/<cliId>.jsonl`, so the resume
  ID created in workdir A couldn't be resolved from workdir B — the
  next send errored with "No conversation found with session ID …"
  and the run aborted. Kiln now migrates the conversation file across
  project dirs when the workdir changes, so the same CLI session
  keeps resolving in the new location with full context intact. Any
  live subprocess is killed first (you can't chdir mid-run).
- **Pipe-drain deadlock in the shell helper.** `Process.waitUntilExit`
  before `readDataToEndOfFile` blocks when the child writes past the
  ~64 KB pipe buffer — `git status` in a dir with many untracked
  files hit this easily. Stdout and stderr are now drained
  concurrently via a DispatchGroup before we wait on exit.
- **Workdir activity scan guards a missing directory.** If the
  session's workdir doesn't exist or isn't a directory, `git status`
  is skipped instead of raising inside `Process.run`.

## [1.8.0] — 2026-04-21

### Added
- **Workdir activity chip** — above the composer, a small pill shows
  how many files have uncommitted changes in the session's workdir.
  Click it for a popover listing each file with its git status letter
  (`M`, `A`, `D`, `R`, `??`). Click a row to open the file's diff in
  the existing DiffSheet, or use the "Open all in diff" button for
  the combined view. The chip disappears when the tree is clean or
  the session isn't in a git repo — so it only draws attention when
  there's actually something to see.
- **Event-driven refresh.** The chip updates automatically when a
  response completes (the moment Claude's tools would have touched
  the disk) and when you switch between sessions. A tiny refresh
  icon handles the edge case where you ran `git stash`/`git commit`
  in Terminal and want Kiln to re-sync without waiting for another
  reply. No polling — we never run `git status` unless something
  actually happened that could have changed the tree.
- **Cmd+Opt+1..9 — jump to the Nth visible session** in the current
  sidebar tab (pinned first, then alphabetical, matching the list
  order). Modelled on the browser/VS Code tab-switching pattern.
  Cmd+1 / Cmd+2 are already bound to the code/chat tab toggle, so
  the option modifier keeps them distinct.

## [1.7.0] — 2026-04-21

### Added
- **31 more slash commands**, grouped:
  - **Workdir inspection:** `/ls`, `/tree`, `/grep <pat>`, `/find <pat>`,
    `/cat <file>` (capped at 400 lines), `/recent` (files touched in
    the last 24h). All inject results as a fresh user message so Claude
    has the context without having to shell out itself.
  - **Git extras:** `/repo` (remote + upstream), `/diffstat`, `/upstream`,
    `/changed` (porcelain list).
  - **Quick-inject into composer:** `/now` (timestamp), `/date`,
    `/clip` (clipboard → composer), `/paste` (clipboard → send now).
  - **App state / UI:** `/expand` (open multi-line editor),
    `/killall` (interrupt every busy session), `/readonly` (toggle the
    composer-hiding read-only flag on the session), `/accent <hex>`
    (live-change the accent color; validates 6-digit hex).
  - **Info toasts:** `/version`, `/age`, `/count`, `/sessions`,
    `/busy`, `/diag` (macOS / arch / CPU).
  - **Navigation:** `/random` (jump to a random non-archived session),
    `/bugs` (opens the issue tracker).
  - **Aliases:** `/duplicate` → `/clone`, `/star` → `/pin`,
    `/zen` → `/focus`, `/repeat` → `/retry`, `/compress` → `/compact`.
- `/grep` auto-prefers `rg` (Homebrew) when available and falls back
  to `grep -rn` otherwise — so the command works on a stock mac but
  gets the good results on a configured one.

## [1.6.0] — 2026-04-21

### Added
- **32 new slash commands** covering workdir, git, content and stats:
  - Workdir: `/pwd`, `/open` (Finder), `/terminal`, `/editor`,
    `/cd <path>`.
  - Git: `/log`, `/branch <name>`, `/checkout <name>`, `/stash`,
    `/unstash`, `/pull`, `/push`, `/blame <file>`.
  - Session metadata: `/pin`, `/archive`, `/tag <name>`,
    `/untag <name>`.
  - Content: `/copy` (last reply), `/copycode` (last fenced block),
    `/save <file>` (write last code block), `/share` (markdown to
    clipboard), `/quote` (quote last reply into composer).
  - Info: `/stats`, `/tokens`, `/env`.
  - Aliases & misc: `/undo` (= `/rewind 1`), `/resend` (= `/retry`),
    `/summary` (= `/title`), `/todo <text>` (appends to `TODO.md`
    in the workdir), `/notes` (opens `~/kiln-notes.md`), `/help`.
- `SlashCommandHelpers.swift` with a shell-safe argv-style `Process`
  runner plus clipboard / Finder / editor utilities and message-content
  extractors. No AppleScript, no `/bin/sh -c` — so arbitrary branch
  names, commit messages and file paths can't break out into shell.

## [1.5.3] — 2026-04-21

### Fixed
- **Tool image preview resolved against session workdir** — relative
  paths in tool input (e.g. `docs/img.png`) were resolved against the
  app's CWD, not the session's workdir, so previews silently failed.
- **Agent directory scan cached (5s TTL)** — the slash popup called
  `loadAgents()` on every keystroke, hammering `FileManager` to
  enumerate `~/.claude/agents/`. Now cached with a short TTL.
- **`/rewind` blocked during active generation** — rewinding mid-stream
  would have the runtime keep appending to a message we'd already
  dropped, corrupting session state. Now toasts "Stop generation first".

## [1.5.2] — 2026-04-21

### Fixed
- **Slash popup stale rendering** — conflicting identity signals
  (ForEach by `element.id` + row `.id(idx)`) kept old rows cached
  when the matches list shrank. Unified on positional identity so
  each row's body rebuilds with the current command.
- **Slash popup now shows all commands** when the input is just `/` —
  was capped at 8 entries; LazyVStack handles the full list fine.
- **Toast auto-dismiss race** — between sleep and wake, a manual
  tap-to-dismiss could cause the next queued toast to be skipped.
  The auto-dismiss now verifies it's still the active toast by id.
- **`/rewind` cap** — parse result clamped to [1, 50] so a typo
  like `/rewind 999` can't quietly shred a session.
- **DiffSheet performance** — switched to `LazyVStack` so a 10k-line
  diff doesn't blow out the view hierarchy on open.

### Added
- Toast feedback for `/rewind` — confirms how many exchanges were
  dropped.

## [1.5.1] — 2026-04-21

### Fixed
- **Slash-command filter ranking** — typing `/t` now surfaces commands
  whose label starts with `t` first, then contains `t`. Description
  text is no longer matched, so unrelated commands don't bubble up.
- **Enter on a fully-typed command runs it** — previously `/timeline`
  + Enter would re-insert the command with a trailing space, forcing
  a second Enter. Now if the typed text exactly matches the highlighted
  command, Enter executes it.

### Added
- **Toast notifications** — ephemeral feedback strip at the bottom of
  the window. Dismisses automatically or on click.
- **`/commit` reports outcome** — toast shows the new short hash on
  success, "Nothing to commit" when clean, or the failure reason.
- **`/diff`** — opens a sheet with staged + unstaged diff for the
  session's workdir. Plain text with +/- coloring, Copy button.
- **`/clone`** — duplicates the active session's shell (model, workDir,
  kind, instructions, tags, color, group) into a fresh empty session.
  Good for "same setup, new thread."

## [1.5.0] — 2026-04-21

Observability, git, and prompt ergonomics — a full feature sweep.

### Added
- **Tool-call timing** — every tool invocation is now stamped with
  `startedAt`/`completedAt`. The ToolCallCard header shows a compact
  monospace duration (`450ms` / `1.2s` / `2:05`) once the call
  finishes. Timestamps persist across session reloads.
- **`/timeline`** — opens a per-session tool-usage sheet. Each row
  shows the tool name, call count, a bar proportional to total time,
  total duration, mean duration, and any errors. Sorted by time spent,
  so the biggest spenders rise to the top.
- **Inline image previews** — when Claude writes or edits an image
  (`.png`/`.jpg`/`.heic`/`.webp`/`.svg`/etc.), the ToolCallCard renders
  the result inline. Double-click to open in the default viewer.
- **`/commit [message]`** — runs `git add -A && git commit -m …` in
  the session's workdir. No message → a dated `wip:` fallback. The
  branch badge refreshes right after.
- **`/status`** — injects `branch X, N uncommitted changes` as a
  user message so Claude sees the working-tree state without having
  to shell out for it.
- **Prompt templates (`/template` and `/t:name`)** — saved reusable
  prompt snippets, stored per-user. Seeds with `review`, `explain`,
  and `tests`. `/t:name` appears in `/`-autocomplete; invoking it
  drops the template body into the composer. Trailing args after
  `/t:name …` get appended as extra context.
- **`/rewind [N]`** — drops the last N message exchanges from the
  active session. Defaults to 1. Peels trailing tool/assistant blocks
  then one user turn per count — "undo N exchanges" as expected.

## [1.4.3] — 2026-04-21

### Added
- **`@file` picker in the composer** — type `@` anywhere in your prompt
  and a file-reference picker appears, listing files from the active
  session's workdir. Typing filters fuzzy-style (subsequence match with
  bonuses for prefix, word-boundary, and filename hits). Arrow keys
  navigate, Return/Tab picks, Esc cancels. Selecting inserts
  `@relative/path` — Claude Code treats the `@` prefix as a file
  reference, so the result is a direct handoff, no copy-paste dance.
- **Skips the noise** — the picker walks the workdir once (cached for
  10 s, re-walks on stale), pruning `.git`, `node_modules`, `build`,
  virtualenvs, IDE metadata and the usual suspects so a monorepo
  doesn't drown the dropdown.

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
