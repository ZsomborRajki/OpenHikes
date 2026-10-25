# AGENTS.md

How code is written in this repository: the commands, the architecture, the
conventions, and the decisions that are already settled. Read it before
changing anything. [`README.md`](README.md) says what the app is,
[`CONTRIBUTING.md`](CONTRIBUTING.md) is the short path to a first change, and
open work lives in [issues](https://github.com/ZsomborRajki/OpenHikes/issues).

Most source files open with a header that argues for their design. When a rule
below names a type, a file or a test, that is where the longer reasoning lives.

## House rules

- **Take a simulator from the pool, and give each checkout its own derived
  data.** Two runs cannot share either. See *A second session on this machine*.
- **Scope the unit tests with `-only-testing:`.** The test plan also carries
  `OpenHikesUITests`, so leaving it out turns a twenty-second gate into most of
  an hour of simulator automation.
- **Do not edit `project.pbxproj` to add a file.** Target folders are
  file-system-synchronized groups, so a new file in the right folder is compiled.
- **Never commit `OpenHikes/Secrets.plist`**, API keys or anything else personal
  to the machine.
- **Render isolation is enforced.** High-frequency state lives in stable
  `@Observable` reference types, and parent SwiftUI bodies must not read it.
  That includes reads from helper `func`s, computed `var`s and `.toolbar` /
  `.overlay` / `.safeAreaInset` closures, all of which are inlined into the
  declaring body. A screen that is always on screen reads settings from
  `StoredSettings`, never `@AppStorage`.
- **One test class or `@Suite` per file.** Tests use Swift Testing everywhere
  except `OpenHikesUITests`. SwiftLint enforces the one-per-file half
  (`single_test_class` and `one_suite_per_file`); nothing enforces the other.
- **No fixed sleeps as barriers.** Wait on the effect, never on a duration.
- **A suite never reaches the network, CloudKit or the app's singletons.** See
  *Deliberate test seams* and *A suite must never reach the real transport*.
- **`OpenHikesWatch` has no test bundle, and no gate boots a watch simulator.**
  Logic worth asserting goes in `OpenHikesShared` (see *The watch app*).
- **Check the exit code, not the printed summary.** `xcodebuild` relaunches a
  crashed test host and can still print a green summary.
- **Each fact is written in exactly one place.** See *Documentation*.

## Build and test

```sh
# Strict SwiftLint at the pinned version: the script CI runs (--fix corrects what it can)
Scripts/lint.sh

# Take a simulator in the same shell command as the test that uses it. This
# prints the UDID of a booted `OpenHikes Pool <n>`, an iPhone 18 Pro (the device
# CI names). The same session always gets the same device back, so call it
# again in every new shell.
udid="$(Scripts/sim-pool.sh acquire)"

# App and widget unit tests: the two app-hosted bundles and nothing else. A
# relative DerivedData gives each worktree its own build, and git and SwiftLint
# both ignore it.
xcodebuild test -project OpenHikes.xcodeproj -scheme OpenHikes \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath DerivedData \
  -only-testing:OpenHikesTests -only-testing:OpenWidgetTests
# Narrow it to one suite, or to one method (a Swift Testing method needs its trailing ()):
#   -only-testing:OpenHikesTests/HikeStatisticsTests
#   -only-testing:'OpenHikesTests/HikeStatisticsTests/elevationGainAndLoss()'

# The same two bundles on the deployment floor, from a pool of its own: an
# iPhone 16 Pro on iOS 18.6 (see *Deployment floor*). Then the same test
# command with -destination "platform=iOS Simulator,id=$floor".
floor="$(OPENHIKES_SIM_POOL_PREFIX='OpenHikes Floor' \
  OPENHIKES_SIM_POOL_DEVICE_TYPE='iPhone 16 Pro' \
  OPENHIKES_SIM_POOL_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-18-6 \
  Scripts/sim-pool.sh acquire)"

# The two local packages, on the macOS host, with warnings as errors as CI runs
# them (CI repeats both with --configuration release). Add --filter <Suite> for
# one suite, such as MercatorTests in OpenHikesShared.
swift test --package-path OpenHikesShared -Xswiftc -warnings-as-errors
swift test --package-path OpenHikesData -Xswiftc -warnings-as-errors

# The shell scripts, against stubbed xcrun, xcodebuild, swiftlint and periphery
Scripts/run-script-tests.sh

# The watch app alone: the fast loop. The OpenHikes scheme already builds it,
# because the app embeds it.
xcodebuild build -project OpenHikes.xcodeproj -scheme OpenHikesWatch \
  -destination 'generic/platform=watchOS Simulator'

# UI automation (CI runs only the two accessibility classes): four simulator
# clones, then a serial pass
Scripts/run-ui-tests.sh --all --device "$udid" --derived-data DerivedData

# Give the simulator back once this session's testing is done (the floor's
# with the same OPENHIKES_SIM_POOL_PREFIX)
Scripts/sim-pool.sh release
```

CI runs the lint, the unit tests, both packages and the script tests, on the
same device.

### Before trusting a run

- **Boot before you test.** `acquire` waits on `simctl bootstatus -b`. A cold
  simulator fails with "Early unexpected exit, operation never finished
  bootstrapping", or after nearly six minutes with "The test runner hung before
  establishing connection". Booted first, the same run passes in eighteen
  seconds.
- **`-only-testing:` can select nothing and still pass.** An identifier it
  cannot resolve is ignored. A suite declared inside an `extension` looks like
  that (`BackgroundDeliveryTests` lives in `extension WidgetFeedSuites`), and so
  does a method missing its `()`. A job that pins identifiers has to count what
  ran, as `Scripts/check-sanitized-selection.sh` does for TSan.
- **Suspect the device before the code.** Failures that differ on every run
  (`Test crashed with signal kill`, `kAXErrorServerNotFound`,
  `Application … is not running`) mean two runs shared a simulator. That has
  been mistaken for a product bug four times.
- **Rebase before trusting a timing.** A stale branch still pays for slowness
  that `main` has since fixed. Compare against `main` at the same commit.

### CI

`.github/workflows/ci.yml` has seven jobs that can fail a run:

| Job | What it covers |
|---|---|
| `Lint and shared package` | Lint, script tests, both packages in Debug and Release |
| `App and widget tests` | Strict suite preconditions, the string-catalog check, the coverage floor |
| `iOS Debug build`, `iOS Release build` | Simulator builds |
| `Unsigned iOS archive` | A device archive |
| `Thread sanitizer` | Concurrency suites under TSan |
| `Accessibility UI tests` | The two accessibility UI classes |

- **None of them is a required check.** `main`'s branch protection has no
  `required_status_checks`, so a red run reports a problem but blocks nothing.
- **Documentation-only pull requests skip the jobs.** The `changes` job runs
  everything unless every changed path is `*.md`, `LICENSE` or under `docs/`. It
  is a job-level `if:` rather than `paths-ignore:`, because a skipped job
  reports success and so would not block a check made required later. A push
  to `main` builds everything.
- **The toolchain is pinned.** CI uses the `xcode-27` image with Xcode 27.0
  pinned by `DEVELOPER_DIR` at the top of `ci.yml`, and its Swift is 6.4. A
  local Xcode 27.x matches only while `xcrun swift --version` says 6.4 too; a
  point release that moves the Swift minor reopens the gap. While CI ran Xcode
  26.6, that version difference broke `main` three times with errors no local
  build could show.
- **CodeQL is the exception.** `codeql.yml` stays on `macos-26` with Xcode 26.6
  until a CodeQL bundle supports Swift 6.4 (watch `swift/ql/lib/CHANGELOG.md`).
  That makes it the one job compiling with the older Swift, so it catches code
  Xcode 27 accepts but 26.6 rejects:
  - a nested type in an unannotated extension (see *Concurrency*)
  - a member of a type reached only through a transitive import (import its
    module)
  - a memberwise init hidden by a `private` stored property (write the init out)

  `reorderable()` and `reorderContainer(for:)`, the app's only iOS 27.0 APIs,
  sit behind `#if compiler(>=6.4)` as well as `#available`, so that this job
  still builds — at the deployment floor, like every other job. The one iOS
  27.1 API, `toolbarVerticalBehavior(_:)`, sits behind
  `#if canImport(SwiftUI, _version: 8.0.85)`: CI's Xcode 27.0 is Swift 6.4 too,
  and only the SDK's SwiftUI version (8.0.84 there) tells it apart.
- **The coverage floor.** `OpenHikes.app` line coverage must stay at or above
  76% (`COVERAGE_FLOOR`). The measurement leaves out the files in
  `Scripts/coverage-exclusions.txt`, which are entirely SwiftUI body code that
  only UI suites evaluate. Put a new screen, or a section folded out of two
  screens, on that list in the same change. Anything containing logic stays off
  it, and the floor is never lowered. A stale path in the list fails the gate.
- **Every `xcodebuild` in `ci.yml` passes `-skipPackagePluginValidation`.** Add
  it to any new call too: SwiftLint plugin trust is stored per user, and a
  fresh runner has none. Xcode Cloud cannot take the flag, so
  `ci_scripts/ci_post_clone.sh` sets the equivalent defaults.
- **A program inside YAML is a program nothing checks.** Logic beyond a shell
  conditional goes in a script under `Scripts/`. The thresholds it enforces stay
  in the workflow as environment variables, beside the comments that argue for
  them. Every `*.sh` file is parse-checked, and `Scripts/run-script-tests.sh`
  exercises each gate.

### A second session on this machine

Two runs cannot share a simulator: the second install tears the first run's app
out mid-gesture, with no diagnostic. They cannot share a derived-data folder
either: the second run waits silently on the first run's build lock.

- **Get the device from the pool, never from `simctl create`.**
  `Scripts/sim-pool.sh acquire` hands out the lowest-numbered free
  `OpenHikes Pool <n>`, booted and with the photo library granted. It creates a
  new device only when every existing one is held, up to
  `OPENHIKES_SIM_POOL_MAX` (5).
  - A device that changes hands is replaced with a fresh clone of a settled
    `OpenHikes Template (<device type>, <runtime>)`. An erased iOS 27 simulator
    downloads about 1.4 GB of Siri and speech models on its next boot; a clone
    boots in seconds.
  - The same owner always gets its own device back, data intact, even after
    `release` if nobody else has taken it since. So it is safe to call before
    every test command.
  - Inside Claude Code the owner is the session, and the claim ends with the
    session's process.
  - Any claim also lapses after `OPENHIKES_SIM_POOL_TTL_MINUTES` (180) without
    a renewal, unless a running process still names the device. A device that a
    running process names is never handed out.
- **Never boot, erase or delete an `OpenHikes Template (…)`.** Losing one means
  downloading those 1.4 GB again, and `adopt` refuses templates.
  `Scripts/sim-pool.sh template` settles a template, or refreshes one older than
  `OPENHIKES_SIM_TEMPLATE_REFRESH_DAYS` (7). Settling or refreshing downloads
  about 1.4 GB, and `acquire` does either on its own when it needs a clean
  device and the template is missing or stale (or erases instead, which also
  downloads), so run `template` first on an unmetered connection.
- **When the pool is full, do not make a device of your own**, and never delete
  a pool device or boot one by name. Instead:
  - `status` shows who holds each device and how old each template is.
  - `adopt <name|udid>` brings an idle leftover simulator into the pool.
  - `prune --keep <n>` deletes free devices beyond the lowest `n`.
  - `release` gives your device back. A session that ends frees its device
    anyway.

  To try out a change to the pool script itself, set
  `OPENHIKES_SIM_POOL_PREFIX` to get a separate pool.
- **`Scripts/run-ui-tests.sh` holds its device for the whole run.** It writes a
  PID lock under `~/Library/Caches/OpenHikes/ui-test-locks` and refuses a second
  run on that device. A lock left by a killed run is taken over, and
  `--no-device-lock` forces past one. Pass each session its own `--device`
  (name or UDID) and `--derived-data <path>`, or set
  `OPENHIKES_SIMULATOR_NAME` and `OPENHIKES_DERIVED_DATA` once per session.
- **Pass `Scripts/simulate-hike.sh` a UDID.** It reads `OPENHIKES_SIMULATOR`
  and hands it to `simctl location`, which accepts a UDID or `booted` but not a
  name.

### The iPhone Duo

- **It needs the iOS 27.1 runtime, which as Xcode 27.1 installs it runs no
  other device.** CI's Xcode 27.0 has neither, so no gate runs on a Duo, and
  the 27.1 SDK's Duo APIs (`toolbarVerticalBehavior`, the one the app uses,
  and `ArrangementView`, `reservedRegions`, `toolbarVerticalEdge`) do not
  exist where CI compiles; *CI* above has the gate they need. Templates and
  the pool pick the newest runtime that runs their device type, never just
  the newest.
