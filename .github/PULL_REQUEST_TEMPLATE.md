<!--
Keep this short. The point is what changed and how you know it works — the
conventions themselves live in .github/copilot-instructions.md, and CONTRIBUTING.md
says which commands to run.
-->

## What this changes

<!-- One or two sentences. If it fixes an issue, say "Fixes #123". -->

## Why

<!-- The problem, not the patch. If it comes from an open issue, link it. -->

## How it was verified

<!-- Which commands you ran, and what you saw. Delete the lines that do not apply. -->

- [ ] `Scripts/lint.sh` passes
- [ ] `xcodebuild test -project OpenHikes.xcodeproj -scheme OpenHikes -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` passes
- [ ] `swift test --package-path OpenHikesShared` passes
- [ ] `Scripts/run-ui-tests.sh --all` — needed for a change to recording, the map or the sheet
- [ ] `Scripts/run-performance-tests.sh` — needed for a change on the render path
- [ ] New behaviour has a test that fails without the change

## Anything a reviewer should look at first

<!--
Screenshots for a UI change, before/after numbers for a performance one, or the
one line you are least sure about.
-->
