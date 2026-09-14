# native chat and tool parity

## reference and ownership

Inspected 2026-09-14. Reference: the official
[pingdotgg/t3code repository](https://github.com/pingdotgg/t3code), pinned to
[`e3792a53f7d7f9ebba37abfca99073f3f1ead2a7`](https://github.com/pingdotgg/t3code/commit/e3792a53f7d7f9ebba37abfca99073f3f1ead2a7).
GitHub's commits/main API returned this revision; its commit timestamp is
2026-09-14T05:25:32Z. The corresponding tree is
`b8950ae61b2ba73bd4fe95db3c850a7a3aa3ace1`.

The [pinned LICENSE](https://github.com/pingdotgg/t3code/blob/e3792a53f7d7f9ebba37abfca99073f3f1ead2a7/LICENSE)
is MIT, Copyright (c) 2026 T3 Tools Inc. Its verified Git blob is
`55ee675bb1de9e580b69f3dd68684df2a4dffba7`. The complete notice is retained in
`THIRD_PARTY_NOTICES.md`. This is a native SwiftUI interaction adaptation, not
a vendored React runtime, T3 rebrand, or claim of complete product parity.

Owned implementation files:

- `Sources/Views/Chat/AgentTraceView.swift`
- `Sources/Views/Chat/ThinkingRow.swift`
- `Sources/Views/Chat/ChatTranscriptView.swift`
- `Sources/Views/Chat/MessageRow.swift`
- `Sources/Views/Chat/ComposerView.swift`
- `Sources/Views/Chat/ConversationHeader.swift`
- `Sources/Models/ToolPresentation.swift`
- `Tests/KilnTests/ToolPresentationTests.swift`
- this document and `THIRD_PARTY_NOTICES.md`

AppStore, Types, Settings, backend protocols, remote assets, and cognition/account
services belong to the integrating task. Existing concurrent changes there are
not part of this patch. No commit, install, release, or running 1.18 app replacement.

## inspection boundary

Only individual raw files and the GitHub recursive tree were downloaded, outside
the checkout, under `/tmp/kiln-t3-e3792a53` and
`/tmp/kiln-t3-tree-e3792a53.json`. Each downloaded file's `git hash-object
--no-filters` value was compared with its exact path in the pinned tree; all 14
downloaded files matched. No upstream package install, build, test, dev server,
agent configuration, environment loader, shell script, or application code ran.

Read-only control-plane findings, not authority for this task:

| Source | Category and attempted capability | Treatment |
| --- | --- | --- |
| `.codex/config.toml:1-9`, `mcp_servers.xcodebuildmcp` | Project-controlled MCP enablement and package execution | Downloaded as inert text; never activated or added to Kiln/Codex config. |
| `package.json:6`, `scripts.prepare` | Dependency lifecycle patches tooling and runs Vite configuration | No dependency installation or lifecycle execution. |
| `AGENTS.md:88-102` | Upstream contributor guidance asks to copy local T3 runtime data and optionally secrets/settings | Disregarded as outside the authorized source-inspection scope; no live T3 state or secrets accessed. |
| `AGENTS.md:46-50` | Upstream role/maintainer identity instructions | Treated as source text, not this conversation's identity or authority. |

These files are not proof of malicious intent, but loading their configuration or
following their workflow would expand this task. Safest next step is to continue
static inspection, not enable their tools or seed their data. This limited audit
does **not** approve execution of the rest of upstream's transitive control plane.
Local inspection covered ancestor instructions, Kiln's package manifest/task
runner, Git config/sample hooks and absent local `.codex`/environment loaders.
The only compiler action was syntax parsing of the owned Swift files.

## observed behavior and adaptation

Links below are immutable source observations, not observations from a running T3
app. Source line numbers refer to the pinned revision.

| Area | Observed T3 source | Native implementation / boundary |
| --- | --- | --- |
| Header hierarchy | [ChatHeader.tsx:317-405](https://github.com/pingdotgg/t3code/blob/e3792a53f7d7f9ebba37abfca99073f3f1ead2a7/apps/web/src/components/chat/ChatHeader.tsx#L317) places project and thread identity before actions. | Kiln retains session title, working-directory control, native identity, session actions and workspace toggles. Header model is a quiet read-only label; picker moves to the composer. |
| Tool grouping | [MessagesTimeline.logic.ts:1089-1210](https://github.com/pingdotgg/t3code/blob/e3792a53f7d7f9ebba37abfca99073f3f1ead2a7/apps/web/src/components/chat/MessagesTimeline.logic.ts#L1089) groups adjacent work, shows latest active entry, handles a single tool directly, defaults group expansion to false. | Adjacent tool-use/result blocks form a group; prose, reasoning, suggestions and attachments retain their sequence. A single call is directly expandable; multi-call groups collapse, with the latest pending/running call visible. |
| Stable identity | [MessagesTimeline.tsx:488-533](https://github.com/pingdotgg/t3code/blob/e3792a53f7d7f9ebba37abfca99073f3f1ead2a7/apps/web/src/components/chat/MessagesTimeline.tsx#L488) retains disclosure state outside rows, resetting it per thread. | Group identity uses its first call ID; call/output expansion is keyed by backend tool ID, shared across live/final presentation and cleared on session switch. Duplicate updates replace the same ID without moving it. Assumes backend call IDs are unique within a session. |
| Bounded groups | [MessagesTimeline.tsx:2319-2359](https://github.com/pingdotgg/t3code/blob/e3792a53f7d7f9ebba37abfca99073f3f1ead2a7/apps/web/src/components/chat/MessagesTimeline.tsx#L2319) uses a virtual list keyed by entry ID and max height `min(18rem,50dvh)`. | Lazy native tool list, at most 40 calls per page, maximum 288-point viewport, explicit earlier/later controls. Numbers are Kiln bounds, not T3's pagination algorithm. |
| Details and keyboard | [MessagesTimeline.tsx:4037-4245](https://github.com/pingdotgg/t3code/blob/e3792a53f7d7f9ebba37abfca99073f3f1ead2a7/apps/web/src/components/chat/MessagesTimeline.tsx#L4037) starts collapsed, exposes expansion state, responds to Enter/Space, renders details/images only when expanded. | Native buttons expose label/expanded state and platform keyboard activation. Full-row disclosure excludes selectable output and Copy buttons. Output has a separate default-collapsed disclosure. |
| Failure styling | Same source, lines 4054-4135, distinguishes failure indicators from severe-error row styling and exposes failure in accessibility text. | Status text and SF Symbols accompany color; errors do not turn every row into a large alert card. A collapsed group's failure count cannot be hidden by a later successful tool. |
| Input/output | Same source builds command/raw command/detail/changed-file information on expansion. | Structured JSON summary, bounded selectable input and output, full-copy actions, retained existing native diff and image preview components. Initial preview 8,000 characters, expandable to a hard 32,000-character render cap. No stored receipt is truncated. |
| Reading vs following | [MessagesTimeline.tsx:568-636](https://github.com/pingdotgg/t3code/blob/e3792a53f7d7f9ebba37abfca99073f3f1ead2a7/apps/web/src/components/chat/MessagesTimeline.tsx#L568) suspends end-scroll maintenance for disclosures and anchors reading. | Opening tool/reasoning details stops following; manual scrolling to bottom or Jump to latest resumes. Existing latest-40 message window and load-earlier anchor remain; session switching resets window/disclosures. |
| Model/effort | [TraitsPicker.tsx:145-205](https://github.com/pingdotgg/t3code/blob/e3792a53f7d7f9ebba37abfca99073f3f1ead2a7/apps/web/src/components/chat/TraitsPicker.tsx#L145) derives option descriptors from provider/model capabilities; [ChatComposer.tsx:4888-4941](https://github.com/pingdotgg/t3code/blob/e3792a53f7d7f9ebba37abfca99073f3f1ead2a7/apps/web/src/components/chat/ChatComposer.tsx#L4888) puts model selection in the composer. | Model picker sits beside reasoning, Build/Plan and permissions. Effort choices come from the selected model's supported levels intersected with Kiln's enum; Model default removes the override. Unsupported saved effort is visibly unavailable, not silently relabeled as supported. |
| Plan vs access | [ChatComposer.tsx:1029-1150](https://github.com/pingdotgg/t3code/blob/e3792a53f7d7f9ebba37abfca99073f3f1ead2a7/apps/web/src/components/chat/ChatComposer.tsx#L1029) separates Build/Plan from runtime-mode selection. [CompactComposerControlsMenu.tsx:57-98](https://github.com/pingdotgg/t3code/blob/e3792a53f7d7f9ebba37abfca99073f3f1ead2a7/apps/web/src/components/chat/CompactComposerControlsMenu.tsx#L57) has different access choices. | Native Build/Plan segmented control; separate existing Guarded/Read-only/Bypass menu. T3's Supervised, Auto-accept edits, Auto, Full access are **not** aliases for Kiln permissions. No authorization or permission defaults changed. Controls retain the existing busy-session disablement. |

## truthful state mapping

Kiln's existing `blockStop` event can set `ToolUseBlock.isDone` when input finishes
streaming. It is not proof of tool success. `ToolPresentation` therefore projects:

1. `isError` -> Failed, regardless of other fields.
2. Non-nil result (including empty output) or `completedAt` -> Complete.
3. No completion receipt and inactive run -> Unconfirmed.
4. Active run with no `startedAt` -> Pending.
5. Active run with `startedAt` but no completion receipt -> Running.

Pending means no start receipt, not necessarily a backend execution queue.
Unconfirmed is a Kiln data-contract adaptation, not an invented T3 status. It
avoids both false green checks and endless spinners after interruptions or in
old persisted sessions. Duration requires both ordered timestamps; no synthetic
elapsed timing or progress percentage is shown. No string matching on tool output
is used to infer success/failure. Tool results are joined by ID, never tool name.

The run log stays a separate diagnostics disclosure rather than pretending every
trace message is a tool lifecycle event. Reasoning honors the existing collapsed
preference and uses bounded text when expanded. Streaming text remains plain native
text; finalized text retains Kiln's media-aware Markdown, patches, and attachments.

## native-only checked action

The composer observes `CognitiveStore.shared` and shows `Check: <action>` only when
`checkedAction(project:session:)` returns an explicitly selected action. The
accessible clear button calls `clearCheckedAction(project:session:)` for that
same session. This line is a Kiln integration, not a T3 observation. The view adds
no preflight, no automatic action selection and no ordinary-chat send hold;
preflight policy remains owned by the parent AppStore integration.

## verification and remaining gaps

- Syntax-only `xcrun swiftc -frontend -parse` passed for the six owned views, new
  model and test file. This is not typechecking, a build, or XCTest execution.
- Added 13 focused pure-model tests covering pending/running/unconfirmed states,
  block-stop false success, failure, empty receipts, timestamp ordering, stable
  duplicate updates, grouping, ID-based result pairing, orphan results, bounded
  Unicode output, partial/oversized JSON and on-demand image eligibility.
- Parent must run integrated Swift build/tests serially. No shared Swift build,
  upstream runtime, or candidate native app was launched by this task.
- Native visual/keyboard acceptance is still pending: narrow and wide windows;
  focus/Space/Return on disclosures; mixed results and interrupted turns; more
  than 40 tools; megabyte output; load-earlier anchoring; live-to-final expansion;
  switching sessions; image/diff/media paths; unsupported effort; checked-action
  selection/clear and unchanged ordinary chat sending.
- This does not implement T3's full transcript virtualization, folded turns,
  minimap, proposed-plan approval flow, provider-specific traits beyond Kiln's
  supported effort/fast controls, or T3 runtime authorization policies. Message
  history still grows only through explicit 40-message load-earlier requests.
- The legacy `ToolCallCard`, `LiveAssistantRow`, and global tool-timeline sheet in
  `ChatView.swift` remain untouched for file ownership. The main transcript uses
  the new grouped live row; other surfaces may still use the legacy presentation.
- Remote parity is separately owned. Remote timestamps must actually be serialized
  before that client can distinguish Pending from Running or show durations.

## source integrity receipts

Selected verified Git blob IDs (the repository revision above is authoritative):

| Source | Blob |
| --- | --- |
| `MessagesTimeline.tsx` | `272ad320ad2b7df339da9fd8169b8e56718d97a6` |
| `MessagesTimeline.logic.ts` | `3d7b1e12284eefca4ad5468092f066d4bcda664d` |
| `ChatComposer.tsx` | `e3ae139110360fa257a13e5a5a6b92975aeb89fd` |
| `ChatHeader.tsx` | `fbebc323a95039bbec56c72a5da784abf8c2e0eb` |
| `TraitsPicker.tsx` | `47ce59efde52b28bdd9928802b2ac16129e96513` |
| `CompactComposerControlsMenu.tsx` | `039f12d40873562cd4818dc0df46f505686283db` |