- **It boots closed**, on the cover display (466 × 678 points), and only
  Device Hub opens it by hand. `Scripts/duo-pose.sh open --device <udid>`
  unfolds it to the inner display (669 × 951, upright) and reads the display
  state back; one unfold from cold is the move to rely on.
  `--orientation landscape` leaves it the way it unfolds, 951 × 669: a window
  wider than tall, so the map screen draws its side panel.
- **XCTest sees it through the cover.** `XCUIScreen.main` is the cover display
  open or closed (the inner one is the other `XCUIScreen.screens` entry), and
  on the inner display turned sideways `app.frame` stays portrait while
  `app.windows.firstMatch.frame` turns. There `isHittable` also answers no for
  everything in the side panel, so the shared helpers measure the window and
  skip it (`OpenHikesUITests/WindowSupport.swift`).
- The screenshot set shoots on it with `--device-type "iPhone Duo"` and
  `--pose`; see `Screenshots/README.md`.

### UI automation

`Scripts/run-ui-tests.sh` runs one test (`--test`), one class
(`--suite <class> --all`) or every functional class (`--all`). `--list` and
`--help` print what is available. **A bare `--all` is the line to run** before
a change to recording, the map, the sheet or the render path; the PR template,
`CONTRIBUTING.md` and this file all ask for it.

- **A bare `--all`:**
  - spreads classes across four clones (under twenty minutes, against about
    fifty serially)
  - then runs the `serial_tests` list on one simulator
  - retries failures only, so a green run pays nothing extra

  `--serial`, `--parallel N` and `--no-retry` change that. Anything narrower
  stays serial, which keeps CI's `--suite` runs on one device. Neither
  `serial_tests` nor retries is a place for a broken test: anything that fails a
  `--suite X --test Y` run fails for its own reasons. Each pass ends by listing
  what failed and what only passed on retry.
- **A new `XCTestCase` must join the script's class list**, or `--all` never
  runs it; `run-script-tests.sh` fails when a class is missing. There are two
  exceptions:
  - `ScreenshotUITests` belongs to the screenshot scripts (see
    `Screenshots/README.md`).
  - `testLaunchPerformance` is kept out by `measurement_tests`, because a
    contended machine measures itself. Let its measure block end on its own:
    `stopMeasuring()` makes the launch metric raise.
- **There is no sysdiagnose.** Runs pass `-collect-test-diagnostics never`,
  because Xcode 27's end-of-session `simctl diagnose` hangs for 600 seconds.
  The evidence is in the result bundle (`--result-bundle <path>`).
- **UI launches pass `--ui-testing`**, which selects an in-memory store and
  isolated `UserDefaults`. Further `DEBUG`-only `--ui-test-…` arguments seed
  data, force failures or replace a network source; each takes effect only
  alongside `--ui-testing`. `AppLaunchEnvironment` is the list, and a new
  argument goes there. One does the reverse: `--ui-test-live-maker` lets the
  trail maker ask Apple Maps and the billed Stadia elevation for real, and
  belongs to the App Store frame of a drawn trail alone.
- **No UI launch shows a first-run tip unless it passes `--ui-test-tips`**,
  which starts them from an empty store of their own (`TipLaunch`). Only
  `FirstRunTipsUITests` does, so no other suite and no screenshot meets one.
- **Reuse the shared helpers.** `OpenHikesUITests/UITestSupport.swift` has the
  fixtures, launch helpers and gestures, and `AccessibilityAuditSupport.swift`
  has the audit support. A file named `Suite+Something.swift` extends `Suite`;
  it is never a second class.
- **A spoofed route must respect `RecordingFixPolicy`.** A static simulated
  location is delivered once, so a fix that gets rejected has to be set again.
  Wait on the `recording-point-count` element. For longer playback, use
  `Scripts/simulate-hike.sh`.
- **The accessibility suites.** `AccessibilityUITests` audits each screen
  without `.contrast`, `.textClipped` and `.dynamicType` (each exclusion is
  argued beside it) and filters out MapKit's own `MK` issues.
  `AccessibilityLabelUITests` asserts the labels, values and traits that an
  audit cannot judge. Widening an exclusion needs the same kind of argument.

### Writing tests

- **App tests use in-memory SwiftData fixtures** from
  `OpenHikesTests/General/TestSupport.swift`. `Fixture.hike(in:configure:)`
  inserts before it configures, because `Hike`'s device-local passthroughs do
  nothing on a row with no context.
  - Give anything that has a clock, a transport, defaults or a location an
    injected one.
  - A suite that touches tiles builds a `TileSandbox`, never
    `TileCache.shared`.
- **Both unit bundles are hosted by the app and serialized**
  (`parallelizable: false` in `OpenHikes.xctestplan`). `OpenWidgetTests`
  compiles the `OpenWidget/` sources into itself.
  - The app's `.task`s run before any test, so startup work that writes shared
    state, or would mirror to iCloud, stays behind
    `AppLaunchEnvironment.isRunningTests`.
  - Serialization is what makes a test's time limit mean anything. The bundle
    is main-actor isolated, so running tests in parallel only interleaves them
    and starves them. A bigger time budget is never the fix.
- **Wait on effects with `settleDelegateHop(until:)`**
  (`OpenHikesTests/General/SettleSupport.swift`), naming the effect you expect.
  Never count `Task.yield()`s or sleep.
  - Delegates deliver through `onMainActor`, so a stub's `deliver(...)` usually
    runs the callback synchronously and needs no settle at all.
  - Keep a conditioned settle where the effect really is deferred: a journal
    flush, live matching, a widget snapshot, trail-graph prefetch, or an
    authorization change.
  - To prove something did not happen, wait for the effect that must follow
    it, then assert.
- **Compare floating-point values with `isApproximatelyEqual`.** Write
  `a.isApproximatelyEqual(to: b, absoluteTolerance: t)`, from swift-numerics'
  `RealModule`, rather than `abs(a - b) < t`. If the test target does not link
  the module yet, add it as a dependency rather than writing a helper. Put any
  optional chain on the `to:` side. Bounds and inequality stay written out,
  because `!isApproximatelyEqual` passes a NaN.
