# remote tool and chat parity

The remote transcript follows the current native `ToolPresentation`,
`ToolActivityGroup`, and `ReasoningDisclosure` projection. It does not dispatch
tools or interpret a tool result as authorization. No server routes, index
template, Swift files, or main attribution files are owned by this change.

## reference

The native UX task supplied the official T3 Code pin
`e3792a53f7d7f9ebba37abfca99073f3f1ead2a7`, authored September 14, 2026.
The matching source was inspected read-only in `/tmp/kiln-t3-e3792a53`:

- [MessagesTimeline.logic.ts](https://github.com/pingdotgg/t3code/blob/e3792a53f7d7f9ebba37abfca99073f3f1ead2a7/apps/web/src/components/chat/MessagesTimeline.logic.ts#L1089): adjacent work groups, collapsed by default, latest active entry visible.
- [MessagesTimeline.tsx](https://github.com/pingdotgg/t3code/blob/e3792a53f7d7f9ebba37abfca99073f3f1ead2a7/apps/web/src/components/chat/MessagesTimeline.tsx#L4037): separate call/output disclosure and keyboard-accessible expansion.
- The same file at lines 2319-2356 bounds expanded lists; lines 488-533 retain per-thread disclosures.

This is a Kiln-native adaptation, not copied React implementation or complete
T3 feature parity. The native task owns the MIT attribution and full provenance
in `docs/t3-parity.md` and the project's notices. Permission modes remain Kiln's
existing modes; T3 access labels are not mapped onto them.

## implemented contract

- Only adjacent calls are grouped. Prose, reasoning, attachments and media keep
  their order. Standalone result blocks are paired by call ID; orphan results
  remain visible. Repeated IDs update their original position within a group.
- Single calls appear directly. Multiple calls default closed, with the latest
  pending/running call still visible. Failure counts stay visible when closed.
- Status precedence is Failed, Complete with a result or finite completion
  timestamp, Unconfirmed for a non-live call without a receipt, then Running
  with a finite start timestamp or Pending without one. An empty result is a
  receipt. `isDone` alone never means execution succeeded.
- `startedAt` and `completedAt` are optional numeric UNIX seconds, matching
  the parent's `toolUseJSON` update. A nonnegative elapsed interval is shown
  only when both fields are finite. Missing/invalid timing is not estimated.
- Group, call and output controls use native `details`/`summary`, explicit
  `aria-expanded`, focus rings, and Enter/Space activation. Disclosure state is
  isolated by session, message scope and tool ID, retained for up to 20 visited
  sessions in memory. Persisted messages use their own IDs, including legacy
  UUIDs; live tools use `assistant:<last-user-id>`, matching new final assistant
  IDs. Group/call/output keys, preview limits, pagination and render-cache
  signatures include that scope. Reused provider `item_` IDs cannot carry state
  between responses; live-to-final disclosures remain continuous. Legacy
  `data-disclosure` selectors remain unchanged.
- Expanded lists show 40 calls per page, initially the latest page, in a
  `min(288px, 50dvh)` viewport. Input/output DOM is created only when opened.
  Text previews start at 8,000 UTF-16 code units and grow to at most 32,000;
  their scroll region is at most 200px. Copy retains the full original text,
  including text outside the preview, with the existing clipboard fallback for
  HTTP LAN clients. Output is text, never raw HTML.
- Reasoning has its own disclosure, bounded preview and copy action. It shows
  Working while busy before answer streaming, then Complete, matching native.
  It starts collapsed unless the server supplies `thinkingCollapsedByDefault`
  as false. A collapsed disclosure retains the last-line preview.
- Live content is ordered reasoning, run log, tools, then prose. Semantic live
  block keys prevent an arriving log from replacing the running tool or prose.
  A trace-only terminal state remains visible after work stops.
- Recorded and live run logs share the 40-entry pager and bounded output
  renderer. A closed log renders only its count, warning/error counts and live
  label; an open page initially renders only entry headers. Expanding an entry
  shows an 8,000-to-32,000-unit JSON receipt containing every original field:
  `id`, numeric UNIX-second `timestamp`, `source`, `level`, `phase`, `title`,
  `detail`, and string-to-string `metadata`. Copy full receipt and Copy full run log serialize
  the unmodified entry/array, including off-page entries and unpreviewed text.
  Pagination or preview limits never truncate received state. An earlier page
  remains pinned when new entries arrive. The legacy `renderBlock.trace` path
  is lazy as well.
- A keyed reconciler updates changed message contents in place. Unchanged
  media figures and rich-link cards are opaque subtrees, including when prose
  or a tool changes in the same message. Audio/video seek state, document and
  embed iframes, metadata and nested output scroll positions are preserved.
- Polls preserve the visible transcript row's offset, including growth above
  it. Disclosure and manual scroll-away pause following; the existing Follow
  output button explicitly resumes it. Selecting text defers same-session
  rendering but never prevents clearing a switched session.
- The existing model button moves to the composer without changing the index
  template. Mode, permissions, provider effort, Fast, send/stop/retry, drafts,
  search, import/export, attachments, settings and mobile panels remain wired.
- Context percentage still uses backend occupancy, never aggregate token
  traffic. The tooltip exposes exact integer counts. Missing context stays
  unavailable; zero is valid. No context window is inferred from a model.
- Authenticated API calls reject cross-origin destinations and redirects.
  Bearer credentials and local media tokens are not appended to external
  media/embed URLs. Existing Markdown sanitization and embed allowlists remain.

## verification

Before tests, read-only inspection covered applicable instructions, repository
Git config and hooks (sample hooks only), absent project `.codex` configuration,
task runners, dependency manifests, environment-loader paths, executable
symlinks and shell startup files. No project setup, lifecycle scripts, hooks,
environment loaders or shared Swift build were run. Tests use non-login Bash,
the preinstalled Node/Playwright runtime and installed Google Chrome.

```sh
NODE_PATH=/path/to/runtime/node_modules /path/to/runtime/node scripts/test-tool-timeline.cjs
NODE_PATH=/path/to/runtime/node_modules /path/to/runtime/node scripts/test-remote-ui.cjs
```

`test-tool-timeline.cjs` assembles the real bundled HTML/CSS/JS and vendor assets
in memory. Playwright intercepts every request; it neither listens on a socket
nor accesses a running Kiln app. Its state, receipts and generated PCM audio are
synthetic. It writes desktop/mobile screenshots and a JSON result receipt to a
fresh OS temporary directory printed as `ARTIFACTS`.

Coverage includes all five tool statuses, paired and orphan results, duplicate
IDs, keyboard disclosures, lazy/full-copy/bounded output, grouping and paging,
reasoning, same-message audio playback and media/embed identity, a 183-message
scroll-anchor fixture, real timer polling, cross-session selection/disclosure
isolation, measured context, draft rejection/send, stop/error lifecycle, mobile
panels, 320/390/900/1100px layouts, light/dark/reduced-motion, auth denial,
cross-origin/redirect isolation and malicious text/Markdown.

The follow-up trace fixture adds 300 entries with 16,000-character details for
both recorded and live logs: closed-DOM bounds, 40-entry pages, lazy entry
receipts, full-copy equality including metadata, append/poll scroll stability,
tool/prose identity, native content order, trace-only completion, desktop/mobile
layout, and the serialized reasoning-default setting. `checkedAction` is not
consumed or displayed.

The retained remote regression's `[data-disclosure="m2:2"] summary` selector is
preserved; no parent test-selector change is required for single calls.

Verified September 14, 2026: the new fixture passed all nine assertion groups
with zero page errors (48 API requests and two isolated external fixture
requests). Its receipt and screenshots are in the printed temporary directory
`kiln-remote-parity-6GkB7s`: `results.json`, `desktop-expanded.png`,
`mobile-expanded.png`, and `mobile-light.png`. The unchanged
`scripts/test-remote-ui.cjs` passed, including the existing audio/video fixtures;
the unchanged `scripts/test-rich-links.cjs` also passed in deterministic mode
(`KILN_LIVE_EMBED_TESTS=0`). JavaScript syntax and scoped `git diff --check` passed.

The trace follow-up passed all ten assertion groups with zero page errors
(49 API requests, two isolated external requests) in `kiln-remote-parity-BgYMMR`,
including exact string-to-string metadata receipts. That temporary directory
also contains `trace-desktop.png` and `trace-mobile.png`. Both retained
regressions passed unchanged against the follow-up assets. JS/CSS are
source-frozen for the parent's release bundle.

## remaining boundaries

Focused collision regression: run `scripts/test-tool-timeline.cjs --scoped-tools`
with the same Node/Playwright runtime. It checks two legacy UUID responses with
identical tool IDs, independent disclosures/preview limits/copies, deterministic
live-to-final scope, next-turn cache invalidation, and the retained `m2:2` selector.

- This is browser-fixture acceptance, not a live remote-server or installed
  native-app acceptance run. Parent integration owns builds and live acceptance.
- The parent now serializes timing fields. Older servers remain readable but
  cannot provide Running or duration without a start/completion timestamp.
- Live trace entries and `thinkingCollapsedByDefault` use the parent's optional
  `/api/state` fields. Older servers without them keep recorded logs and the
  default-collapsed reasoning behavior. Native trace search and Issues filters
  remain native-only; all entries remain accessible remotely through paging.
- Native edit-diff and tool-local image previews are not synthesized from tool
  input paths. Remote media remains confined to server-issued references; an
  arbitrary tool path is not a new file-access capability.
- Outer transcript virtualization and native inspector redesign are not part of
  this patch. Unchanged message DOM is reused; expanded tool lists are paged and
  bounded. JavaScript preview limits count UTF-16 units, unlike Swift graphemes.
- Provider widgets are deterministic local responses in the new fixture. Their
  live availability and third-party playback are not claimed.
