# Kiln Workflow

After each substantial code or UI change, get a fresh code review from
`gpt-6-astra` before calling the phase complete. Address actionable findings
and send the fixes back for focused review. Confirm the actual review model;
do not assume a resumed agent retained its original model.

Keep source review, automated tests, and rendered client acceptance separate.
Use GPT-6.1 Sol or Grok 4.7 for routine live-model smoke tests, not Astra.

For the native suite, use `swift test --build-system native` if SwiftTerm's
Metal build fails with the default SwiftPM engine. Stage candidate app bundles
separately from the running app and verify the exact executable and version
when restarting Kiln.