- **Report a missing environment capability through `SuitePrecondition`.**
  Today that means the App Group container. Strict mode turns a skip into a
  failure, and CI runs strict. Turn it on with
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS="\$(inherited) REQUIRE_ALL_SUITES"`, or
  with `OPENHIKES_REQUIRE_ALL_SUITES=1` in the scheme.

### Lint and tools

- **`Scripts/lint.sh`** runs strict SwiftLint at the version in
  `.swiftlint-version`. It exits 0 when clean, 2 on violations, and 1 when it
  could not lint at all (SwiftLint reads an unparseable `.swiftlint.yml` as a
  warning and lints against its defaults).
  - Strict mode makes the *warning* thresholds fail. The ones a large change
    hits are `line_length` 120 (comments exempt), `file_length` 500,
    `type_body_length` 300, `function_body_length` 60, `closure_body_length` 40
    and `cyclomatic_complexity` 12.
  - The project's own `custom_rules`:
    - one `@Suite` per file
    - American spelling in names and in literals outside the test bundles
      (color, center, license, meter, gray)
    - the typographic ’ in user-visible copy
    - `ForEach` over `x.indexed()`, never over `Array(x.enumerated())`
      (`x.enumerated()` alone is random access only from iOS 26)

    Somebody else's vocabulary, such as an OSM tag or a wire key, carries
    `swiftlint:disable:this`.
- **The Xcode build lints too**, through the SwiftLint build-tool plugin, but
  without `--strict`. Warnings never show there, but an *error* fails the
  prebuild step and with it every target. The error thresholds sit next to the
  warning thresholds in `.swiftlint.yml`, and some rules (`force_cast`,
  `force_try`, `unhandled_throwing_task`, the custom rules) error on a single
  occurrence.
- **SwiftLint walks dot-directories.** `excluded: "**/.*"` keeps a worktree or
  a scratch copy inside the checkout out of the lint.
- **Optional tools** run if installed
  (`brew install xcbeautify periphery xcode-build-server`):
  - `xcbeautify` formats `xcodebuild` output through
    `Scripts/lib/xcodebuild-output.sh`. It prints nothing for output it cannot
    parse (crashes, hangs, TSan reports), so the UI scripts keep a raw log. In
    CI, every piped `run:` needs `set -o pipefail`.
  - `Scripts/periphery.sh` requires the version in `.periphery-version`,
    because an older Periphery ignores `.periphery.yml` and reports a clean
    scan. It indexes into `.build/periphery`, and what it lists are candidates,
    not verdicts.
  - `xcode-build-server config -project OpenHikes.xcodeproj -scheme OpenHikes`
    writes the gitignored `buildServer.json` that `sourcekit-lsp` uses.
- **Hooks and formatting.** `Scripts/install-git-hooks.sh` installs an opt-in
  pre-push lint hook. There is no formatter.

### Releasing

- **Bump all four shipping targets together.** The app, the widget, the watch
  app and the watch widgets each carry `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` in `project.pbxproj`.
- **Run `Scripts/check-release-secrets.sh` before pressing Archive.** The
  gitignored `OpenHikes/Secrets.plist` holds the Stadia and Thunderforest keys,
  and an archive succeeds without it, shipping paid map styles that draw
  nothing. CI archives without keys on purpose, so this check cannot be a CI
  step.
- **Promote the CloudKit schema before uploading.** An App Store Connect
  upload, TestFlight included, is signed for the production container, and a
  save there cannot add a field. Check production against the model first (see
  *CloudKit*).
- **Tag each archived commit.** Use an annotated tag,
  `git tag -a v<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>`, and add a GitHub
  Release for App Store builds. There are no release branches, so a tag is the
  only way to map an Organizer crash report to a revision. The bump commit is
  not the answer: the archive can be any commit at or after it.
- **Run `Scripts/periphery.sh` after a feature lands.** No CI job runs it. With
  `MemberImportVisibility` on, deleting an unused import is safe, because the
  build fails at once if the import was load-bearing.

## Architecture

### Layout and targets

- **`OpenHikes/` is organized by product domain**, after Apple's Food Truck and
  Backyard Birds samples. `App/` is the composition root. `Hikes/`,
  `Recording/`, `Map/`, `Tiles/`, `Photos/`, `Weather/`, `Purchases/`, `Sync/`,
  `Settings/`, `Health/`, `Reminders/`, `LiveActivity/`, `Intents/`, `Watch/`,
  `Community/`, `Tips/` and `General/` each own their models, services and
  views.
  - A folder that outgrows one level nests by job (for example
    `Hikes/Maker/`), never into `Models/`, `Views/` or `Services/`.
  - A folder's root holds what all of its subfolders use.
  - Tests mirror the same folders.
- **`OpenHikesData` is what a hike *is*.** This package holds the five
  `@Model` types (`Hike`, `HikeWalk`, `TrailPoint`, `HikeLocalState`,
  `TrailDraftRecord`), `OpenHikesSchema`, `RouteProfile`, their stored value
  types and the framework-free logic over them.
  - It defaults to `MainActor`, like the app.
  - An app extension on one of its types takes the app's isolation, so a pure
    static there needs `nonisolated`.
  - The container, the trail graph, recording, GPX, Community and every view
    stay in the app.
  - So do the words: only an app target extracts `String(localized:)`, so a
    label on a package type is an app extension (`…+Label.swift`).
- **`OpenHikesShared` is compiled by the app, the widget, the watch app and its
  complications.** It holds cross-target payloads, projections, deep links, the
  watch link and shared presentation logic.
  - It is **not** main-actor by default, because the widget reads it off the
    main actor.
  - **Its library has no package dependencies, on purpose.** A product that
    links only this package pays for a dependency in full: five one-line
    swift-algorithms rewrites measured +610 KB on the widget and +1.2 MB on
    each watch product. Write the few lines by hand.
- **Targets: iPhone, plus a watch companion, and nothing else.** The shipping
  targets are `OpenHikes`, `OpenWidgetExtension` (the widget, the Live Activity
  views and the Control Center toggle), `OpenHikesWatch` (watchOS 11) and
  `OpenHikesWatchWidgets`.
  - The app embeds the watch app, so building `OpenHikes` builds the watch
    too. Breaking the watch cannot leave CI green.
  - An embedded extension's device family stays a subset of its host's, so
    `OpenWidgetExtension` moves with the app; the archive job's
    `ValidateEmbeddedBinary` enforces it.
  - In the app targets, the `canImport(UIKit)` and `#if os(iOS)` guards are kept
    for possible later platforms, and nothing builds their other branch. In
    `OpenHikesShared` they are load-bearing: the watch build compiles it, where
    `canImport(UIKit)` is true, and `swift test` compiles its macOS side. Guard
    iOS-only API there with `os(iOS)` (or `canImport(UIKit) && !os(watchOS)`).
- **Synchronized folders compile everything in them**, and bundle their
  resources flat.
  - `OpenWidget/` feeds both the extension and `OpenWidgetTests`, minus
    `OpenWidgetBundle.swift`, because a test bundle cannot have a second
    `@main`.
  - `OpenHikes/SimulatedLocations/` is excluded from Release builds by
    `EXCLUDED_SOURCE_FILE_NAMES`.
  - `OpenHikes.storekit` is in no Resources phase.
  - CI's archive job asserts that neither of the last two ships.

### The app

- **Composition.** `OpenHikesApp` creates one `OpenHikesModel` and injects it
  through the environment.
  - The model owns the `ModelContainer` and the long-lived services: location,
    weather, background tracking, auto-save, sync and recording.
  - `OpenHikesView` owns selection, map presentation and navigation.
  - `Hike` is the persisted truth. `RouteProfile` is the distance and elevation
    index that scrubbing and GPS matching share.
  - A pause, or a GPX `<trkseg>` break, is not distance and not trail
    (`RouteBoundary`). A route's length and every distance along it give the
    paused leg none (`RouteCoordinate.legMeters(from:)`), nothing projects a
    fix or a place onto it, the watch's tracker included, and no surface,
    difficulty or steepness stretch is measured across it.
  - A recording that the matcher moved or found ambiguous stops in
    `.reviewing`, and only `saveReviewedRecording()` writes it.
- **The map is imperative MapKit behind `MapView`.** `MapView.Coordinator`
  observes stable controllers and updates `MKMapView` directly. Tiles flow
  through `CachingTileOverlayRenderer` into `TileCache`, auto-saves through
  `AutoSaveTileStore`, and bulk downloads through `OfflineTileDownloader`.
- **A drawn trail is an ordinary `Hike`.** `TrailDraftSave` writes the same row
  a GPX import does, plus `Hike.drawnRouteData` (a `DrawnRoute`), which is what
  *Edit Route* reads. That column is `nil` on recordings and imports.
  - The draft, `TrailDraft`, is a stable `@Observable`. It persists as a
    `TrailDraftRecord` in the **unmirrored** store, because a half-drawn line is
    one device's work.
  - The maker routes legs one at a time through one worker, since nineteen
    parallel Overpass requests earn a `429`. Nothing on that path may block
    drawing.
- **Places** (`Hikes/Places/`): `TrailPlace` is the value and `TrailPoint` the
  mirrored row. The owner's rule:
  - A place from OpenStreetMap takes photographs and nothing else.
  - A place the hiker made can also be renamed, re-kinded and annotated.
  - A place's photographs belong to the hike (`HikePhoto.placeID`), and go back
    to the gallery when the place is removed.
- **A map claim goes to the deepest screen, not to the newest**
  (`ScreenClaims`). Pushing a third screen makes the screen two levels down
  appear again *after* the new one has claimed, so "last to appear" would hand
  the map to the wrong screen.
- **Following a trail is a walk, and the walk outlives the screen.**
  - **One owner.** `TrailWalkSession` is the only place a walk starts: by hand,
    or once matches show real movement along the route. One walk runs at a
    time, and it pins `BackgroundTrailTracker`.
  - **Device-local while it runs.** The walk in progress lives on
    `HikeLocalState`, written at milestones and never per fix.
  - **Bound to its line.** A walk ends when its route is edited
    (`routeRevision`). Its stretches, climb and photo matches are read only
    along the same revision. In `LibraryTotals`, a walk on an older revision
    keeps its distance and time and can still be the longest, but adds no climb
    and is never the highest or the steepest.
  - **A saved recording writes its own walk.** Its active time is
    `PreparedRecording.recordedSeconds`, the gaps between saved points, and
    never wall clock minus the pause list. The pause list is incomplete: a
    recovered session is parked without a pause, and nothing records the time
    before a relaunch. The watch measures the same way
    (`WatchWalkAccumulator`).
