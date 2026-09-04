# Contributing to OpenHikes

Thanks for taking an interest. OpenHikes is a small, opinionated codebase, and
most of what a contribution needs to know is already written down — this file
points at it rather than repeating it.

- [`README.md`](README.md) — what the app is, what it needs, how to build and
  run it, and what lives where.
- [`.github/copilot-instructions.md`](.github/copilot-instructions.md) — the
  architecture rules, the conventions, the energy policies, and the decisions
  that have already been settled and should not be re-opened.
- [`PERFORMANCE.md`](PERFORMANCE.md) — what the app costs and how that was
  measured.
- [GitHub issues](https://github.com/ZsomborRajki/OpenHikes/issues) — the open
  work: bugs, missing features, and product decisions that are still open. A
  good place to find something worth doing.

## Before you start

Open an issue first for anything larger than a fix. The app has a deliberate
scope — local-first, iPhone-only, no backend, no account — and a feature that
does not fit it is better discussed before it is written.

## Setting up

See [Requirements](README.md#requirements) and [Setup](README.md#setup). In
short: Xcode 26.5 or later, iOS 26.0, and an Apple development team that can
sign the WeatherKit entitlement, the App Group, the iCloud container and push.

`OpenHikes/Secrets.plist` holds the optional Stadia and Thunderforest keys. It
is gitignored and **must never be committed** — `cp Secrets.example.plist
OpenHikes/Secrets.plist` and edit the copy. OpenStreetMap is the keyless
default, so a build with no keys works; the paid providers simply stay locked.

## Before you open a pull request

Run these three. They are what CI runs, so a green run here is a green run
there:

```sh
# Strict SwiftLint, the pinned version, the same script the CI `quality` job
# runs. --fix applies what SwiftLint can correct on its own.
Scripts/lint.sh

# The app and widget unit suites. The -only-testing: scoping is what makes
# this the run CI gates on: the scheme's test plan carries OpenHikesUITests
# too, and without it this becomes thirteen extra minutes of UI automation.
xcodebuild test -project OpenHikes.xcodeproj -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:OpenHikesTests -only-testing:OpenWidgetTests

# The standalone shared package
swift test --package-path OpenHikesShared
```

`Scripts/install-git-hooks.sh` installs an opt-in pre-push hook that runs the
linter for you.

Two suites stay out of CI because a shared runner makes real gestures and
timing-sensitive waits slow and unreliable. Run them locally when you touch
recording, the map, or anything on the render path:

```sh
# Spreads its classes across three simulator clones; --serial for one
Scripts/run-ui-tests.sh --all
Scripts/run-performance-tests.sh
```

## Writing code here

The conventions live in
[`.github/copilot-instructions.md`](.github/copilot-instructions.md) and the
linter enforces what it can. The handful that catch people out:

- **Render isolation.** High-frequency state lives in stable `@Observable`
  reference types, and parent SwiftUI bodies must not read it. Adding a read in
  a body — or in a helper `func`, a computed `var`, or a `.toolbar` /
  `.overlay` / `.safeAreaInset` closure, all of which are inlined into the body
  that declares them — is how an idle map starts costing a core.
- **One test class or `@Suite` per file.** SwiftLint's `single_test_class` rule
  is enabled and will reject a second one.
- **Tests use Swift Testing** (`@Suite`, `@Test`, `#expect`). Only
  `OpenHikesUITests` uses XCTest, because Apple's UI automation and launch
  metrics are not available through Swift Testing.
- **No fixed sleeps as barriers.** Wait on the effect you expect —
  `settleDelegateHop(until:)` for a delegate hop, the counter a UI test is
  really waiting on — never on a duration.
- **New Swift files are discovered automatically.** The target folders are
  file-system-synchronized groups, so put a file in the folder belonging to the
  target that should compile it and do not edit the project file.
- **Accessibility is part of the contract.** A composite row is one element
  with one label and one value; identifiers go on the leaf view, never on a
  container. `AccessibilityUITests` and `AccessibilityLabelUITests` enforce it.

## Commits and pull requests

- Keep a pull request to one subject, and say what you did and how you know it
  works. The template asks for exactly that.
- Documentation is owned by exactly one file each — see the *Documentation*
  section of `.github/copilot-instructions.md` before adding a fact to two
  places. `PERFORMANCE.md` is a live list, not a log: a finding that has been
  fixed is deleted, not annotated. Open work belongs in an issue, not in a
  checked-in list.
- Do not commit `OpenHikes/Secrets.plist`, API keys, or anything else that
  belongs to you rather than to the repository.

## Licence

By contributing you agree that your contribution is licensed under the
[MIT License](LICENSE), like the rest of the repository.
