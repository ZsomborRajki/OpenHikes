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
- [ ] `xcodebuild test -project OpenHikes.xcodeproj -scheme OpenHikes -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:OpenHikesTests -only-testing:OpenWidgetTests` passes
- [ ] `swift test --package-path OpenHikesShared` and `swift test --package-path OpenHikesData` pass
- [ ] `Scripts/run-ui-tests.sh --all` — needed for a change to recording, the map or the sheet
- [ ] New behaviour has a test that fails without the change

## Anything a reviewer should look at first

<!--
Screenshots for a UI change, or the one line you are least sure about.
-->