- **A recording always outranks a followed trail**, on every surface, because
  it is the one that would be *lost*: a follow is re-derived from the trail and
  the next fix, and a recording is not. Three places hold the rule and must
  agree: `TrailWidgetEntry.init`, `HikeLiveActivityController.accepts(_:)` and
  `HikeRecordingControlState.init(snapshot:)`.
- **App Intents perform through `HikeIntentCoordinator`.** The system can launch
  the process just to run an intent, so no view state is reachable.
  `OpenHikesApp.init()` registers the coordinator, and each intent makes one
  call into it.
  - The recorder stays the single authority. The coordinator holds no state,
    settles recovery before it reads the phase, and reads the phase back
    afterwards, because refusals arrive as `.failed`, not as a throw.
  - Start and resume hand off with `askToContinueInForeground(_:)` for the
    two foreground-only location prompts: `continueInForeground(_:)` on iOS
    26, `requestToContinueInForeground` below it. A
    `needsToContinueInForegroundError` re-run would find the same undecided
    authorization.
  - Suites reach the intents through `HikeIntentContext.$override`.
  - `AppShortcutsProvider` silently drops shortcuts past ten.
- **The Control Center toggle and the Live Activity buttons live in
  `OpenHikesShared`.** Each extension that draws one must compile its action,
  while the app performs it through the same coordinator. The Live Activity
  offers Pause or Resume and never Stop (`HikeActivityControlIntents.swift`).
- **One controller makes the reminder decisions.**
  `MovementReminderController` is handed to both the recorder and the walk
  session, so it can see both. The thresholds live only in
  `MovementReminderPolicy`.

### First-run tips

- **TipKit, in two ordered queues** (`AppTips`). The main screen's are
  *Record a Hike*, *Make a Trail*, the *Community* tab and *Search this
  area*; the recording screen's are *Add Place* and *Places Nearby*. A screen
  never shows two at once, and a tip goes for good once it is closed or its
  control is used.
- **The two about making a hike are for a new hiker** (`CreationTipsAudience`).
  They are retired the first time the list holds a hike, so an existing hiker
  never sees them and the queue moves on to the *Community* tab's. A
  recording in progress is not a hike yet. A hiker who taps the pill on an
  empty list is new, which is kept in TipKit's store, and from then on each
  of the two goes only when it is closed or used. The list is the only
  witness: on a new phone it is empty until iCloud's first import, so an
  existing hiker sees *Record a Hike* until then.
- **Every tip is inline, never a popover.** A popover over the map would be
  presented by the permanent sheet, and while it was up the sheet could
  present nothing else (see *Present modals from inside the sheet's
  contents*). And a `.popoverTip` on a toolbar button never presented at all,
  measured on iOS 27. The map's tips are cards beside their controls
  (`MapTipCards.swift`), the *Community* tab's sits under the picker, and the
  recording screen's sit under its bar.
- **A card on the map speaks for itself.** MapKit builds the map's
  accessibility from its UIKit elements and walks straight past TipKit's
  SwiftUI, so `MapTipCardView` is one element carrying the title, the message
  and *Close* as an action.
- **Configured once, in `OpenHikesApp.init()`, and never for a hosted
  suite** (`TipLaunch`). The store is TipKit's default, in the app's own
  container rather than the App Group.

### The widget and the Live Activity

- **The app computes and the widget draws.** The app writes a compact
  `SharedTrailSnapshot` atomically through `SharedStore` into the App Group,
  then reloads timelines. The widget never recomputes route matching.
- **The widget reads location, deliberately.**
  - While a recording `isCapturingFixes`, `WidgetRecordingLocationSampler`
    appends sparse anchors to `pending-fixes.json`: at most one per 15 minutes,
    claimed with an App Group lock file.
  - The recorder merges and deduplicates them on its next drain.
  - The widget's half is append-only. It never reads the queue back, matches a
    route or computes a statistic.
- **Basemaps are kept per trail**, so a pinned widget keeps its map whatever is
  selected. When WidgetKit cannot say what is pinned, nothing is pruned.
- **The Live Activity is split along the same seam.**
  - `OpenHikesShared/LiveActivity/` owns the payload (`HikeActivityAttributes`)
    and numeric projections and rounding. `OpenWidget/`
    owns the wording (`HikeActivityPresentation`) and draws it, so its build
    extracts the words into the widget’s String Catalog. `OpenHikes/LiveActivity/` decides when one exists.
  - It renders `context.state` only, fed by the widget's two funnels.
  - Its clock ticks by itself through `Text(timerInterval:)`.
  - The payload must fit 4 KB (`payloadFitsTheActivityBudget`), so it carries no
    polyline.
  - The attributes **type name** is a storage contract.
- **`HikeLiveActivityController` owns every rate.** Updates come at most every
  20 seconds, and status flips at most every 10. A recording goes stale after 10
  minutes, a follow after 30. A finished recording lingers for 5 minutes. A
  `nil` final state means "remove now", which is what makes a discard leave
  nothing.
- **A hike's name is bounded where it is entered.** `HikeTitle.bounded(_:)`
  caps it at 128 characters *and* 512 UTF-8 bytes. Every new way to name a hike
  goes through it.
- **Some `Info.plist` keys fail silently when they are missing.** The app
  declares `NSSupportsLiveActivities` and deliberately leaves out
  `NSSupportsLiveActivitiesFrequentUpdates`. `InfoPlistContractTests` pins the
  keys whose absence nobody would notice.

### Persistence and sync

- **Two stores, one container.**
  - `Hike`, `HikeWalk` and `TrailPoint` mirror to the hiker's private CloudKit
    database.
  - `HikeLocalState` and `TrailDraftRecord` live in an unmirrored configuration.
    They hold everything about *this* device: tile claims, offline downloads,
    the walk in progress, recording ownership, a drawing in progress and an
    unfinished community upload.
  - The split matters. The tile sweep deletes what no hike claims, so mirrored
    claims would strip another device of its tiles.
- **Build containers only through `ModelContainer.openHikes(…)`.**
  `ModelConfiguration+OpenHikes.swift` is the only place that names
  `cloudKitDatabase`.
  - A device-local column goes on `HikeLocalState`, with a passthrough on
    `Hike`.
  - A synced column goes on `Hike` with an inline default, and needs a CloudKit
    deployment (*Schema and migration policy*).
  - The rows join on `hikeID`, so deleting a hike calls
    `hike.deleteLocalState()`, after the tile-deletion plan is built.
- **A route is written only through `Hike.replaceRoute(with:)`**, which keeps
  `Hike.durationSeconds` describing it. That column is the synced clock Siri,
  Spotlight and the widget's catalogue read instead of decoding every route at
  launch. `route`'s setter is private, so the compiler holds every writer to
  it.
- **`CloudSyncCoordinator` only reports and toggles; SwiftData owns sync.** That
  gives up four things, deliberately:
  - photo pixels on other devices (see *Settled decisions*)
  - small updates (a rename re-uploads the whole row)
  - hiding unfinished work (a recording in progress is an ordinary row, so
    another device can show a line still being drawn)
  - any preference for unsent local edits

  The Simulator gets no CloudKit pushes, so two simulators cannot test sync.
- **Draft cleanup requires positive ownership.** `Hike.isRecording` is
  mirrored; `TrackJournal` is not. Only `HikeLocalState.ownsRecordingDraft` lets
  the orphan sweep touch a draft, and an absent journal proves nothing.
- **Files outside SwiftData need an owner and a sweep.** Photo and tile
  deletion is fire-and-forget, so at launch `TileCache.trimCache(claimedBy:)`
  and `HikePhotoStore.reclaimOrphans(claimedBy:)` sweep from a *complete* claim
  set. A failed fetch sweeps nothing.
- **Persisted identifiers are stable:**
  - provider IDs
  - `SettingsKey` strings
  - the container and App Group IDs
  - the widget kind
  - the tile-key shape
  - the deep-link format
  - `MovementReminderKind` raw values (they double as notification categories)
  - the Live Activity attributes type name
  - the first-run tips' ids, which their closed and used state is stored
    against (`FirstRunTipsTests`), and the name of `AppTips.isNewHiker`,
    the TipKit parameter that keeps a new hiker

## Conventions

### Deployment floor

- **The floor is iOS 18.4 and watchOS 11.0.** The packages declare the same
  generation (macOS 15.4, visionOS 2.4), so that `swift test` refuses what the
  iOS build refuses. Below 18 the app would lose `Mutex` and the Control
  Center control. 18.4 is `DispatchQueue` as a `TaskExecutor` (`TileCache`,
  `TrailBasemapRenderer`), and every iPhone that runs 18 can update to it.
- **A newer API is reached through one wrapper, with its fallback beside
  it.** A screen asks for a shape or a behavior, never for a release. The
  `if #available` lives in:
  - `RoleButton` (`OpenHikesShared`), for the role-only close, cancel and
    confirm buttons. Below 26 they say *Cancel* and *Done*, or the screen's
    own verb (*Save*, *Add*, *Send*), and a pill or a notice draws the glyph.
  - `LiquidGlass.swift` and `GlassButtonStyle.swift`, for SwiftUI glass, which
    falls back to the regular material and the bordered styles, as the
    visionOS branches always did. `MapGlass` does the same for the map's
    UIKit controls.
  - `observedValues(_:)` for `Observations`, `LifecycleObservation` for the
    typed lifecycle messages, `ReverseGeocode` and the `MKMapItem` readers
    beside it for MapKit's iOS 26 geocoding (`CLGeocoder` below), and
    `askToContinueInForeground(_:)` for an intent's foreground hand-off.
  - `trailStopsReorderable(_:move:)`, for the one iOS 27 API: `reorderable()`
    on 27, `onMove` below.
