# 1.25 verification

Local candidate evidence, 2026-11-08. This is not a published release or a
claim that the account service has been deployed.

The Studio-only publish snapshot is on `studio-delivery`, based on
`53dfd2f`. Evidence below describes the earlier full local candidate unless
explicitly identified as a publish-snapshot check. Account-site, Antigravity,
and local-only model aliases are excluded from this snapshot. Native account
credential responsiveness fixes and the requested Grok integration remain.

## Publish Snapshot Checks

- Hosted run `42453359096` passed for `dcec629`: 210 tests, zero failures,
  13 opt-in skips, with arm64 and x86_64 candidate bundles. Both downloaded
  bundles passed strict deep signature checks and architecture inspection.
  The arm64 candidate `1.25.0-ci.93` was installed at
  `/Users/ari/Applications/Kiln.app`, after backing up the previous app and
  Kiln data. Intel execution remains untested.
- CI93 recognizes both macOS grants after the user re-added the installed
  copy. The packaged MCP helper passed initialize, all six tools, inactive
  observe denial, and EOF shutdown. A real Sol read-only discovery probe
  found `mcp__kiln_computer__status` and received the expected inactive
  result without sharing or input.
- A user's shared-window request chose unrelated general desktop tools
  despite Kiln's MCP launch configuration. The follow-up adds selected-window
  guidance to active turns and MCP initialization. Its per-turn server is
  required; a deliberately failing-server CLI probe exited before starting
  a turn, confirming that startup cannot silently omit the connection.
  The follow-up's local test attempt stopped before tests because the volume
  was full. Hosted verification is required; no test pass is inferred.
  Real selected-window observation and user-approved input remain pending.
  Fresh focused Astra review passed after correcting stale status and an
  overstated routing claim, review `01a1b9d2-e14c-79d0-a53f-6142cfc0dfb1`.
  Its rollout metadata identifies `gpt-6-astra` at high effort. Changed Swift
  files pass syntax parsing; this does not replace the pending full suite.
- Default SwiftPM engine: 210 tests, zero failures, 13 opt-in skips. The
  isolated checkout uses the upstream pinned SwiftTerm 1.99.2 dependency.
- Four opt-in live checks passed without skips: Sol image input on new and
  resumed turns, Fast mode, installed model discovery, and read-only CLI
  update checks. Codex was 0.167.0; OpenCode 2.0.22 reported newer than stable.
- A fifth live check passed in 26.2 seconds: a new synthetic read-only Sol
  conversation replied, completed actual in-place backend compaction, and
  replied again with the same backend thread mapping. No existing user chat
  was compacted. This exercises the real compactor, not a mocked completion.
- Rendered two-origin media checks repeated at 1280px and 390px using a fake
  bearer. The legitimate image decoded, the redirect preview failed closed,
  and forged hydration/open/download controls sent no external requests.
- Palette results now use the item identity for both rows and scrolling,
  expose Button semantics, and offer Compact context for idle supported chats.
  Native navigation and composer shortcuts have separate accessibility IDs.
  Unit coverage passed; acceptance in a newly packaged native client remains.
- Review-driven regressions cover same-process overlapping windows, per-chat
  preview/history isolation, prelaunch Grok attachment rejection, scoped
  listener startup cancellation and background approval identity. The listener
  tests pause readiness deterministically rather than depending on timing.
- The computer panel refreshes permissions on app activation and reports all
  blockers. The running Studio.11 build is ad-hoc signed with a code-hash-based
  designated requirement, so grants to earlier builds may not cover this copy.
  That diagnosis is not proof of the user's saved TCC grant state.
- Duplicate desktop Settings/Tools controls were checked in the rendered web
  fixture. Mobile retained Settings in its session drawer and Tools in its
  header; Escape closed the drawer. Native Return/Escape and the updated
  computer panel still require packaged-client acceptance.
- The later rendered edge checks verified Stop and Retry request bodies naming
  the displayed chat, tool copying under a disabled Clipboard API policy, and
  mobile Settings Escape leaving its parent drawer open with focus restored.
  A second Escape closed that drawer. Listener startup timeout, stale capture
  isolation, and setup cancellation passed dedicated native regressions.
- Concurrent mutating requests now return busy without consuming the capture
  for an approval already on screen; a regression approves the original and
  verifies exactly one synthetic dispatch. All remote copy commands share
  truthful feedback. Message/path copying passed the disabled-Clipboard-API
  fixture. At 1024px, Escape from inside Tools restored the visible toggle;
  at 390px, nested Escape restored Settings, then the Sessions opener.
- CI is configured to retain arm64 and x86_64 candidate bundles, identified by
  the exact source commit. Check the hosted run and artifact for the commit
  being installed; a source-review pass alone is not a successful build.
- The separate, locally installed Engram runtime now probes Metal before
  importing MLX. Under a profile denying network and IOKit access, 142
  embedding/fallback/reranker tests passed, and an isolated stdio MCP process
  completed CPU model warmup, initialize, an 80-tool listing and status, then
  exited successfully. A normal GPU process still selected MLX and produced
  a finite normalized 384-dimensional embedding. No production database,
  provider credentials, or sandbox permissions were changed. Focused actual
  `gpt-6-astra` review passed after correcting over-broad forced CPU placement.
  That runtime patch is separate from this Kiln Git snapshot.

The publish snapshot's final focused source gate passed with no remaining
P1/P2 findings. The fresh visible reviewer explicitly used `gpt-6-astra`,
review ID `01a1b9bb-0fce-74a1-8595-f9ffbaf519e8`. It followed fixes and
re-review of the earlier overlap, isolation, cancellation, copy, and drawer
findings. Earlier candidate evidence below is a separate checkpoint.

