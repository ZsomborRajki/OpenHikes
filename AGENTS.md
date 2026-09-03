# AGENTS.md

Instructions for coding agents working in this repository.

## The instructions live in one file

Everything an agent needs — architecture, repository conventions, render
isolation rules, energy policies, the performance harness, and the decisions
that have already been settled and must not be re-raised — is in
[`.github/copilot-instructions.md`](.github/copilot-instructions.md)
([view on GitHub](https://github.com/ZsomborRajki/OpenHikes/blob/main/.github/copilot-instructions.md)).

**Read it before changing anything.** It is the single source of truth for how
code is written here, and this file deliberately does not restate it.

Supporting documents, each owning its own facts:

- [`README.md`](README.md) — what the app is, what it needs, how to build it, and how it is laid out.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — the short version for a first change.
- [`PERFORMANCE.md`](PERFORMANCE.md) — what the app costs and how that was measured.
- [Issues](https://github.com/ZsomborRajki/OpenHikes/issues) — the open work. Missing features and undecided product questions are tracked there, not in a checked-in list.

## Commands

```sh
# Strict SwiftLint, the pinned version, the same script CI runs
Scripts/lint.sh

# App and widget unit tests — the two bundles, and nothing else
xcodebuild test -project OpenHikes.xcodeproj -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:OpenHikesTests -only-testing:OpenWidgetTests

# The standalone shared package
swift test --package-path OpenHikesShared
```

Those three are what CI gates on. **The `-only-testing:` scoping is part of the
command, not a refinement of it** — `OpenHikes.xctestplan` also carries
`OpenHikesUITests`, so dropping it turns a twenty-second gate into thirteen
minutes of simulator automation and stops the run matching the one CI gates on.

`Scripts/run-ui-tests.sh --all` and `Scripts/run-performance-tests.sh` stay out
of CI and are run locally for a change to recording, the map, or anything on
the render path. `--all` spreads its classes across three simulator clones on
its own — 5m49s against thirteen minutes serial — so the line above is already
the fast one; `--serial` goes back to a single device and `--parallel N`
changes the count. Anything narrower than a bare `--all` stays serial, which is
what keeps CI's `--suite` runs on one simulator. The performance suite has no
such flag and must not get one. Rebase before trusting any of these timings —
a branch cut before a fix that made a suite faster still pays the old cost.

Check the exit code rather than the printed summary: `xcodebuild` will relaunch
a crashed test host and still print a green summary.

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
  `OpenHikesUITests`.
- **No fixed sleeps as barriers.** Wait on the effect, never on a duration.
- **Documentation is owned by exactly one file each.** Before adding a fact to a
  second place, read the *Documentation* section of the instructions file.