- **A fallback with logic in it is tested on the current simulator.** Each
  wrapper exposes its earlier form, so a suite can hold it to the same
  contract on a release that would never run it: `EarlierObservations`,
  `LifecycleObservation(earlier:on:perform:)`, `TrailStopName.EarlierAnswer`,
  `TrailStopSlot.drop(in:moving:to:)` and `EarlierMapGlassView`.
- **Swift Testing refuses `@available` on a `@Suite`.** Put it on each
  `@Test`, and on the helpers that build the newer values.
- **The compiler does not check SF Symbol names.** A `systemName:` newer than
  the floor compiles and draws nothing. Look a new one up in the SF Symbols
  app's `Contents/Resources/Metadata/name_availability.plist`, where 2024 is
  iOS 18.0.
- **Some differences compile and only show at run time.** Each of these
  passed on iOS 27 and failed on iOS 18.6:
  - Foundation's ISO 8601 parser insists on a fraction the style includes
    (`GPXImport` keeps a whole-second style beside the fractional one).
  - `URL` keeps no query for an opaque URL such as a `mailto:`; read one
    through `URLComponents`.
  - `UIColor(Color.accentColor)` resolved outside a view is the system blue;
    the `AccentColor` asset is the accent.
  - ImageIO writes no XMP into a PNG it copies, so only a JPEG, a HEIC or a
    TIFF takes a Commons credit there.
- **Nothing in CI runs on the floor.** The image has no iOS 18 runtime, so the
  compile at 18.4 is the only gate there. Before a release, and after changing
  a fallback, run the unit suite on an iOS 18 simulator (*Build and test*).
  Xcode 27.1 will not download one (`iOS 18.4 is not available for
  download`), so it has to be a runtime an earlier Xcode installed. An image
  still in `/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime`
  comes back with `xcrun simctl runtime add <its .dmg>`, with nothing to
  download.

### Concurrency

- **UI and SwiftData are main-actor isolated.** The project sets
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency and
  warnings as errors.
  - Delegate callbacks are `nonisolated`. They reduce what they received to a
    `Sendable` value before hopping, then use `onMainActor { … }`
    (`General/MainActorDelivery.swift`), which runs synchronously when it is
    already on the main thread. That keeps GPS batches in order;
    `RecordingFixPolicy` silently drops a reordered pair.
  - A callback that must `await` keeps `Task { @MainActor in … }`.
  - A `withObservationTracking` `onChange` stays deferred, because it fires
    mid-mutation.
- **To leave the main actor, put `@concurrent` or `nonisolated` on the callee,
  never a bare `Task {}`.** A bare task inherits main-actor isolation. A plain
  `nonisolated async` function runs on its caller's executor, so use
  `@concurrent`, and put it on the protocol requirement when "off the main
  actor" is the contract.
  - `CloudSyncCoordinator.offMainThread(_:)` and `PhotoLibraryWriting.save` are
    where this shipped as a bug, and are now guarded by tests.
  - `lazy` changes when the work runs, not where.
- **Spell `nonisolated` on the extension**, not only on the type. An
  unannotated extension of a `nonisolated` type is still a main-actor context,
  and Swift 6.3 rejects nested types in one. Every `CloudKitCommunityTransport` extension says
  `nonisolated`.
- **Blocking work stays off the main thread:** tile math, image encoding and
  disk enumeration. Hot paths call `assertOffMainThread`. Shared off-main types
  are `Sendable`, and singleton state sits behind the existing `Mutex` pattern.

### The map screen

- **Present modals from inside the sheet's contents.** `MapSheet` is presented
  permanently in portrait. A `.sheet`, cover, picker, importer or alert attached
  beside it never presents, and an alert can even take the sheet down. Every map
  alert lives in `MapScreenAlerts`, and `MapScreenAlertUITests` checks them,
  except the trail maker's missed-photo alert: it is attached beside them on the
  same contents, because a seventh parameter is past the lint limit.
- **The primary surface has two shapes: a sheet when the window is taller
  than wide, a panel when it is wider.**
  - A compact height ignores detents, so `MapSidePanel` draws the same
    `MapSheet` beside the map, and `SheetPresentation.layout` settles the
    differences.
  - A wider window of regular height — an unfolded iPhone Duo, an iPad later —
    takes the panel too, by choice; there the sheet was a card in the middle
    of the bottom edge. `SheetLayout(windowSize:isCompactHeight:)` is the rule.
  - `verticalSizeClass` and the window's size are read only in
    `SheetLayoutReader`.
  - The sheet keeps its toolbar across its top (`horizontalSheetToolbar()`).
    A closed iPhone Duo stands a sheet's toolbar up its side, and the compact
    detent holds one button of that column.
  - Only the map ignores the horizontal safe area, plus a photo viewer, which
    `MapSidePanel` widens to edge to edge.
  - `SheetPresentation` keeps each pushed screen's state objects until the
    route pops, so rotation keeps them. A cover driven by a destination's own
    `@State` closes on a turn.
  - `OrientationUITests` guards all of this.
- **Make a push reach `NavigationStack` in one pass per frame.**
  - Outside a tap, write the selection and the detent first and the path last,
    in a single assignment (`SheetPresentation.path`).
  - Navigation requested from outside a view goes through an `EventFeed` read
    by a `.task`, never through a token watched by `onChange`.
  - When this goes wrong, SwiftUI logs "tried to update multiple times per
    frame".

### Tiles

- **Respect provider policy.** `TileProvider.supportsBulkDownload` gates
  prefetching, and OpenStreetMap is auto-save only. Waymarked Trails is a
  `TileLayer` with no bulk download, and stays out of `TileProvider.all`.
- **A tile is identified by provider plus z/x/y**, never by scale
  (`TileCacheKey`).
- **Never turn a render miss into synchronous disk or network work**, and never
  measure storage in a body. Delete durable tiles through `TileOwnership`.

### Accessibility

- **A composite row is one element with one label and value** (`HikeRow`,
  `StatRow`, the settings rows…). UI tests find a row by identifier plus label
  prefix (`hikeRow(titled:)`).
- **Selection shown only as a tint** carries `.isSelected`.
- **A glyph-only button** carries an `accessibilityLabel` and
  `minimumTapTarget()`.
- **Decoration** is `.accessibilityHidden(true)`.
- **Identifiers go on leaves, never on containers.**

### Platform contracts

- **`OpenHikes/PrivacyInfo.xcprivacy` ships with the app.** It declares four
  required-reason codes (`CA92.1`, `C617.1`, `3B52.1`, `35F9.1`) and five
  collected types, all linked to the user and none used for tracking: precise
  location, photos, other user content, user ID and fitness. Publishing a hike
  sends all five.
  - A new required-reason API adds its code in the same change.
  - `PrivacyManifestTests` pins the collected set both ways.
  - The widget extension has no manifest of its own, because it calls none of
    those APIs.
- **Background location is described in three places, and they must agree:**
  the `Info.plist` purpose strings, the Background Trail Tracking footer, and
  App Review's notes in App Store Connect. Always access is for the widget and
  the Live Activity; the `location` background mode is for the recorder.
- **Strings live in String Catalogs, and English is the only language.**
  - `xcodebuild` does not merge extracted strings the way the IDE does. After
    changing text, build, then run
    `Scripts/sync-string-catalogs.sh <derived-data>`. CI's `--check` exits 2
    when a catalog is behind. `Scripts/check-string-extraction.sh` audits the
    source for copy that bypasses extraction, including concatenations and
    `String` label parameters. It reads helper parameter types with the selected
    toolchain’s SwiftSyntax and runs regression fixtures. Intentional machine
    text and prescribed credits are listed with reasons in
    `Scripts/string-extraction-exclusions.json`; stale entries fail the gate.
    Shared App Intent metadata and `RoleButton` defaults must remain in their
    package declarations. The sync script derives temporary typed literals
    from them and asks the compiler to extract those for all four catalogs;
    no second copy of their wording is checked in.
  - A count is a plural variation, never `if count == 1`.
  - Figures are formatted per locale and never catalogued.
- **OpenHikes Pro is one monthly subscription.**
  - **`MapEntitlementStore.productID` (`…pro.maps.monthly`) never changes.**
    It is recorded against every purchase. The name customers read lives in the
    paywall's title.
  - **`MapPaywallView` lists everything Pro unlocks and unlocks everything it
    lists**, because App Review checks both directions. Today that is the paid
    map styles (Stadia Outdoors, Stamen Terrain, Thunderforest Outdoors), offline
    Stadia maps, and Stadia elevation where a trail has none. A change updates
    the paywall, `OpenHikes.storekit`, `docs/terms/`, the README and App Store
    Connect together.
  - Everything else is free, the community included.
  - The paywall stays reachable from About even when no keys are bundled.
- **Remember only the negative entitlement answer.** `MapEntitlementStore` starts
  as `.notEntitled` if that was the last answer, and as `.unknown` otherwise.
  `.unknown` is already permissive, so a subscriber's map never flickers locked,
  and a non-subscriber never gets billed tiles while waiting for StoreKit.

## Render isolation, in practice

These rules are what keep an idle map at zero SwiftUI body evaluations, a chart
scrub from re-running anything above the chart, and a backgrounded recording
from rendering at all. Every one of them first produced a convincing wrong
answer.

- **Only a `View` type is a boundary.** A helper `func`, a computed `var` and a
  `.toolbar`, `.overlay` or `.safeAreaInset` closure are all inlined into the
  declaring body. A `ViewModifier` is a boundary for its own dynamic properties
  and the reads in its `body(content:)`, but its arguments are evaluated in the
  body that applies it: a `.sensoryFeedback(_:trigger:)` written on a screen
  makes its trigger an input of that screen.
