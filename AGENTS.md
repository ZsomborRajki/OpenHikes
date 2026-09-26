# AGENTS.md

Instructions for coding agents working in this repository.

## The instructions live in one file

Everything an agent needs — architecture, repository conventions, render
isolation rules, energy policies, and the decisions
that have already been settled and must not be re-raised — is in
[`.github/copilot-instructions.md`](.github/copilot-instructions.md)
([view on GitHub](https://github.com/ZsomborRajki/OpenHikes/blob/main/.github/copilot-instructions.md)).

**Read it before changing anything.** It is the single source of truth for how
code is written here, and this file deliberately does not restate it.

Supporting documents, each owning its own facts:

- [`README.md`](README.md) — what the app is, what it needs, how to build it, and how it is laid out.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — the short version for a first change.
- [Issues](https://github.com/ZsomborRajki/OpenHikes/issues) — the open work. Missing features and undecided product questions are tracked there, not in a checked-in list.

## Commands

```sh
# Strict SwiftLint, the pinned version, the same script CI runs
Scripts/lint.sh

# Boot the simulator before any test command below
xcrun simctl boot "iPhone 18 Pro" || true
xcrun simctl bootstatus "iPhone 18 Pro" -b

# App and widget unit tests — the two bundles, and nothing else
xcodebuild test -project OpenHikes.xcodeproj -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:OpenHikesTests -only-testing:OpenWidgetTests

# The standalone shared package
swift test --package-path OpenHikesShared

# The data package — the models, on the macOS host
swift test --package-path OpenHikesData

# The watch app alone — the faster loop while working on it. Building the
# `OpenHikes` scheme above already compiles it, because it is a dependency of
# the app and embedded in it, so there is no way to break the watch that
# leaves the three gates green.
xcodebuild build -project OpenHikes.xcodeproj -scheme OpenHikesWatch \
  -destination 'generic/platform=watchOS Simulator'
```

**The boot is part of the test command, not a refinement of it.** A cold
simulator fails with "Early unexpected exit, operation never finished
bootstrapping" or "The test runner hung before establishing connection" —
nearly six minutes of a red run that says nothing about the code, against
eighteen seconds of a green one. CI boots as its own step for the same reason;
see *Build and test* in the instructions file.

Those four are the gates CI runs, on the same device and the same compiler.
**The `-only-testing:` scoping is part of the command, not a refinement of
it** — `OpenHikes.xctestplan` also carries `OpenHikesUITests`, so dropping it
turns a twenty-second gate into thirteen minutes of simulator automation and
stops the run matching the one CI gates on. CI names `iPhone 18 Pro` on an
`xcode-27` runner image carrying Xcode 27.0, so a green local gate now means
what it says; it did not while CI was on `Xcode_26.6`, and *Build and test* in
the instructions file records what that cost.

`Scripts/run-ui-tests.sh --all` stays out
of CI and is run locally for a change to recording, the map, or anything on
the render path. `--all` spreads its classes across three simulator clones on
its own — 5m49s against thirteen minutes serial — so the line above is already
the fast one; `--serial` goes back to a single device and `--parallel N`
changes the count. Anything narrower than a bare `--all` stays serial, which is
what keeps CI's `--suite` runs on one simulator.

Two things guard that fan-out against itself, because three clones booting,
installing and first-launching at once make the machine slow enough that a test
with a tight wait gives up. A bare `--all` **retries its failures** — failures
and only failures, so a green run pays nothing; `--no-retry` turns it off — and
it runs the tests in the script's `serial_tests` list in a **second, serial
pass** on the one simulator afterwards. Neither is a place to put a test that is
actually broken: anything failing a `--suite X --test Y` run fails for its own
reasons, and pinning it would only make the same failure take longer to find. Rebase before trusting any of these timings —
a branch cut before a fix that made a suite faster still pays the old cost.

Check the exit code rather than the printed summary: `xcodebuild` will relaunch
a crashed test host and still print a green summary. What the script does print
at the end of each pass is the tests that failed, and the ones that only passed
on a retry — read those before suspecting the branch.

**A second session on this machine needs its own of both.** Two runs cannot
share a simulator, and they cannot share a derived-data directory either: the
first collision kills tests mid-gesture with no diagnostic, the second stalls
silently for as long as it is left to. So a run claims the simulator it
resolved and refuses to start on one another run holds; `--device <name|udid>`
gives this one its own device and `--derived-data <path>` its own build.

**Get that device from the pool, never from `simctl create`:**
`udid="$(Scripts/sim-pool.sh acquire)"` before a test command (repeating it is
safe), and `Scripts/sim-pool.sh release` when the work is done. *Build and test*
in the instructions file says how it picks, erases and frees a device.

## House rules an agent trips over first

- **Do not edit `project.pbxproj` to add a file.** The target folders are
  file-system-synchronized groups; a new file in the right folder is compiled.
- **Never commit `OpenHikes/Secrets.plist`,** API keys, or anything else
  personal to the machine.
- **Render isolation is enforced.** High-frequency state lives in stable
  `@Observable` reference types, and parent SwiftUI bodies must not read it —
  including from helper `func`s, computed `var`s and `.toolbar` / `.overlay` /
  `.safeAreaInset` closures, all of which are inlined into the declaring body.
- **One test class or `@Suite` per file,** and tests use Swift Testing except in
  `OpenHikesUITests`. Both halves are enforced: `single_test_class` for
  `XCTestCase`, and the `one_suite_per_file` custom rule for `@Suite`.
- **`OpenHikesWatch` has no test bundle, and a watch simulator is in no gate.**
  Anything on the watch worth asserting belongs in `OpenHikesShared`, where
  `swift test` reaches it on the macOS host; what stays on the watch is Core
  Location, HealthKit and SwiftUI. See *The watch app* in the instructions
  file.
- **No fixed sleeps as barriers.** Wait on the effect, never on a duration.
- **Documentation is owned by exactly one file each.** Before adding a fact to a
  second place, read the *Documentation* section of the instructions file.