The first hosted Xcode 26 build exposed compiler inference differences in
tool-search concatenation and Grok's synthesized stream initializer. Both
were made explicit without changing behavior; the 210-test suite passed
again. Fresh focused Astra review also passed, review ID
`01a1b9c1-f810-74e3-9513-525c6d3cf4cd`. The replacement hosted run remains
the release-compiler verification.

Studio.11 must not be used for computer-input acceptance: the subsequent
publish-snapshot review found a pointer-targeting issue with overlapping
same-process windows. Its source fix and regression are in this snapshot,
not that installed binary. The latest snapshot review is a fresh visible
`gpt-6-astra` subagent, not an unstarted or implied CLI review.

## Earlier Candidate Evidence

- Native suite: 196 tests, zero failures, 12 opt-in skips, using
  `swift test --build-system native`.
- Remote UI: desktop dark/light, 390px mobile, and both sides of the
  900/901px navigation breakpoint. Code/Chat switching, panel selection,
  tool filtering, reasoning, Fast mode, compaction settings, and rejected
  send draft recovery were exercised through the rendered UI.
- Remote media: a two-origin loopback fixture used a fake bearer. Forged
  hydration/open/download attributes and cross-origin redirects produced
  zero requests at the receiving origin. A legitimate local image decoded;
  local media and export downloads reached the authenticated local routes.
- Native Studio.3: window opened after the Keychain startup fix. Sessions
  and inspector controls both exited Focus mode correctly. Seven flame
  clicks showed the local easter egg without sending a model request.
- Studio.4's live chat check exposed an async-entry-point main-actor stall.
  Its queued send did not launch; do not use it as chat acceptance evidence.
  Studio.6 passed the replacement check: a real read-only GPT-6.1 Sol send
  advanced past the countdown and displayed `KILN_STUDIO_OK`, with backend
  context occupancy reported. The native Fast control appeared after live
  catalog discovery. A second turn returned the same marker and retained
  the exact backend thread ID. No computer grant was enabled.
- Studio.6 opened an existing 123-message conversation and scrolled five
  pages up, six more up, and eight down without a crash, then returned to
  the acceptance chat.
- Studio.8 reopened that acceptance chat and completed a third read-only
  Sol turn after restart, retaining the same backend thread and showing
  six messages with measured context occupancy.
- Final candidate: `1.25.0-studio.11`, staged separately under
  `.tmp/studio-candidate-11/arm64/Kiln.app`. The exact running executable,
  bundle version, strict deep signature verification, and bundled remote
  JS/CSS hashes were checked. Its fourth read-only Sol reply retained the
  same thread, bringing the acceptance chat to eight messages. Fast mode
  remained available and context occupancy was measured by the backend.
- Studio.11 repeated the existing 123-message chat scroll check: five pages
  up, six more up, and eight down without a crash, then restored the
  acceptance chat. Its final screenshot is under
  `.tmp/computer-verification/visuals/studio-native-desktop.png`.
- The packaged Studio.6 MCP helper returned initialize and six tools,
  rejected a call without an active grant, and exited with status 0 on EOF.
  Studio.8 and the final Studio.11 candidate repeated that packaged-helper
  check successfully.
- Focused regressions cover cancelled Warden retries, late callbacks from
  replaced clients, claims for superseded configurations, current-claim
  reconciliation, and suspended account startup credential cleanup. The
  fixtures use injected clients and credentials, not live tunnels or Keychain.
- A revoked tunnel lifetime rejects websocket and local-request admission
  before any network task starts; replacement-client tests verify that only
  the current lifetime remains active. Concurrent revokers wait for
  cancellation issuance, retry backoff advances and resets on readiness,
  and background 401 cleanup blocks credential replacement until it ends.
- A live GPT-6.1 Sol metadata/response smoke check passed. Routine model
  tests do not use Astra.

## Review Gate

Substantial changes require a fresh Astra source review, followed by fixes
and focused re-review. Source review is not runtime acceptance. The Studio
and security reviews have already driven fixes to navigation, cancellation,
authenticated media, request framing, and retry
durability. Final focused source gate: PASS, with no actionable P1/P2
findings remaining in the reviewed paths. The CLI startup banner confirmed
`gpt-6-astra`, review session `01a1b977-0526-71c1-8282-b4ef9e0691d0`.
The final native run includes the cleanup spinner/button changes as well
as the cancellation, listener identity, retry, and credential-admission fixes.

## Remaining Boundaries

- Real computer input still requires macOS Screen Recording/Accessibility
  permissions and a human approval for each proposed action. Automation did
  not change those grants or approve real input. The user reported a Screen
  Recording grant, while the older Studio.11 panel still showed Accessibility
  unavailable. No real input was dispatched as part of this verification.
- Computer capability is Codex-only. OpenCode and Grok chat
  support does not imply that their plugins are isolated for computer use.
- Ad-hoc builds may need the user to unlock the saved remote token in
  Settings. Denied Keychain access must not replace the saved token or
  prevent the app window from opening.
- Native 1119/1120px session visibility is unit-tested. Exact native resize
  and VoiceOver acceptance remain manual checks.
- Local and ordinary CI candidates are not Developer ID notarized releases.
  No release tag or live deployment is implied by publishing this branch;
  unrelated pending work in the original checkout has been preserved.
- The session writer provides private atomic publication and an app-process
  retry recovery marker. Full machine-power-loss durability is not claimed.