- **A binding belongs to the body that creates it.** That body re-runs on every
  write, and `Binding(get:set:)` reads its getter during construction.
  - Fix shapes: `HikeTitleEditor`, which makes its own binding
    (`HikeTitleEditorIsolationTests`), and `SheetPresentation.pathBinding`, which
    is built once.
  - A screen's `@FocusState` re-runs that screen whenever the keyboard comes or
    goes.
  - A view that stores one re-runs on every write through it too, equatable or
    not, because a `Binding` is a `DynamicProperty` (next point).
    `ElevationChartPlot` holds none: the marks keep the selection
    (`ElevationScrubSelection`) and the plot passes on closures.
- **Any `DynamicProperty` invalidates the view that declares it**, even if
  nothing reads it. `@Environment(\.dismiss)` is the worst offender: its value
  is new on every presentation pass, and one backgrounding rebuilt a photo grid
  eight times.
  - Fix shapes: `SheetPresentation`, which keeps raw state
    `@ObservationIgnored` and publishes coarse flags, and `DismissButton` /
    `.dismiss(when:)` (`General/Dismissal.swift`).
- **`@AppStorage` re-runs its view on every write to its defaults suite, for
  any key.** Screens that are always up read `StoredSettings`, which assigns
  only values that changed (`AppStorageInvalidationTests`).
- **Nothing above the root may rebuild it.** `OpenHikesApp`'s body runs on every
  scene phase, so it builds only `AppRoot`, which holds only the model.
- **A pushed screen with closure inputs is rebuilt by every push over it.**
  Compare what it draws from, by identity, and leave the closures out
  (`HikeDetailView+Equatable.swift`, `MapSheet`, `MapSheetHikes`).
- **A `.safeAreaInset` on a screen pushed into the sheet costs the whole
  sheet.** Each re-run of the body that applied it re-evaluated `MapSheet`
  and everything under it a second time. Put such content in the screen's
  own layout, as `RecordingPlaceTips` is.
- **A computed property that sorts looks like a field access.** Read
  `Hike.orderedPhotos` once per pass.
- **`@Observable` filters same-value writes only for `Equatable` properties, and
  `@Model` filters none.**
  - A dedup guard on an `Equatable` observable property therefore cannot be
    proven by a test, because the runtime has already filtered the write.
  - A guard on a non-`Equatable` property is load-bearing
    (`RouteHighlight.move(to:)`, `LocationManager.publish`).
  - `RenderIsolationTests+Observation.swift` pins both behaviors.
- **A zero-assertion is evidence only once you have watched it fail.** An
  observation count cannot measure a throttle, because `ObservationCounter`
  re-arms through a `Task`. Assert the throttle's effect instead.
- **A cost prediction is a hypothesis.** Measure both sides.

**Measuring.** `Scripts/render-trace.sh` runs a UI-test selection under
Instruments and credits every body evaluation, with the property changes that
caused it, to the test step it ran in. Give it the pool device and the
checkout's own build, as `run-ui-tests.sh` takes them
(`--device "$udid" --derived-data DerivedData`).

- `report.md` leads with hot spots (a view that ran three or more times in one
  step). `bodies.tsv` holds the counts.
- **Compare two runs.** Run the same selection on `main` and on the branch, then
  `--report <branch> --baseline <main>/bodies.tsv`.
- A count is a question, not a verdict. Look for bodies that run in an
  unrelated step, or once per keystroke, fix or frame.
- A body with no property update before it is *unexplained*; add
  `Self._logChanges()` to it next.
- The trace facility is one per machine, so the script refuses to start while
  another `xctrace record` runs.
- Durations come from a Debug build on a simulator. They are comparable between
  runs but are not frame budgets; use device Instruments for frame time and
  energy.

## Energy policies in force

Each policy started as a measured finding and is now shipping behavior, argued
in its source header. Do not weaken one without a measurement.

- **GPS accuracy follows conditions** (`Recording/RecordingEnergyPolicy.swift`).
  `desiredAccuracy` drops only for Low Power Mode or thermal `.serious` and
  above. `.fair` is excluded, because a phone in a sunny pocket sits there all
  summer. `distanceFilter` also widens when the hiker stands still.
- **Tile fetching is split by purpose** (`Tiles/TileNetworkPolicy.swift`).
  `.interactive` (someone is looking) and `.speculative` (bulk downloads and
  prefetching ahead of need) are treated differently:

  | Condition | `.interactive` | `.speculative` |
  |---|---|---|
  | Cellular | allowed | denied |
  | Offline or Low Data Mode | denied | denied |
  | Low Power Mode or thermal pressure | allowed | denied |

  The policy has no setting. Every refusal logs a stable `reason` and serves
  saved coverage.
- **A pause spends nothing unless something will read it**
  (`Reminders/MovementReminderController.swift` decides whether to watch;
  `SystemRecordingLocationSource.startMovementWatch()` in
  `Recording/HikeRecorder+State.swift` picks the feed). With reminders off, or
  before the first fix, GPS stops. Otherwise the app uses the cheapest delivery
  that still notices a departure: significant-change monitoring with Always
  access, or a 100-meter feed with When In Use.
- **The screen stays awake only on a claim, and only if asked**
  (`General/ScreenWake.swift`). `SettingsKey.keepScreenAwake` is off by default.
  The switch, a live subject and an active scene must all agree.
  `ScreenWakeCoordinator` counts claims and is the only writer of
  `isIdleTimerDisabled`.
- **A backgrounded recording draws nothing and ticks nothing.**
  `MapView.Coordinator` defers overlay work until the app returns, driven by
  `UIApplication` notifications rather than SwiftUI. The 1 Hz `TimelineView`
  exists only while the scene is `.active`. The location background mode keeps
  the app running, so iOS will not stop those timers for you.

## Schema and migration policy

- **Preserve only the current formats.** The owner treats existing data as
  resettable: users can reinstall, and the CloudKit data can be cleared.
  - Do not write frozen historical models, `SchemaMigrationPlan` stages,
    launch-time conversions, legacy decoding branches or compatibility-only
    fields.
  - Edit the live `OpenHikesSchema` (`1.0.0`) in place.
  - This is a reset policy, not a promise that an old store opens. Still, never
    erase a store on an open failure: the in-memory fallback and alert handle
    it.
  - Keep the current-format tests that reopen both stores, check the `hikeID`
    join, and exercise deletion and recording recovery.
- **For an incompatible change, stop the app and widget, then discard the
  affected local state.** That means the stores and their side files, tile
  manifests and files, journals, App Group snapshots, basemaps, pending fixes
  and changed settings. Reset mirrored data together with local data, or the
  old records come back.
- **Versioned payloads match exactly.** The shared snapshots (v1) and the
  journal header refuse any other version, with a diagnostic; that is
  validation, not migration. Derived caches carry no version and are
  regenerated when they fail to decode. The trail graph's region cache is the
  exception, because its older files still decode: it counts its format
  (`OverpassTrailGraphProvider.cacheFormat`). A region in another format reads
  as expired. It is fetched again when next asked for, and serves as a
  fallback until a fetch succeeds.
- **Revisit this policy only when installs must survive upgrades.** Then:
  - Freeze the actual model and every encoded type.
  - Write a real migration plan.
  - Test previous-version stores from disk.
  - Never put a new version number on today's model.

### CloudKit

- **Mirroring constraints.** A non-optional mirrored attribute needs an inline
  default, relationships are optional, and uniqueness constraints are forbidden.
  `MirroredCloudKitSchemaTests` compares the model with
  `MirroredCloudKitSchema.recordTypes`, where every new synced field must be
  added. It never contacts CloudKit, so it cannot catch a field the container
  lacks.
- **Records and schema differ.** Development records are disposable. A
  production schema can only be added to; nothing in it can be deleted, renamed
  or retyped. Resetting the development environment restores the production
  schema, so a field staged in development and not yet promoted is lost.
- **Only a Console promote changes production.** SwiftData creates a column in
  development on the first non-nil save, but a save in production cannot add a
  field. So a new synced field must be promoted before any build that writes it
  reaches the production environment, and an App Store Connect upload,
  TestFlight included, does:
  1. `xcrun cktool export-schema`, then add the line.
  2. `validate-schema`, then `import-schema --environment development`.
  3. Re-export and check the result.
  4. Promote in the Console. `cktool` has no promote command.

  Field shapes:

  | Swift type | CloudKit field |
  |---|---|
  | `String?` | `STRING QUERYABLE SEARCHABLE SORTABLE` |
  | `Data?` or a `Codable` array, without external storage | `BYTES QUERYABLE SORTABLE` |
  | `Int` or `Bool` | `INT64 QUERYABLE SORTABLE` |
  | `Double` or `Double?` | `DOUBLE QUERYABLE SORTABLE` |

  A hand-declared shape is inferred, so let a development build save the field
  once before promoting. An `@Attribute(.externalStorage)` column, such as
  `Hike.route`, also mirrors through a `CD_<name>_ckAsset` asset field: check
  that the development export has it, and promote both.
- **Deployment state, checked 2026-10-25.** Development and production export
  the same schema, `md5 a3ab9849bf6af7d5bf89fb03d667682f`, with a column for
  every attribute in `MirroredCloudKitSchema.recordTypes`.
  The only live columns the contract does not
  name are SwiftData's own `CD_entityName` and the to-one reference columns
  that the contract lists as relationships. Re-export before believing these
  numbers, and update this paragraph when they move. Deployment facts live
  here, not in code.

## The community feature

Sharing publishes a hike to the **public** CloudKit database of the same
container. That database is the developer's storage, everyone can read it, and
it is the one place where data leaves the device for a database other people
read. `Community/` is separate from `Sync/` and never touches the
`ModelContainer`. It nests by job: `Transport/`, `Curated/`, `Browse/`,
`Listing/`, `Publishing/` and `Review/`.

