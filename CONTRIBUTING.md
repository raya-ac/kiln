# Contributing to Kiln

Thanks for poking around. It's a personal project but genuine PRs are welcome
— especially small, surgical ones.

## Before you open a PR

- **Check the issues.** If someone's already discussed it, join that thread
  rather than opening a parallel one.
- **Open an issue first for anything bigger than a small fix.** Saves both of
  us the case where your PR goes in a direction I wouldn't have taken.
- **One PR per concern.** If you're fixing a bug *and* renaming a thing,
  that's two PRs.

## Building

```bash
git clone https://github.com/raya-ac/kiln
cd kiln
swift build                          # debug
open .build/debug/Kiln               # run it
swift build -c release               # release
./scripts/make-app-bundle.sh 0.0.0 arm64   # or x86_64
```

macOS 14+, Xcode 15+ (Xcode 26 preferred). Apple Silicon or Intel.

## Style

- Swift 6 concurrency is on. `@MainActor` things stay on main; anything
  crossing actors needs to be explicit about it. Don't reach for
  `nonisolated(unsafe)` unless you really mean it.
- SwiftUI views: state lives as close to where it's used as possible. Avoid
  passing `store` three layers down if one child genuinely needs it —
  inject the concrete value instead.
- Comments should say *why*, not *what*. The code says what.
- No trailing-return-type magic or clever one-liners if a boring version
  reads as well.

## Tests

Run `swift test` for the native suite. This checkout also supports
`swift test --build-system native` when SwiftTerm's Metal build fails with
the default engine. Use the remote fixture in `scripts/test-remote-ui.cjs`
for browser acceptance, including compact layouts and recoverable drafts.

After every substantial change, get a fresh code review from Astra before
calling the phase complete. Address actionable findings and re-check the
affected flow. Keep source review, automated tests, and actual client
acceptance separate. Use GPT-6.1 Sol or Grok 4.7 for routine model smoke
tests; Astra is the review gate, not the default test model.

## Commit messages

Conventional-ish. Present tense, imperative, short subject:

```
fix: port field now rebinds listener on commit
feat(tunnels): reconnect with exponential backoff
docs: humanise the readme
```

Don't worry about being too strict — I'll squash on merge if the history is
messy.

## CI

`swift build -c release` and both arch bundles run on every push/PR via
`.github/workflows/ci.yml`. If CI's red, the PR isn't landing until it's
green.

## Security

Don't file vulnerabilities as public issues. See
[SECURITY.md](SECURITY.md).

## Conduct

[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Short version: be decent.

## Licence

By contributing, you agree your changes ship under the project's
[MIT licence](LICENSE).
