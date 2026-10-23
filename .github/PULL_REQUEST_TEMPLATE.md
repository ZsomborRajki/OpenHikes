<!--
Keep this short. The point is what changed and how you know it works — the
conventions and the commands themselves live in AGENTS.md (*Build and
test*).
-->

## What this changes

<!-- One or two sentences. If it fixes an issue, say "Fixes #123". -->

## Why

<!-- The problem, not the patch. If it comes from an open issue, link it. -->

## How it was verified

<!-- Which commands you ran, and what you saw. Delete the lines that do not apply. -->

- [ ] `Scripts/lint.sh` passes
- [ ] The app and widget unit tests pass, run as *Build and test* in AGENTS.md shows (a `Scripts/sim-pool.sh acquire` device, `-derivedDataPath DerivedData`, `-only-testing:OpenHikesTests -only-testing:OpenWidgetTests`)
- [ ] `swift test --package-path OpenHikesShared -Xswiftc -warnings-as-errors` and `swift test --package-path OpenHikesData -Xswiftc -warnings-as-errors` pass
- [ ] `Scripts/run-ui-tests.sh --all --device "$udid" --derived-data DerivedData` — needed for a change to recording, the map or the sheet
- [ ] `Scripts/render-trace.sh` on `main` and on this branch, compared with `--baseline` — for a change on the render path; the counts that moved are in the description
- [ ] New behaviour has a test that fails without the change

## Anything a reviewer should look at first

<!--
Screenshots for a UI change, or the one line you are least sure about.
-->