### The schema is the moderation gate

CloudKit grants permissions per record type, never per field, so review is
enforced by the schema rather than by a flag. `CommunitySchema` spells the
types, and `SECURITY.md` explains them to readers. Every type except the queue
is world-readable, because browsing needs no account.

| Record type | Created by / written by | Indexes |
|---|---|---|
| `CommunityHikeSubmission` (an upload) | any signed-in account / `reviewer` | **none** |
| `CommunityHike` (the listing) | `reviewer` / `reviewer` | `location`, `title`, `publishedAt`, `submission` |
| `CommunityPhotoSubmission` (offered photos) | any signed-in account / `reviewer` | **none** |
| `CommunityPhotoContribution` (published photos) | `reviewer` / `reviewer` | `listing`, `photoSubmission`, `publishedAt` |
| `CommunitySubmissionNotice` (the queue; `reviewer` reads it) | any signed-in account / `reviewer` | `___recordID`, `___createTime` |

- **A submission is write-once.** A listing points at its submission, so an
  author who could write would be able to swap an approved route.
  - Amending a route means a removal request plus a fresh share. A takedown is
    a reviewer's delete.
  - A reviewer may correct only the title (on the listing) and which
    photographs go (`keepOnlyPhotos`, before the listing exists).
- **The missing indexes are the security control.** A submission is fetched
  only by record ID, so any index on one, including the `___recordID` the
  Console adds by default, would list every unreviewed upload. `authorID` has
  no index either, or anyone could enumerate one person's hikes.
- **A new field arrives indexed.** A field that a first save auto-creates
  arrives with every index, and an auto-created type also gets
  `GRANT WRITE TO "_creator"`. Change the schema by import (as in *CloudKit*
  above) and **re-read the index list after every change**. A promote can also
  drop indexes and downgrade grants.
- **No export shows the role membership.** `reviewer` membership is set per
  environment in the Console. Whether an account can add itself to `reviewer`
  (`Users` grants `WRITE TO "_creator"`) is unverified, so test it before
  trusting the role in production.

### Rules that hold it up

- **A suite must never reach the real transport.** There is no sandbox for a
  public database.
  - Under `isRunningTests` (UI tests included),
    `OpenHikesModel.makeCommunityTransport()` returns `nil`, which removes the
    share button and the list.
  - The only way past that is `--ui-test-community=<scenario>`, which selects
    the `DEBUG`-only `SeededCommunityTransport`. `published` is the only
    scenario that reaches the published state; `curated` and `commons` seed the
    OpenStreetMap and Wikimedia halves.
- **The feature is free**, including publishing and photo contributions.
  Nothing on the publish path checks an entitlement. Do not add one back
  without the decision being made again in the open; only the schema decides
  what reaches other people.
- **The server decides who reviews.** No role is stored. `reviewQueue()`
  reports a refusal as `.notPermitted`, not as an empty list, and
  `CommunityReviewQueue.isReviewer` only hints at what to draw. A failed queue
  load draws nothing; a failed action is reported.
- **Publication has three derived states.** `CommunityPublicationState` derives
  `notShared`, `awaitingReview` or `published` from two columns on `Hike`.
  - A decline leaves no record, so the UI never says *rejected*.
  - Only `CommunityPublicationCheck.refresh` learns `communityListingID`, and
    it fails silently. A new route share clears it
    (`CommunityUploadQueueing.record`), and so does `forgetPublication`.
  - Un-publishing happens only through an explicit *Check Whether It's Still
    Live*. `forgetPublication` clears both columns only after the listing is
    confirmed gone, because queries are eventually consistent.
- **Reporting is an email; blocking is device-local.** Both follow from
  account-free browsing.
  - `CommunityReport` composes a `mailto:` naming both record names.
  - `CommunityBlockList` keeps blocks in unsynced `UserDefaults`.
  - Blocks are keyed on `CommunityHike.authorID` (the CloudKit creator, which
    the app copies at publication), never on a typed name. A listing without an
    `authorID` is dropped.
  - Blocked authors are filtered on read and excluded before a page's `limit`
    is spent (`CommunityPageBudget`).
  - Report and Block sit on the content's screen, never on a row. Contributed
    photos get their own (`CommunityPhotoActions`).
- **A submission and its review notice are two saves, and a failed notice must
  not lose the upload.**
  - A refused notice comes back as `CommunityQueueingFailure`, carrying the
    name of the submission that did land.
  - `CommunityUploadQueueing.record` keeps that name in the mirrored column
    and in a device-local marker (`HikeLocalState.unqueuedSubmissionID`,
    `unqueuedPhotoSubmissionID`).
  - *Finish Sending* then saves the notice and nothing else; it never
    re-uploads. The notice is named `notice-<submissionID>`, so a retry saves
    the same record.
  - `.serverRecordChanged` reads as *already queued*. A permission failure is
    never read as success.
  - Two server answers are assumed and not yet observed: `.serverRecordChanged`
    for a re-save without a change tag, and `.referenceViolation` for a notice
    about a deleted submission. Check both against the development container
    before a promote, never from a test (`CommunityRecordWriting` is the seam
    the suites script).
- **Photos can be added to an already-listed trail** as a second pair of record
  types, not as an edit.
  - `CommunityHike.photoCount` stays the author's count.
  - Contributions load when a hike opens, never for a list, budgeted to 20 sets
    and 60 photos.
  - `HikePhoto.sentToCommunityAt` starts a photo already sent struck off the
    contribution form, and one tap puts it back: a default, not a filter.
- **What is sent is stated, and the statements move together.**
  `CommunityShareDisclosureTests` holds the share footer to the payload. The
  privacy manifest, `docs/privacy/` and `docs/terms/` change whenever what is
  sent changes, what a reviewer may do changes, the removal, *Check Whether
  It's Still Live*, reset or *Finish Sending* flows change, what the Commons
  requests ask for or keep changes, or `CommunityPublisher.maximumPhotos` (36)
  changes. That limit is the first number to lower if storage costs bite.
  App Store Connect's own privacy answers are separate, and the manifest does
  not update them.

### OpenStreetMap and Wikimedia Commons

- **Two sources feed the list.** `MergedCommunityTransport` combines CloudKit
  with `CuratedTrailSourcing` (Overpass `route=hiking` relations).
  - The `limit` is spent on CloudKit first, so a published hike never loses its
    place.
  - A curated failure comes back as a `CuratedTrailOutage` beside the rows,
    rather than failing the whole answer.
  - Calls route on `CommunityIdentity`, and `CommunityOrigin` is a sum type, so
    a curated ID never reaches CloudKit.
  - A curated route has no Report, Block or Take Down. It links to
    openstreetmap.org instead, which is also its ODbL attribution.
- **Only a hiker's own request asks Overpass.** `overpass-api.de` allows a few
  request slots per address, and has answered this app with a `429`.
  - `CommunityQueryPolicy` turns a pan into an *offer*, never a request.
  - Nothing is fetched until the *Community* tab opens.
  - All requests share `OverpassConversation`'s gate and its single retry.
  - Relations are cached on disk (`CuratedTrailStore`), and a refused search
    falls back to them while still showing the outage.
- **Stadia elevation is Pro-only and never fetched for a list.** A curated
  route asks once, on open; the trail maker asks once the drawing settles.
  `StadiaElevationSource` is billed per call, so it refuses before forming a
  request unless `MapEntitlement.current` is entitled (`.unknown` refuses too).
  The default source is `DormantElevationSource`.
- **Commons photographs** fill a curated route's strip and the area search
  (`CommonsPhotoSourcing`, live only from the composition root).
  - Keep only CC BY, CC0 or public-domain files, credited with
    `PhotoLicenseCredit`.
  - Fetch over HTTPS from the two hosts the privacy policy names
    (`CommonsPhotoQuery.imageHosts`), sending `TileCache.userAgent`.
  - Make one API request at a time, and fetch nothing in Low Data Mode.
  - Never offer one for community sharing: `HikePhoto.isOwn` is false.
- **Shared hikes draw as lines and pins.** `CommunityRouteOutline` is a polyline
  of about 1 KB on the submission, so a page's outlines arrive in one
  `desiredKeys` fetch. MapKit never hit-tests overlays, so the app does
  (`RouteHitTest`). Pins stay, because a polyline is not an accessibility
  element.

## The watch app

`OpenHikesWatch` is a watchOS 11 companion, embedded in the phone app. Read
this before changing `OpenHikesWatch/`, `OpenHikes/Watch/` or the shared
`Watch/` folder.

- **One recording has one owner: the device that started it.**
  - Watch to phone: a recording in progress never crosses, and there is no
    payload for one. The finished walk arrives as an import, like a GPX file
    (`WatchWalkImport`).
  - Phone to watch: the recording is mirrored, and the watch drives it through
    `HikeIntentCoordinator`. That makes it a fourth surface beside the Live
    Activity, Control Center and Siri, holding no state of its own
    (`WatchRecordingMirror`).
- **The mirror runs only while the watch app is reachable** (in the
  foreground). It publishes on the Live Activity's 20-second floor, and only
  when a figure moves. It sends the clock once, as an anchor, and carries
  `LiveRecordingReport`'s figures only.
- **Commands use `sendMessage` with a reply handler, and have no fallback.** A
  button press delivered late is worse than none.
- **A phone recording outranks the watch's own.** The watch refuses to start
  while the phone records. The reverse is unguarded: the phone never learns of
  a watch recording.
- **Which `WCSession` door a payload uses is a decision.** The library goes as
  the application context (latest wins). The live recording mirror goes by
  `sendMessage` with no reply and is dropped when the watch is out of reach,
  because a late reading is a wrong one. Everything else, including the trail
  request, goes by `transferUserInfo`, because `sendMessage` fails out of range.
  `WatchLink` is the only encoder, with one function pair per
  `WatchMessageKind`.
