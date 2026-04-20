<!--
Thanks for sending a patch! A couple of small things before you hit "Create":
- If this is more than a one-line fix, please link an issue that discusses the
  change. If there isn't one yet, file one first so we can agree on shape.
- Keep the PR focused. One concern per PR.
- CI has to be green before this lands.
-->

## What this does

<!-- One or two sentences. Link the issue with "Fixes #123" if applicable. -->

## Why

<!-- The motivation. What was wrong / missing / annoying before? -->

## How to verify

<!--
Steps a reviewer can follow locally. Screenshots / recordings welcome for
UI changes.
-->

## Checklist

- [ ] Builds cleanly: `swift build -c release`
- [ ] Bundle script still works: `./scripts/make-app-bundle.sh 0.0.0 arm64`
- [ ] Tested on my machine (arch: ____, macOS: ____)
- [ ] Updated docs / README if behaviour changed
- [ ] No new warnings that weren't there before