- **A recorded walk is written before it is sent.**
  - `WatchStore` queues it on disk and drops it only on a `WatchWalkReceipt`.
  - The phone's import is idempotent on `HikeLocalState.watchSessionID`.
  - A failed write leaves the walk `.unsaved` (`WatchStoppedWalk`).
  - Until Stop, `WatchRecorder` journals fixes, pauses and resumes. A crash
    resumes the workout session, or offers Continue, Save or Discard; the
    outage counts as a pause.
- **The watch matches against the trail itself.** `WatchRouteTracker` uses one
  polyline. It is not `TrailMatcher` and must not grow toward it. Its
  thresholds are `RouteProfile`'s (`WatchFixPolicyParityTests`), and an
  out-and-back is settled by course on both devices
  (`RouteProfileHeadingFirstTests`).
- **The workout session only keeps the app alive.** Its builder is always
  discarded, because the phone's `HealthKitWorkoutWriter` is the only Health
  writer. The session is read for heart rate alone.
- **There is no watch test bundle.** Decisions live in `OpenHikesShared` value
  types under `swift test` (`WatchRouteTracker`, `WatchWalkAccumulator`,
  `WatchFixPolicy`, `WatchStoppedWalk`, `WatchLink`, `WatchGlanceDisplay`…). The
  watch target keeps only Core Location, HealthKit and SwiftUI. The phone's half
  is tested in `OpenHikesTests/Watch/`.
- **Render isolation applies here too.** `WatchRecordingStats` and
  `WatchFollowState` are read only by leaf views, and `WatchRootView` reads
  nothing.
- **Maps come from MapKit, without tiles.** `TrailMapScreen` is a `Map` with a
  `MapPolyline`, because tile overlays are unavailable on watchOS. Double Tap
  pauses and resumes, and never starts or stops.
- **The complication shows only the watch's own recording.** It reads a
  `WatchGlance` from the watch's **own** App Group
  (`group.tappium.com.OpenHikes.watch`). `WatchGlanceDisplay` and
  `WatchGlanceReloadPolicy` decide what it shows and when it redraws.
- **Not on the watch:** community, photographs, weather and offline maps.
  Following a trail without recording updates only while the app is on screen.

## Settled decisions — do not re-raise

Each of these looks like a finding, and has already been investigated.
Reopening one needs new evidence, not a fresh reading of the same code.

- **Types that should not become actors.**
  - `TileCache`: its `Mutex` makes bump-then-delete atomic, and an actor's
    suspensions would reintroduce the interleaving it forbids.
  - `HikePhotoStore`: its state is a thread-safe `NSCache`, and an actor would
    serialize decodes.
  - `SerialAsyncQueue`: an actor gives no FIFO ordering across suspensions and
    no barrier.
  - `SharedStore`: its hazard is cross-process, and every write is `.atomic`.
  - `RecordingStats` and `RecordingTrace`: they are read synchronously in the
    MapKit path.
  - `PendingRecordingFixStore.withExclusiveLock`: `flock()` is cross-process.
- **Older API that is justified, not legacy.**
  - `MKMapView` rather than SwiftUI `Map`: `Map` re-diffs on every observable
    change, and it cannot host the tracking button or the custom renderers.
  - `CLLocationManager` rather than `liveUpdates()`, which stalls under
    `simctl location`.
  - The few GCD uses, each required by an API with no async form or by
    synchronous blocking work that should not be awaited (`TileCache`'s
    maintenance queue, `TrailBasemapRenderer`'s render executor).
  - `UIImagePickerController` for the camera.
  - `CLGeocoder`, `MKPlacemark` and `ForegroundContinuableIntent` below iOS
    26, where each is the only form there is, reached only through its
    wrapper (*Deployment floor*).
  - The lint-pragma'd force unwraps of literal URLs in `MapPurchaseLinks` and
    `TileAttribution`.
  - The `fatalError` when even the in-memory store fails.
- **A store-open failure is reported without saying which store failed.** Both
  stores belong to one container, so a corrupt sidecar fails exactly like a
  corrupt primary, and telling them apart would take a second open
  (`StoreFailureAttributionTests`).
- **The iCloud switch takes effect at the next launch.** Swapping the container
  mid-session would detach the recorder, the tracker, every `@Query` and the
  intent coordinator, and mid-recording it would cost the walk
  (`CloudSyncRecordingTests`). Settings sync switches at once.
- **Deliberate test seams, not production indirection.** Transports, clocks,
  defaults, location sources, render boundaries and containers are injectable so
  that suites never touch singletons, the network or the wall clock. The bundle
  is one process. A live call fails no `#expect`: `TrailBasemapRendererTests`
  once spent 570 green seconds on live snapshots. It now has a `.timeLimit`, and
  a stub that records an issue if a live render is attempted.
- **`StoreKitTest` cannot be used.** It needs a warnings-as-errors exemption,
  and even then `SKTestSession` never attaches under `xcodebuild test`, and
  `AppStore.sync()` never returns in a hosted test. This was measured on Xcode
  26.6, and `MapEntitlementStoreLaunchTests` has the argument. Purchases are
  tested through the seams.
- **ActivityKit is untestable in a hosted test.** Policy sits above
  `HikeActivityPresenting`, and the controller is `nil` under `isHostingTests`.
  - `Activity` is boxed in a `nonisolated` `@unchecked Sendable` handle.
  - `ActivityState` is matched positively.
  - A running activity is adopted, never requested twice.
- **A live recording outranks the selected trail, on every surface, without
  qualification.**
  - The widget replaces the trail rather than badging it, and a paused
    recording keeps the widget.
  - The takeover writes nothing, so the trail returns the moment the recording
    clears.
  - A finished recording still lingers on the Lock Screen while the widget
    returns to the trail at once. That split is deliberate: the panel shows a
    result the hiker may not have read yet, and the widget shows what is
    happening now.
  - Who owns the widget, whether it is worth spending on (`isCapturingFixes`)
    and what the Control Center button does are three different predicates on
    purpose.
  - Trail redraws go through `TrailWidgetReload.requestUnlessRecording()`.
  - The takeover has **no staleness window**: a killed launch's recording keeps
    sampling fixes, and that is the recovery path working.
- **Photo pixels stay on the device the photo was added on.** A `CKAsset` column, an
  app-owned zone and fetch-on-demand were each rejected, because the private
  quota belongs to the hiker. Another device shows the photo as unavailable
  (`PhotoUnavailability`), with no retry and no remove. The community's public
  copies do not reopen this.
- **The live average speed keeps its clock, and is spoken in full.** Every
  *Avg Speed* that is not named for a clock divides by the walk's active
  clock: the time between kept fixes, which leaves pauses out and counts a
  rest taken without one. That covers the recording screen, the watch, the
  widget and Live Activity chip and the share card, and it is the clock a
  walk's *Active Time* shows. A saved hike's two averages are named for their
  own clocks, *Overall* and *Moving*, so after a pause the live figure matches
  neither. Moving time live would need a moving-time rule for the watch in
  `OpenHikesShared`, written without `Deque`, and a mirrored `HikeWalk` column
  for the share card to agree. The caption stays *Avg Speed*, which fits a
  watch tile, and every surface speaks "Average Speed", as the chip always
  has.
- **Two foreground location managers, on purpose.** iOS coalesces demand to the
  most demanding request, so the second manager costs dispatch, not power, and
  keeps background semantics out of browsing. Revisit only with a device energy
  trace.
- **Info.plists are written by hand** (`GENERATE_INFOPLIST_FILE = NO` on the
  shipping targets). Xcode 27.0's target editor crashed on a generated plist
  holding dictionaries. Re-test before flipping it back. Until then
  `INFOPLIST_KEY_…` settings do nothing, which `InfoPlistContractTests` verifies.
- **Claims investigated and found false.**
  - The widget deep link needs no `CFBundleURLTypes`, because the system routes
    a `widgetURL` straight to the owning app.
  - A trim cannot delete a tile that was just promoted.
  - `RouteMotion` really is read only by tests.
  - A synced `tileProviderID` cannot blank a keyless device
    (`TileProvider.renderable(id:)` falls back).
  - The two copies of `Color+Hex` are the widget's cost, and `ColorHexTests`
    holds them equal.
  - `.readWrite` photo access is required for reading and for limited access.
  - The bare `Task {}`s on main-actor types are main-actor work.
  - `aps-environment = development` is correct, because signing substitutes
    `production` on archive.
- **Load-bearing but never observed.**
  - The overzoom path assumes MapKit re-enters `draw` after every
    `setNeedsDisplay(_ mapRect:)`.
  - Mirroring is assumed to carry `@Attribute(.externalStorage)` routes as
    `CKAsset`s. Nobody has watched a 20,000-point route cross a real container.

## Documentation

Each fact lives in one file:

| File | What it owns |
|---|---|
| `AGENTS.md` (this file) | Commands, architecture, conventions, policies, settled decisions, CloudKit deployment facts |
| `README.md` | What the app is and needs, and how to build it and find your way around. No engineering rationale. |
| `CONTRIBUTING.md` | A person's short path to a first change. It points here. |
| `SECURITY.md` | Vulnerability reporting, and what the public database grants to whom (the argument stays in `CommunitySchema.swift`) |
| `Screenshots/README.md` | The App Store screenshot set and its capture scripts |
| `docs/` | The GitHub Pages site (privacy, terms, support) linked from the App Store listing. It is not a documentation folder; new prose goes at the repository root. |

- **Open work is a GitHub issue, never a checked-in list.**
- **Cite this file by section name.** Code comments cite sections such as
  *Schema and migration policy*, *Settled decisions*, *Deliberate test seams*
  and *The watch app*, so keep those names stable. Never cite a number or a
  quoted figure; those go stale.
