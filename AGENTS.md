# AGENTS.md

How code is written in this repository: the commands, the architecture, the
conventions, and the decisions that are already settled. Read it before
changing anything. [`README.md`](README.md) says what the app is,
[`CONTRIBUTING.md`](CONTRIBUTING.md) is the short path to a first change, and
open work lives in [issues](https://github.com/ZsomborRajki/OpenHikes/issues).

Most source files open with a header that argues for their design. When a rule
below names a type, a file or a test, that is where the longer reasoning lives.
This file keeps what a change must not break and where to read on. How a
feature behaves is in its source (see *Documentation*).

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

# The two local packages, on the macOS host, with warnings as errors as CI runs
# them (CI repeats both with --configuration release). Add --filter <Suite> for
# one suite, such as MercatorTests in OpenHikesShared.
swift test --package-path OpenHikesShared -Xswiftc -warnings-as-errors
swift test --package-path OpenHikesData -Xswiftc -warnings-as-errors

# The shell scripts, against stubbed xcrun, xcodebuild, swiftlint, periphery, osmium and pyosmium
Scripts/run-script-tests.sh

# The privacy policy and terms pages the app links, read out of docs/
Scripts/check-legal-pages.sh

# The watch app alone: the fast loop. The OpenHikes scheme already builds it,
# because the app embeds it.
xcodebuild build -project OpenHikes.xcodeproj -scheme OpenHikesWatch \
  -destination 'generic/platform=watchOS Simulator'

# UI automation (CI runs only the two accessibility classes): four simulator
# clones, then a serial pass
Scripts/run-ui-tests.sh --all --device "$udid" --derived-data DerivedData

# Give the simulator back once this session's testing is done
Scripts/sim-pool.sh release
```

CI runs the lint, the unit tests on the same device, both packages, the
script tests and the page check.

### Before trusting a run

- **Boot before you test.** `acquire` waits on `simctl bootstatus -b`. A cold
  simulator fails with "Early unexpected exit, operation never finished
  bootstrapping", or after nearly six minutes with "The test runner hung before
  establishing connection".
- **`-only-testing:` can select nothing and still pass.** An identifier it
  cannot resolve is ignored: a suite declared inside an `extension`
  (`BackgroundDeliveryTests` lives in `extension WidgetFeedSuites`), or a
  method missing its `()`. A job that pins identifiers has to count what ran,
  as `Scripts/check-sanitized-selection.sh` does for TSan.
- **Suspect the device before the code.** Failures that differ on every run
  (`Test crashed with signal kill`, `kAXErrorServerNotFound`,
  `Application … is not running`) mean two runs shared a simulator.
- **Rebase before trusting a timing.** A stale branch still pays for slowness
  that `main` has since fixed. Compare against `main` at the same commit.

### CI

`.github/workflows/ci.yml` has eight jobs that can fail a run: `Published
legal pages`, `Lint and shared package` (with the script tests, and both
packages in Debug and Release), `App and widget tests` (with strict suite
preconditions, the string-catalog check and the coverage floor), `iOS Debug
build`, `iOS Release build`, `Unsigned iOS archive`, `Thread sanitizer` and
`Accessibility UI tests`.

- **None of them is a required check.** `main`'s branch protection has no
  `required_status_checks`, so a red run reports a problem but blocks nothing.
- **A merged branch's runs are cancelled for it**
  (`cancel-superseded-runs.yml`, `Scripts/cancel-branch-runs.sh`), except a
  dispatched run's. The script refuses the default branch: a queued run there
  is the only thing that will ever say whether that commit compiles.
- **Documentation-only pull requests skip the jobs.** The `changes` job runs
  everything unless every changed path is `*.md`, `LICENSE` or under `docs/`. It
  is a job-level `if:` rather than `paths-ignore:`, because a skipped job
  reports success and so would not block a check made required later.
  `Published legal pages` always runs: it is the one job that reads `docs/`.
- **The toolchain is pinned.** CI uses the `xcode-27` image with Xcode 27.0
  pinned by `DEVELOPER_DIR` at the top of `ci.yml`, and its Swift is 6.4. A
  local Xcode 27.x matches only while `xcrun swift --version` says 6.4 too.
  While CI ran Xcode 26.6, that version difference broke `main` three times
  with errors no local build could show.
- **CodeQL is the exception.** `codeql.yml` stays on `macos-26` with Xcode 26.6
  until a CodeQL bundle supports Swift 6.4. That makes it the one job
  compiling with the older Swift and SDK, so it catches what Xcode 27 accepts
  and 26.6 rejects: a nested type in an unannotated extension (see
  *Concurrency*), a member of a type reached only through a transitive import,
  and a memberwise init hidden by a `private` stored property.
- **An API newer than CI's SDK needs a compile-time gate as well as
  `#available`.** `reorderable()` and `reorderContainer(for:)`, the app's only
  iOS 27.0 APIs, sit behind `#if compiler(>=6.4)` for CodeQL. The one iOS 27.1
  API, `toolbarVerticalBehavior(_:)`, sits behind
  `#if canImport(SwiftUI, _version: 8.0.85)`: CI's Xcode 27.0 is Swift 6.4 too,
  and only the SDK's SwiftUI version (8.0.84 there) tells it apart.
- **The coverage floor.** `OpenHikes.app` line coverage must stay at or above
  76% (`COVERAGE_FLOOR`), and the floor is never lowered. The measurement
  leaves out the files in `Scripts/coverage-exclusions.txt`, which are
  entirely SwiftUI body code that only UI suites evaluate. Put a new screen on
  that list in the same change; anything containing logic stays off it. A
  stale path in the list fails the gate.
- **Every `xcodebuild` in `ci.yml` passes `-skipPackagePluginValidation`.** Add
  it to any new call too: SwiftLint plugin trust is stored per user, and a
  fresh runner has none.
- **A program inside YAML is a program nothing checks.** Logic beyond a shell
  conditional goes in a script under `Scripts/`, where
  `Scripts/run-script-tests.sh` exercises it. The thresholds it enforces stay
  in the workflow as environment variables, beside the comments that argue for
  them.

### A second session on this machine

Two runs cannot share a simulator: the second install tears the first run's app
out mid-gesture, with no diagnostic. They cannot share a derived-data folder
either: the second run waits silently on the first run's build lock.

- **Get the device from the pool, never from `simctl create`.**
  `Scripts/sim-pool.sh acquire` hands out the lowest-numbered free
  `OpenHikes Pool <n>`, booted and with the photo library granted, and creates
  one only when every existing one is held, up to `OPENHIKES_SIM_POOL_MAX` (5).
  The same owner always gets its own device back, data intact, so it is safe
  to call before every test command. Inside Claude Code the owner is the
  session, and the claim ends with the session's process. The script's header
  has the rest.
- **Never boot, erase or delete an `OpenHikes Template (…)`.** A device that
  changes hands is replaced with a clone of a settled template, because an
  erased iOS 27 simulator downloads about 1.4 GB of Siri and speech models on
  its next boot. `Scripts/sim-pool.sh template` settles or refreshes one, with
  that download.
- **When the pool is full, do not make a device of your own**, and never delete
  a pool device or boot one by name. `status` shows who holds each device,
  `adopt <name|udid>` brings an idle leftover simulator in, `prune --keep <n>`
  deletes free devices beyond the lowest `n`, and `release` gives yours back.
  To try out a change to the pool script itself, set
  `OPENHIKES_SIM_POOL_PREFIX` to get a separate pool.
- **`Scripts/run-ui-tests.sh` holds its device for the whole run**, with a PID
  lock under `~/Library/Caches/OpenHikes/ui-test-locks`, and refuses a second
  run on that device (`--no-device-lock` forces past one). Pass each session
  its own `--device` (name or UDID) and `--derived-data <path>`.
- **Pass `Scripts/simulate-hike.sh` a UDID** (`OPENHIKES_SIMULATOR`).
  `simctl location` accepts a UDID or `booted` but not a name.

### The iPhone Duo

- **It needs a runtime of its own, which runs no other device:** iOS 27.1 as
  Xcode 27.1 installed it, and a build of iOS 27.2 for the Duo alone under
  Xcode 27.2. CI's Xcode 27.0 has neither, so no gate runs on a Duo, and the
  27.1 SDK's Duo APIs do not exist where CI compiles (*CI* has the gate).
  Templates and the pool pick the newest runtime that runs their device type,
  never just the newest.
- **It boots closed**, on the cover display (466 × 678 points).
  `Scripts/duo-pose.sh open --device <udid>` unfolds it to the inner display
  (669 × 951, upright) and reads the display state back.
  `--orientation landscape` leaves it 951 × 669, wide enough for the map
  screen's side panel.
- **Opening it takes hinge**
  ([artemnovichkov/hinge](https://github.com/artemnovichkov/hinge)), an
  optional Homebrew tool. Give it the pool device every time (`-d "$udid"`):
  without `-d` it folds the only booted iPhone Duo, which on a shared machine
  can be another session's.
- **XCTest sees it through the cover.** `XCUIScreen.main` is the cover display
  open or closed, and on the inner display turned sideways `app.frame` stays
  portrait while `app.windows.firstMatch.frame` turns. There `isHittable` also
  answers no for everything in the side panel, so the shared helpers measure
  the window and skip it (`OpenHikesUITests/WindowSupport.swift`).

### The iPad

- **It runs the iPhone's screens, laid out by the window.** Nothing in the app
  asks which device it is on, except whether it is a Mac (*The Mac*). A
  full-screen iPad either way up takes the map screen's side panel, and a
  window narrowed beside another app gets the sheet a phone gets (*The map
  screen*).
- **One window.** `UIApplicationSceneManifest~ipad` turns multiple scenes off,
  because each window would build its own `OpenHikesView` and run its launch
  sweeps again. `InfoPlistContractTests` pins it, with the four orientations
  App Store Connect requires.
- **It pairs with no watch** (`WCSession.isSupported()` is false), and a Wi-Fi
  model has no GPS.
- **Take one from a pool of its own:** `OPENHIKES_SIM_POOL_PREFIX='OpenHikes
  iPad' OPENHIKES_SIM_POOL_DEVICE_TYPE='iPad Pro 13-inch (M5)'
  Scripts/sim-pool.sh acquire`. No gate runs on an iPad, and `isHittable`
  answers no in its side panel as on the Duo.

### The Mac

- **An Apple silicon Mac runs the iPad app as it is.** There is no Mac target
  and no Catalyst build: Xcode's *My Mac (Designed for iPad)* destination runs
  the device build. Xcode offers that destination only to a target whose
  `SDKROOT` is `iphoneos`, so neither the app nor `OpenHikesTests` may go back
  to the multiplatform template's `auto`.
- **A symbol the Mac's libraries lack stops the launch.** dyld refuses a
  binary that names a missing symbol strongly, before any code runs ("Symbol
  not found" in the crash report), and the iOS SDK compiles such a reference
  without a word. So after adding a framework or a newer API, run the app on
  the Mac once, through the code that uses it.
  - CoreLocation's overlay on the Mac lacks `CLBackgroundActivitySession`'s
    diagnostics, so the app target links it weakly
    (`OTHER_LDFLAGS = -weak-lswiftCoreLocation`, held by
    `MacLaunchContractTests`), and the recorder reads them only where
    `isiOSAppOnMac` is false.
  - **Ask in the caller, never in the function that uses the symbol.** A
    function can look up the metadata of the types it uses as it is entered,
    so a guard at its top comes too late. `@_weakLinked import` cannot do
    this instead: the compiler wants it on every import of the module or
    none.
- **No hardened runtime.** The app target leaves `ENABLE_HARDENED_RUNTIME`
  off: a Mac's location daemon will not show the location prompt to an app
  signed with it and without macOS's location entitlement. No hosted test can
  hold this.
- **What a Mac lacks is asked about at run time**, as on an iPad: GPS, Health,
  the watch, the Live Activity, motion and the barometer. Settings shows a Mac
  only what a Mac uses (`SettingsView.fieldSections`).
- **Running it outside Xcode.** Build with `-destination 'platform=macOS,
  arch=arm64,variant=Designed for iPad'`, put the `Debug-iphoneos` app inside
  a wrapper (`X.app/Wrapper/OpenHikes.app`, with an `X.app/WrappedBundle`
  symlink to it) and `open` the wrapper.
- **No gate runs on a Mac**, only macOS 27 has been checked, and whether the
  App Store offers the app there is App Store Connect's switch, not the
  build's.

### UI automation

`Scripts/run-ui-tests.sh` runs one test (`--test`), one class
(`--suite <class> --all`) or every functional class (`--all`). `--list` and
`--help` print what is available. **A bare `--all` is the line to run** before
a change to recording, the map, the sheet or the render path; the PR template,
`CONTRIBUTING.md` and this file all ask for it.

- **A bare `--all`** spreads classes across four clones (under twenty minutes,
  against about fifty serially), then runs the `serial_tests` list on one
  simulator, and retries failures only. Anything narrower stays serial, which
  keeps CI's `--suite` runs on one device. Neither `serial_tests` nor retries
  is a place for a broken test.
- **A new `XCTestCase` must join the script's class list**, or `--all` never
  runs it; `run-script-tests.sh` fails when a class is missing. The two
  exceptions are `ScreenshotUITests`, which belongs to the screenshot scripts
  (`Screenshots/README.md`), and `testLaunchPerformance`, kept out by
  `measurement_tests`.
- **There is no sysdiagnose.** Runs pass `-collect-test-diagnostics never`,
  because Xcode 27's end-of-session `simctl diagnose` hangs for 600 seconds.
  The evidence is in the result bundle (`--result-bundle <path>`).
- **UI launches pass `--ui-testing`**, which selects an in-memory store and
  isolated `UserDefaults`. Further `DEBUG`-only `--ui-test-…` arguments seed
  data, force failures or replace a network source; each takes effect only
  alongside `--ui-testing`. `AppLaunchEnvironment` is the list, and a new
  argument goes there. Two do the reverse and reach real services, for the
  App Store frames alone: `--ui-test-live-maker` and `--ui-test-tile-server`.
- **No UI launch shows a first-run tip unless it passes `--ui-test-tips`**
  (`TipLaunch`). Only `FirstRunTipsUITests` does.
- **Reuse the shared helpers.** `OpenHikesUITests/UITestSupport.swift` has the
  fixtures, launch helpers and gestures, and `AccessibilityAuditSupport.swift`
  the audit support. A file named `Suite+Something.swift` extends `Suite`; it
  is never a second class.
- **A spoofed route must respect `RecordingFixPolicy`.** A static simulated
  location is delivered once, so a fix that gets rejected has to be set again.
  Wait on the `recording-point-count` element. For longer playback, use
  `Scripts/simulate-hike.sh`.
- **A spoofed stop has to pace.** A simulator delivers no fix inside the
  recording's distance filter and has no motion sensors, so standing still is
  silence that Auto-Pause cannot call a stop. A scenario paces between two
  spots inside the stop's area, with `--ui-test-auto-pause-seconds`
  (`RecordingUITests+AutoPause.swift`).
- **The accessibility suites.** `AccessibilityUITests` audits each screen
  without `.contrast`, `.textClipped` and `.dynamicType` (each exclusion is
  argued beside it) and filters out MapKit's own `MK` issues.
  `AccessibilityLabelUITests` asserts the labels, values and traits that an
  audit cannot judge. Widening an exclusion needs the same kind of argument.

### Writing tests

- **App tests use in-memory SwiftData fixtures** from
  `OpenHikesTests/General/TestSupport.swift`. `Fixture.hike(in:configure:)`
  inserts before it configures, because `Hike`'s device-local passthroughs do
  nothing on a row with no context. Give anything that has a clock, a
  transport, defaults or a location an injected one. A suite that touches
  tiles builds a `TileSandbox`, never `TileCache.shared`.
- **Both unit bundles are hosted by the app and serialized**
  (`parallelizable: false` in `OpenHikes.xctestplan`).
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
- **Compare floating-point values with `isApproximatelyEqual`**
  (`a.isApproximatelyEqual(to: b, absoluteTolerance: t)`, from swift-numerics'
  `RealModule`), rather than `abs(a - b) < t`. Put any optional chain on the
  `to:` side. Bounds and inequality stay written out, because
  `!isApproximatelyEqual` passes a NaN.
- **Report a missing environment capability through `SuitePrecondition`.**
  Today that means the App Group container. Strict mode turns a skip into a
  failure, and CI runs strict (`REQUIRE_ALL_SUITES` as a compilation
  condition, or `OPENHIKES_REQUIRE_ALL_SUITES=1` in the scheme).

### Lint and tools

- **`Scripts/lint.sh`** runs strict SwiftLint at the pinned version. It exits
  0 when clean, 2 on violations, and 1 when it could not lint at all.
  - The version is the SwiftLintPlugins pin in the app's `Package.resolved`,
    so Dependabot's bump of the plugin moves the CLI too. CI's install step
    then fails until the `SwiftLint.pkg` checksum beside it in `ci.yml` is
    updated for the new release.
  - Strict mode makes the *warning* thresholds fail. The ones a large change
    hits are `line_length` 120 (comments exempt), `file_length` 500,
    `type_body_length` 300, `function_body_length` 60, `closure_body_length` 40
    and `cyclomatic_complexity` 12.
  - The project's own `custom_rules`: one `@Suite` per file; American
    spelling in names and in literals outside the test bundles (color,
    center, license, meter, gray); the typographic ’ in user-visible copy;
    and `ForEach` over `x.indexed()`, never over `Array(x.enumerated())`.
    Somebody else's vocabulary, such as an OSM tag or a wire key, carries
    `swiftlint:disable:this`.
- **The Xcode build lints too**, through the SwiftLint build-tool plugin, but
  without `--strict`. Warnings never show there, but an *error* fails the
  prebuild step and with it every target, and some rules (`force_cast`,
  `force_try`, `unhandled_throwing_task`, the custom rules) error on a single
  occurrence.
- **SwiftLint walks dot-directories.** `excluded: "**/.*"` keeps a worktree or
  a scratch copy inside the checkout out of the lint.
- **Optional tools** run if installed (`brew install xcbeautify periphery
  xcode-build-server artemnovichkov/tap/hinge osmium-tool`).
  - `xcbeautify` prints nothing for output it cannot parse (crashes, hangs,
    TSan reports), so the UI scripts keep a raw log. In CI, every piped `run:`
    needs `set -o pipefail`.
  - `Scripts/periphery.sh` requires the version it pins, or newer, because an
    older Periphery ignores `.periphery.yml` and reports a clean scan. What it
    lists are candidates, not verdicts. No CI job runs it; run it after a
    feature lands. With `MemberImportVisibility` on, deleting an unused
    import is safe, because the build fails at once if it was load-bearing.
  - `xcode-build-server config -project OpenHikes.xcodeproj -scheme OpenHikes`
    writes the gitignored `buildServer.json` that `sourcekit-lsp` uses.
- **Hooks and formatting.** `Scripts/install-git-hooks.sh` installs an opt-in
  pre-push lint hook. There is no formatter.

### Releasing

- **Upload with the TestFlight workflow.** `.github/workflows/testflight.yml`
  runs on demand with the version to ship (`gh workflow run testflight.yml -f
  version=<version> -f cloudkit_promoted=true`). It archives the branch it is
  run from, uploads it and pushes its tag. Its header lists the `testflight`
  environment's secrets and how to set them.
  - It stamps the version at build time and commits nothing, because `main`
    takes no pushes. So the tags, not `project.pbxproj`, record what shipped.
  - Each version's builds start at 1. After that, the build number is one
    past the highest build tagged or committed for that version
    (`Scripts/release-version.sh`).
  - It writes the gitignored `OpenHikes/Secrets.plist` (the Stadia and
    Thunderforest keys) from its secrets, then runs
    `Scripts/check-release-secrets.sh` on that file and on the archived app's
    copy. An archive succeeds without the file, shipping paid map styles that
    draw nothing, and `ci.yml` archives without keys on purpose.
- **Promote the CloudKit schema before uploading.** An App Store Connect
  upload, TestFlight included, is signed for the production container, and a
  save there cannot add a field. Check production against the model first (see
  *CloudKit*). Nothing can check it for the workflow, so it refuses to start
  until `cloudkit_promoted` is ticked.
- **Every archived commit carries a tag**,
  `v<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>`, which the workflow pushes.
  There are no release branches, so a tag is the only way to map an Organizer
  crash report to a revision. Add a GitHub Release for App Store builds.

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
- **`OpenHikesData` is what a hike *is*.** This package holds the six
  `@Model` types (`Hike`, `HikeWalk`, `TrailPoint`, `HikeLocalState`,
  `TrailDraftRecord`, `DeletedWatchWalk`), `OpenHikesSchema`, `RouteProfile`,
  their stored value types and the framework-free logic over them.
  - It defaults to `MainActor`, like the app. An app extension on one of its
    types takes the app's isolation, so a pure static there needs
    `nonisolated`.
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
  - Its platform guards are load-bearing: the watch build compiles it, where
    `canImport(UIKit)` is true, and `swift test` compiles its macOS side.
    Guard iOS-only API there with `os(iOS)` (or
    `canImport(UIKit) && !os(watchOS)`).
- **Targets: iPhone and iPad, plus a watch companion, and nothing else.** The
  shipping targets are `OpenHikes`, `OpenWidgetExtension` (the widget, the Live
  Activity views and the Control Center toggle), `OpenHikesWatch` (watchOS 11)
  and `OpenHikesWatchWidgets`. Every iOS target builds for
  `TARGETED_DEVICE_FAMILY = "1,2"`; see *The iPad*. An Apple silicon Mac runs
  the iPad app; see *The Mac*.
  - The app embeds the watch app, so building `OpenHikes` builds the watch
    too. Breaking the watch cannot leave CI green.
  - `InfoPlistContractTests` holds the widget's device family equal to the
    app's.
- **Synchronized folders compile everything in them**, and bundle their
  resources flat.
  - `OpenWidget/` feeds both the extension and `OpenWidgetTests`, minus
    `OpenWidgetBundle.swift`, because a test bundle cannot have a second
    `@main`.
  - `OpenHikes/SimulatedLocations/` is excluded from Release builds by
    `EXCLUDED_SOURCE_FILE_NAMES`, and `OpenHikes.storekit` is in no Resources
    phase. CI's archive job asserts that neither ships.

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
  - A walk with a line is saved at Stop wherever Stop is pressed, and
    nothing waits for a review. A stretch the matcher moved, bridged or
    could not decide is saved the way that needs no answer, and the
    question is kept on the hike for *Edit Route* to ask (`RouteAssembly`,
    `RecordingAssembly.swift`).
- **Stop is where a recording ends, kept or not** (`RecordingStop.swift`).
  A recording with no line is ended without being named, and *no line* is
  the journal's answer once every pending fix has merged
  (`HikeRecorder.settledStopStep()`), never the live count's.
  - **The offered name opens selected, and its parts and their order are
    the owner's decision** (`RecordingTitle`). A field left as it opened is
    not a typed name (`RecordingStopName`), and only `RouteShape` says what
    a loop is.
  - **Every Stop asks the same first question.** The bar, the map's capsule
    and the Live Activity's link ask it through `RecordingStopQuestion`.
    Siri, Control Center and the watch stop through
    `HikeIntentCoordinator.stopRecording()`, which ends an empty recording as
    the button does. It leaves one holding
    photographs or places running, because only the screen can ask before
    they go.
- **A recording's or a walk's controls are on its own screen's bar, or on
  the map's capsule, never both** (`MapActivityCapsule`), by the owner's
  decision. Stop or End is beside Pause in each. Both Stops ask one
  `RecordingStopQuestion` and both Ends one `WalkEndQuestion`, put up with
  what the map's controls open, and how either ended reaches the sheet's
  path as an `ActivityEnding`. The capsule stands at the foot of the leading
  column, where the record button stood, and the pills stand on it.
- **The map is imperative MapKit behind `MapView`.** `MapView.Coordinator`
  observes stable controllers and updates `MKMapView` directly. Tiles flow
  through `CachingTileOverlayRenderer` into `TileCache`, auto-saves through
  `AutoSaveTileStore`, and bulk downloads through `OfflineTileDownloader`.
- **Every hike in the library is on the map** (`LibraryLines`), faded beneath
  the selected route. A line is read once, off the main actor, and read again
  only when its row is saved, never by observing `route`. One overlay and one
  renderer draw them all (`LibraryLinesRenderer`), so hikes over the same
  trail do not stack into a solid line.
- **A drawn trail is an ordinary `Hike`.** `TrailDraftSave` writes the same row
  a GPX import does and nothing more: no stops, no chosen ways and no travel
  mode, by the owner's decision. The library is lines with walks on them, so a
  saved trail is edited in *Edit Route* like every other line, and the maker
  only ever makes a new one. `Hike.drawnRouteData` stays only for 1.6
  installs, which the owner keeps working: its shared-copy marker is read,
  and an *Edit Route* save clears it. A line another writer replaced since
  the last edit is edited afresh, never rebuilt from that edit's history
  (`RouteEdit.lineRevision`). The draft, `TrailDraft`, persists as a
  `TrailDraftRecord` in the **unmirrored** store, because a half-drawn line is
  one device's work. The maker routes legs one at a time through one worker,
  since nineteen parallel Overpass requests earn a `429`, and nothing on that
  path may block drawing.
- **A line somebody walked is never changed without saying so**
  (`RouteTrim`, `RouteStep`, `RouteEditSave`). *Edit Route* keeps every point
  it does not touch as it was saved. A stretch drawn where nobody recorded
  the hiker is `RouteProvenance.inferred` and carries no times, and a line
  turned round or begun elsewhere loses its clock rather than run it
  backwards. The line it had goes to `Hike.originalRoute`, written by the
  first edit and by no later one, which is what *Revert to Original* puts
  back.
  - **The hike's line is derived, never patched**: the line as it was saved,
    put together under the answers that stand
    (`RouteAssembly.line(saved:raw:)`), then each step in the order it was
    made (`RouteSteps`), then cut (`RouteEdit.trim`). A section names its
    points in the saved line and in `Hike.rawRoute` by index, and a step its
    place in metres along the line the step before it left. So no edit trims
    or rewrites the saved line or the trace, and an answer stands while a
    step is made on the line it drew.
- **Places** (`Hikes/Places/`): `TrailPlace` is the value and `TrailPoint` the
  mirrored row. The owner's rule: a place from OpenStreetMap takes photographs
  and nothing else, and a place the hiker made can also be renamed, re-kinded
  and annotated. A place's photographs belong to the hike
  (`HikePhoto.placeID`), and go back to the gallery when the place is removed.
- **A map claim goes to the deepest screen, not to the newest**
  (`ScreenClaims`). Pushing a third screen makes the screen two levels down
  appear again *after* the new one has claimed, so "last to appear" would hand
  the map to the wrong screen.
- **Following a trail is a walk, and the walk outlives the screen.**
  `TrailWalkSession` is the only place a walk starts. One walk runs at a time,
  and it pins `BackgroundTrailTracker`.
  - The walk in progress is device-local, on `HikeLocalState`, written at
    milestones and never per fix.
  - A walk is bound to its line. It ends when its route is edited
    (`routeRevision`), and its stretches, climb and photo matches are read
    only along the same revision.
  - A saved recording writes its own walk. Its active time is
    `PreparedRecording.recordedSeconds`, the gaps between saved points, and
    never wall clock minus the pause list, which is incomplete. The watch
    measures the same way (`WatchWalkAccumulator`).
  - Off the trail, the hiker is asked whether to keep following or to record
    instead (`OffTrailQuestion`, `OffTrailWatch`). Recording instead begins
    with what the walk covered (`RecordingSeed`).
  - Junction warnings (`JunctionGuide`) are spoken only while a walk is
    *following*, and are off until the hiker turns them on from a button on
    the map, by the owner's decision: never in Settings. `JunctionAnnouncer`
    in `OpenHikesShared` decides when each is said, for the phone and the
    watch alike, and the watch taps where the phone speaks.
- **A recording always outranks a followed trail**, on every surface, because
  it is the one that would be *lost*: a follow is re-derived from the trail and
  the next fix, and a recording is not. Four places hold the rule and must
  agree: `TrailWidgetEntry.init`, `HikeLiveActivityController.accepts(_:)`,
  `HikeRecordingControlState.init(snapshot:)` and the map's capsule,
  `MapActivityCapsule.activity(recordingLive:recordingOnTop:walkedHikeID:hikeOnTop:)`.
- **App Intents perform through `HikeIntentCoordinator`.** The system can launch
  the process just to run an intent, so no view state is reachable.
  `OpenHikesApp.init()` registers the coordinator, and each intent makes one
  call into it.
  - The recorder stays the single authority. The coordinator holds no state,
    settles recovery before it reads the phase, and reads the phase back
    afterwards, because refusals arrive as `.failed`, not as a throw.
  - Suites reach the intents through `HikeIntentContext.$override`.
  - `AppShortcutsProvider` silently drops shortcuts past ten.
- **The Control Center toggle and the Live Activity buttons live in
  `OpenHikesShared`.** Each extension that draws one must compile its action,
  while the app performs it through the same coordinator. The Live Activity
  offers Pause or Resume as intents, and Stop only as a link that opens the
  app with Stop's question up, by the owner's decision: a Lock Screen button
  can ask nothing (`HikeActivityControlIntents.swift`).
- **One controller makes the reminder decisions.**
  `MovementReminderController` is handed to both the recorder and the walk
  session, so it can see both. The thresholds live only in
  `MovementReminderPolicy`.
- **A recording pauses itself at a stop, and resumes as the next segment**
  (`AutoPauseWatch` in `OpenHikesShared` decides; `HikeRecorder+AutoPause.swift`
  acts). The switch is *Auto-Pause*, on unless the hiker turns it off.
  - The journal is cut back to the fix the stop began at
    (`TrackJournal.pause(at:discardingPointsAfter:)`), so an auto-pause reads
    as a pause by hand at that moment would, on every surface: the same
    `RouteBoundary`, no record of a new kind and no new journal version.
  - The thresholds (`AutoPausePolicy`) are a first guess. A `DEBUG` build
    writes down every fix and change of motion (`AutoPauseEvidenceFile`), and
    `AutoPauseEvidence.replay(_:policy:)` runs a policy over what was
    written. Change one from recorded stops, and give `AutoPauseWatchTests`
    the stream that argued for it.
  - The watch's own recordings take the same rule (`WatchAutoPause`), on
    position alone, by the phone's switch.
- **A segment is a walked run** (`RouteSegments`). A hike's segments are
  read off the pauses its route already has, so a pause by hand, an
  auto-pause and a GPX file's `<trkseg>` breaks all cut one, and nothing is
  stored for it.

### First-run tips

- **TipKit, in two ordered queues and one tip of its own** (`AppTips`). A
  screen never shows two at once, and a tip goes for good once it is closed
  or its control is used. The two about making a hike are for a new hiker
  (`CreationTipsAudience`).
- **Every tip is inline, never a popover.** A popover over the map would be
  presented by the permanent sheet, and while it was up the sheet could
  present nothing else (see *Present modals from inside the sheet's
  contents*). And a `.popoverTip` on a toolbar button never presented at all,
  measured on iOS 27. The map's tips are cards beside their controls
  (`MapTipCards.swift`).
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
- **The widget reads location, deliberately.** While a recording
  `isCapturingFixes`, `WidgetRecordingLocationSampler` appends sparse anchors
  to `pending-fixes.json`: at most one per 15 minutes, claimed with an App
  Group lock file. The recorder merges and deduplicates them on its next
  drain. The widget's half is append-only: it never reads the queue back,
  matches a route or computes a statistic.
- **Basemaps are kept per trail**, so a pinned widget keeps its map whatever is
  selected. When WidgetKit cannot say what is pinned, nothing is pruned. A pin
  whose hike the store no longer holds loses its snapshot and map at the
  launch sweep; a read that failed is not a missing row, and keeps them.
- **The Live Activity is split along the same seam.**
  - `OpenHikesShared/LiveActivity/` owns the payload (`HikeActivityAttributes`)
    and numeric projections and rounding. `OpenWidget/` owns the wording
    (`HikeActivityPresentation`) and draws it, so its build extracts the words
    into the widget’s String Catalog. `OpenHikes/LiveActivity/` decides when
    one exists.
  - It renders `context.state` only, and its clock ticks by itself through
    `Text(timerInterval:)`.
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
  - `HikeLocalState`, `TrailDraftRecord` and `DeletedWatchWalk` live in an
    unmirrored configuration. They hold everything about *this* device: tile
    claims, offline downloads, the walk in progress, recording ownership, a
    drawing in progress, an unfinished community upload and the watch walks
    whose hikes were deleted here.
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
- **A saved hike's line is read off the main actor.** Reading `route` decodes
  it whole, and under the list's `@Query` the next read after any save decodes
  it again. A screen about a hike reads `ShownLine`, which
  `HikeDetailInteraction` keeps for all of them. A reader with no screen hands
  on a line it read anyway, or makes a `SelectedLine` for one read. A read
  that fails is not a missing row: the readers keep the line they hold, and it
  stays owed until a refresh reads it (`SelectedLine.Found`). A recording's
  screens read the column, because a draft has no line until Stop.
- **`CloudSyncCoordinator` only reports and toggles; SwiftData owns sync.** That
  gives up four things, deliberately:
  - photo pixels on other devices (see *Settled decisions*)
  - small updates (a rename re-uploads the whole row)
  - hiding unfinished work (a recording's draft is an ordinary row, so
    another device shows it as a hike with no line; the route stays in the
    device-local `TrackJournal` until Stop writes it)
  - any preference for unsent local edits

  The Simulator gets no CloudKit pushes, so two simulators cannot test sync.
- **Draft cleanup requires positive ownership.** `Hike.isRecording` is
  mirrored; `TrackJournal` is not. Only `HikeLocalState.ownsRecordingDraft` lets
  the orphan sweep touch a draft, and an absent journal proves nothing.
- **Files outside SwiftData need an owner and a sweep.** Photo and tile
  deletion is fire-and-forget, so at launch `TileCache.trimCache(claimedBy:)`
  and `HikePhotoStore.reclaimOrphans(claimedBy:)` sweep from a *complete* claim
  set. A failed fetch sweeps nothing. A downloaded country's owner is an index
  of its own (*The offline countries*).
- **Persisted identifiers are stable:**
  - provider IDs, `SettingsKey` strings, the container and App Group IDs, the
    widget kind, the tile-key shape and the deep-link format
  - `MovementReminderKind` raw values (they double as notification categories)
  - the Live Activity attributes type name
  - the first-run tips' ids (`FirstRunTipsTests`) and the name of
    `AppTips.isNewHiker`, the TipKit parameter that keeps a new hiker
  - the record names of the four sets of squares, which every installed
    build asks for (`TrailCellGridTests`, `RouteSquareGridTests`,
    `PlaceSquareGridTests`, `TrailGraphSquareGridTests`)
  - the background session the areas download in
    (`BackgroundCountryDownloader.sessionIdentifier`), and
    `countries/manifest.json` with the names of the files it lists and the
    area codes they start with (*The offline countries*)
  - the tile server's own `manifest.json`, its fields, and the 410 it gives
    for an archive it does not have (*Tiles*)
  - each set of squares' list in the tile server's manifest, its archives'
    names, and where a square is in one, its zoom included (`SquareArchive`,
    `SquareArchiveTests`, *The trail squares*)

## Conventions

### Deployment floor

- **The floor is iOS 18.4 and watchOS 11.0.** The packages declare the same
  generation (macOS 15.4, visionOS 2.4), so that `swift test` refuses what the
  iOS build refuses. Below 18 the app would lose `Mutex` and the Control
  Center control. 18.4 is `DispatchQueue` as a `TaskExecutor` (`TileCache`,
  `TrailBasemapRenderer`), and every iPhone and iPad that runs 18 can update
  to it.
- **A newer API is reached through one wrapper, with its fallback beside
  it.** A screen asks for a shape or a behavior, never for a release. The
  `if #available` lives in `RoleButton` (the role-only close, cancel and
  confirm buttons), `LiquidGlass.swift`, `GlassButtonStyle.swift` and
  `MapGlass` (glass), `observedValues(_:)` (`Observations`),
  `LifecycleObservation`, `ReverseGeocode` and the `MKMapItem` readers beside
  it (`CLGeocoder` below 26), `askToContinueInForeground(_:)`,
  `trailStopsReorderable(_:move:)` (`reorderable()` on 27, `onMove` below) and
  `sectionIndexLetter(_:isShown:)`.
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
- **The compile at 18.4 is the only gate on the floor.** CI's image has no
  iOS 18 runtime, and nothing runs the suites there. A problem that exists
  only on iOS 18 is fixed when it is a crash. `Scripts/sim-pool.sh`'s header
  says how to pin a pool of its own to an older runtime.

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
  - A handler a framework calls on its own queue is written `@Sendable`. In
    a main-actor body it is otherwise main-actor isolated, and where the
    framework's type says nothing about isolation (`WCSession.sendMessage`)
    Swift checks that at run time and traps (`WatchSessionCoordinator`).
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
  and Swift 6.3 rejects nested types in one. Every `CloudKitCommunityTransport`
  extension says `nonisolated`.
- **Blocking work stays off the main thread:** tile math, image encoding and
  disk enumeration. Hot paths call `assertOffMainThread`. Shared off-main types
  are `Sendable`, and singleton state sits behind the existing `Mutex` pattern.

### The map screen

- **Present modals from inside the sheet's contents.** `MapSheet` is presented
  permanently in portrait. A `.sheet`, cover, picker, importer or alert attached
  beside it never presents, and an alert can even take the sheet down. Every map
  alert lives in `MapScreenAlerts`, and `MapScreenAlertUITests` checks them,
  except those attached beside them on the same contents: the trail maker's
  missed-photo alert, which carries an object rather than a binding, and the
  refused location button's, a walk's off-trail question and the Stop and
  End questions, which go with the map controls' (below).
- **What a map control opens goes through `MapControlModals`.** A place card
  leaves the map live behind it, and the map sheet is already presenting the
  card. A sheet asked for from under it waits until the card is closed; an
  alert comes up at once and takes the card down. So the card presents those
  modals over itself while it is up (`presentsMapControlsOverCard()`), and
  anything new a map control opens joins them there.
- **What follows an alert is an alert.** A `confirmationDialog` raised from
  an alert's button is never presented, so the question the recording's stop
  alert leads to is a second alert (`RecordingCard`). And an alert's text
  field ignores a `selection:` binding: one that opens holding text to type
  over is asked to select it (`AlertTextSelection`).
- **The map is chosen on the map.** *Map Modes* (`MapModesView`) is the only
  place the map and *Hiking Routes* are chosen. Settings keeps only a
  subscriber's subscription row.
- **The primary surface has two shapes: a sheet in a narrow window, a panel
  beside the map in a wide or a short one.**
  `SheetLayout(windowSize:isCompactHeight:)` is the rule, and
  `verticalSizeClass` and the window's size are read only in
  `SheetLayoutReader`.
  - At a compact height a sheet left to adapt is presented full-screen, its
    detents ignored, so `MapSidePanel` draws the same `MapSheet` beside the
    map. A window of regular height with room for a map beside the panel (an
    unfolded iPhone Duo in landscape, an iPad either way up) takes the panel
    too.
  - A screen pushed into the sheet marks the scroll view it is built around
    with `fitsSidePanel()` (`SidePanelFit`). Each figure a screen reports is
    one that does not move when the panel does, because a measure that
    follows the panel is chased by it.
  - A window can change size and keep the panel. `MapView.update` does not
    run then, so what the map measures from its own height hears of it from
    UIKit (`MapLayoutObserver`).
  - `SheetPresentation` keeps each pushed screen's state objects until the
    route pops, so rotation keeps them. A pop builds the screen it is taking
    away once more, so a new destination's object goes in a `SheetRetained`.
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
  prefetching. OpenStreetMap's tiles are never bulk-downloaded: the
  OpenHikes map is kept by country (*The offline countries*), and the
  openstreetmap.org card by auto-save alone. The hiking routes are a
  `TileLayer` the app draws itself (*The hiking-routes layer*), and stay out
  of `TileProvider.all`.
- **Auto-save is one switch, off until the hiker turns it on**, by the
  owner's decision (`SettingsKey.autoSaveTilesEnabled`, `AutoSaveController`).
  It is for the maps with no download of their own: a tile a downloaded
  country draws is never kept.
- **A tile is identified by provider plus z/x/y**, never by scale
  (`TileCacheKey`).
- **Never turn a render miss into synchronous disk or network work**, and never
  measure storage in a body. Delete durable tiles through `TileOwnership`.
- **OpenStreetMap is drawn from our own vector tiles, with the OSMF's raster
  tiles behind them** (#1481). The style's `vectorSource` names a PMTiles
  archive on `tiles.openhikes.app`. `VectorTileClient` fetches each tile and
  `VectorTileRasterizer` draws it. The cache then files the picture as any
  tile, under the raster style's id and keys, so saved coverage keeps
  answering.
- **A drawn tile's key names neither its archives nor its language.**
  `VectorTileArchives` keeps both, and since when, and every drawing, the
  server's and a country's, takes its language from there, so a copy drawn
  before either changed is drawn again.
- **The look is OpenStreetMap Carto's**, and each rule is argued in the file
  that draws it, under `OpenHikes/Tiles/Vector/`. Points, icons and patterns
  are read out of Carto's style, never written by hand
  (`Scripts/carto-points.sh`). The archive's landcover is ESA WorldCover's,
  under CC BY 4.0, so the style credits it beside OpenStreetMap.
- **The extras fill in what the basemap leaves out**
  (`VectorTileSource.Extras`): a second archive that
  `Scripts/vector-extras.sh` builds from the planet, with its layers named as
  the basemap's are, so a tile of each merges into one. They add to the map
  and are never its reason to fall back. A tile drawn without extras it
  failed to get is provisional (`VectorTileClient.Drawing.provisional`): held
  in memory alone and drawn again, never filed for a week.
- **A tile is drawn so that the tile beside it agrees.** A name never crosses
  its tile's edge, because the neighbor could not finish it. Whatever repeats
  (a name along a line, a road number, a pattern) stands on marks worked out
  from the whole line or the whole world, never from the tile. Every tile
  ranks names the same way (`VectorTileLabelStyle.Category`).
- **Fallback.** Wherever the server cannot answer, the tile comes from
  `tile.openstreetmap.org` as before. A failure of the device's own
  connection falls back to nothing: the load fails and is tried again, rather
  than filing a raster tile among the drawn ones for a week. So does a server
  failing over a saved tile, whose copy stays the tile
  (`VectorTileClient.Drawing.unavailable`).
- **openstreetmap.org stands beside it while the style is new.**
  `TileProvider.openStreetMapRaster` (`osm_raster`), the fourth card on
  *Map Modes*, draws the OSMF's raster tiles alone, so the two can be
  compared. It goes once the transition is over, and a choice stored for it
  then reads as the default.
- **No suite reaches the tile server.** `TileCache.shared` has no vector
  source under `isRunningTests`, UI tests included
  (`VectorTileArchives.forThisLaunch()`), except a launch that passes
  `--ui-test-tile-server`, which only the App Store frames do. The squares
  have no server then at all (*The trail squares*).
- **A new build gets a new archive name**, carrying its date, and the
  extras the hour too: the server's cache holds a tile for a day, so a build
  overwritten in place would mix two builds on screen.
- **The server's manifest names the archives the app draws from**
  (`VectorTileArchiveManifest`): `manifest.json` at the server's root, a copy
  of the bundled `VectorTileArchiveManifest.json`. A build draws the first
  basemap of the schema it reads and the first extras of a generation it
  reads, so extras an installed app would draw wrong go up as the next
  generation, and the last of the old one stays listed. The app reads the
  manifest again when it comes to the front and when an archive answers 410,
  so it moves without a release (`VectorTileArchives`). It names each set of
  squares' archives too, under a list a set (*The trail squares*).
- **Refreshing the server is a run of commands, each safe to run again.**
  Each script's header has its options.
  1. `Scripts/trail-cells.sh update-planet <planet.osm.pbf>`, then
     `Scripts/vector-extras.sh build <planet.osm.pbf>` and `upload`, and the
     four sets of squares (*The trail squares*).
  2. `Scripts/vector-archives.sh basemap` copies Protomaps' newest daily
     build of the schema the app reads into the bucket.
  3. `Scripts/vector-archives.sh use` with each new name, then `publish`, and
     commit the manifest.
  4. `Scripts/offline-countries.sh publish` cuts every area again from the
     new archives and puts it up.
  5. `prune` in `Scripts/vector-archives.sh` and
     `Scripts/offline-countries.sh`, once the apps have read the new
     manifests. An archive leaves the manifest before it leaves the bucket.
     `Scripts/trail-cells.sh prune` is no part of a refresh: it takes the
     public database's copies from 1.5–1.7 (*The trail squares*).
- **The server is not in this repository.** It is a Worker and an R2 bucket.

### The offline countries

Any country can be downloaded for the OpenHikes map (#1482), or, for the few
too big for one download, any of their states or provinces, from *Offline
Maps*. `OfflineCountries` is the one owner, on the main actor.

- **An area is a country, or a region of one too big for one download.**
  Every country Natural Earth's outlines name is cut whole, except those
  `Scripts/lib/offline-countries.json` splits (the United States, Canada and
  Russia), which are cut by state or province and are never themselves
  downloadable. An area is keyed by its ISO 3166 code, and a region goes into
  the country its code names, where Natural Earth draws otherwise.
- **Zoom 14 always, zoom 15 with *Extra Detail*.** An area's map is four
  files: the basemap and the extras to zoom 14, which every download takes,
  and both at zoom 15, which the switch adds
  (`SettingsKey.offlineCountriesDetail`, on by default).
- **An area carries its day hikes** (`OfflineCountryManifest.Role.trails`),
  a fifth file every download takes: the trails archive's squares within a
  wide margin of the outline (`Scripts/lib/offline-countries/Trails.swift`),
  so the Community tab searches there with no signal.
  - Copied out of the world's archive, never rebuilt from an extract, and
    every square it covers is a tile of it, an empty one included. A square
    it has no tile for is one it says nothing about, so a search reads the
    downloads square by square before its cache and the server
    (`DownloadedTrailCells`, `TrailCellLibrary`).
  - A file a build gains after it is up goes up beside it under the same
    build (`Scripts/offline-countries.sh trails`, then `upload`), and an area
    already down brings it at the next read of the list
    (`OfflineCountries.reconcile()`), never as an update.
- **Cut on the server, read in place.** `Scripts/offline-countries.sh` cuts
  each area out of the archives the map draws; its header is the procedure.
  A build is named for the later of its archives' days. Its files go under
  `countries/`, never over a file of the same name, and the manifest that
  promises them is written last (`OfflineCountryManifest`). The app keeps each
  file as it arrived and reads tiles out of it (`PMTilesArchive`).
- **The tool compiles the app's format files as they stand**
  (`PMTilesFile.swift`, `PMTilesArchive.swift`, `OfflineCountryManifest.swift`
  and `PackedBytes.swift`), which import nothing of the app's.
  `Scripts/run-script-tests.sh` builds it and runs its `selftest`.
- **An area is drawn before the network is asked.** `TileCache` asks the
  downloaded areas (`OfflineCountryArchives`) ahead of the network policy and
  the tile server, and files the picture in the cache as any tile.
- **A download is `.speculative`** (`TileNetworkPolicy`), in a background
  `URLSession`, and nothing on its path checks an entitlement. Trying again
  goes by what the server offers now (`OfflineCountries.retry`), because the
  server deletes a build it has moved past.
- **Checked before it is used.** Each file is staged and moved into place
  only once its size and SHA-256 match the manifest's
  (`OfflineCountryStore.isWhole`).
- **Owned by an index, not a row.** The tile cache reads the list from
  MapKit's drawing threads, where a main-actor model cannot be read. So
  `OfflineCountryStore` keeps a JSON index beside the archives under
  Application Support, out of the backup. The launch sweep deletes every
  archive the index does not hold, and never a file the index on disk names.
- **A file the index names stays its owner's even when it will not open.**
  The map's opening judges it, never the index: an area keeps every file
  that opened, offers the rest again (`OfflineCountries.unopenable`), and
  counts as drawn only if its basemap opened (`isDrawn`). Filtering the index
  instead would let the sweep delete checked files over a read the device
  refused for the moment.
- **An index that cannot be read is not an empty one.** Before the device's
  first unlock, a launch the system makes can list and delete files and read
  none. So a launch that cannot read the index, or the list of downloads
  under way, opens, resumes and sweeps nothing (`OfflineCountryStore.List`).
  A change to `OfflineCountryStore.Record`, or to the manifest's `Country`
  inside it, has to keep reading the index an installed build wrote, or that
  build's downloads are lost to their owner.
- **A name off the network never reaches a path.** The manifest's file names
  are held to the shape the server's route serves
  (`OfflineCountryManifest.File.hasSafeName`), and an area listing one that
  is not is left off whole.
- **The list is read to leave the server room to move**
  (`OfflineCountryManifest.catalog(from:)`): a file of a role a build does
  not know, and an area it would draw wrong, are left out. The index on the
  device and the cutting tool refuse such a file instead, because one left
  out of what owns it would be swept.
- **No suite reaches the server or the session.**
  `OfflineCountries.forThisLaunch()` has neither under `isRunningTests`. The
  one way past the server is
  `--ui-test-offline-countries=<seeded|showcase|refused>`
  (`SeededOfflineCountryServer`), and still no session, so nothing downloads.
- **Deployment state, checked 2026-11-23.** The bucket holds every area of
  build `20261122`, cut from `planet-20261118` and `extras-20261122-00`, with
  its day hikes from `trails-20261122-00` 50 km round it: 381 of them (234
  countries, and the 51 states, 13 provinces and 83 regions of the three
  split ones), 1,905 files and 180.8 GB, of which the day hikes are 279 MB,
  and no other country file. Beside them it holds those two archives, the
  four sets of squares (*The trail squares*), and the manifest at revision
  11, which names all six, and nothing else. The squares are `routing-20261122-00`,
  `trails-20261122-00`, `routes-20261122-00` and `places-20261122-00`, each
  the planet of 2026-11-22 00:00 UTC.

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

- **`OpenHikes/PrivacyInfo.xcprivacy` ships with the app.** It declares five
  required-reason codes (`CA92.1`, `C617.1`, `3B52.1`, `35F9.1`, `E174.1`) and
  five collected types, all linked to the user and none used for tracking:
  precise location, photos, other user content, user ID and fitness.
  Publishing a hike sends all five. A new required-reason API adds its code
  in the same change, and `PrivacyManifestTests` pins the collected set both
  ways.
- **Background location is described in three places, and they must agree:**
  the `Info.plist` purpose strings, the Background Trail Tracking footer, and
  App Review's notes in App Store Connect. Always access is for the widget and
  the Live Activity; the `location` background mode is for the recorder and
  for a walk with junction warnings on, and the `audio` mode is for those
  warnings alone (`JunctionVoice`). Their translations must agree too.
- **Strings live in String Catalogs, in English, German, French, Spanish,
  Italian, Russian, Polish, Ukrainian and Romanian.** English is the
  development language.
  - `xcodebuild` does not merge extracted strings the way the IDE does. After
    changing text, build, then run
    `Scripts/sync-string-catalogs.sh <derived-data>`. CI's `--check` exits 2
    when a catalog is behind.
  - `Scripts/check-string-extraction.sh` audits the source for copy that
    bypasses extraction. Intentional machine text and prescribed credits are
    listed with reasons in `Scripts/string-extraction-exclusions.json`; stale
    entries fail the gate.
  - **Every string gets all eight translations in the same change**, each
    with `"state" : "translated"`. `StringCatalogTests+Translations.swift`
    fails on a key missing one, on a translation that drops or retypes a
    placeholder, and on a plural without a form its language needs. The
    catalog is the style guide: a new translation takes its form of address,
    its words for the app's things and its punctuation from the entries
    already there.
  - **Copy is a simple explanation.** A footer, alert or empty state says what
    a control does, or what happened and what to do next, in a sentence or
    two. The reasoning and the edge cases go in the code's comments, or on
    the support page when a hiker needs them. `StringCatalogTests` holds
    every English value under a length ceiling.
  - A count is a plural variation, never `if count == 1`. Figures are
    formatted per locale and never catalogued.
  - **One English word that a translation splits takes a second key**:
    `String(localized: "<area>.<meaning>", defaultValue: "…")` with the same
    English, as `recording.start` does for the record button.
  - **A sentence never changes the case of a catalogued word**, because German
    capitalizes every noun. A sentence that names something is passed whole.
  - Shared App Intent metadata and `RoleButton` defaults stay in their
    package declarations, and the sync script extracts them into all four
    catalogs. An IDE build never sees them, so their entries are marked
    `"extractionState" : "manual"` wherever the target does not use the same
    words itself.
  - **Two catalogs have no sync:** the permission prompts in
    `InfoPlist.xcstrings` (the app's and the watch's) and the Siri phrases in
    `OpenHikes/AppShortcuts.xcstrings`. The IDE extracts into both and
    `xcodebuild` into neither, so an edited purpose string or phrase means
    editing its catalog in every language by hand.
  - A new language joins `StringCatalogTests.translations`, `knownRegions` in
    the project, `MapPurchaseLinks.PageLanguage` with its pages under `docs/`,
    and the archive job's `.lproj` list in `ci.yml`.
  - **The privacy policy, the terms and the support page are published in
    every language**, the translations under `docs/<language>/`. An edit to
    an English page edits its eight copies in the same change, and the legal
    pages move their `<time datetime>` together, which
    `Scripts/check-legal-pages.sh` holds them to. No script holds the support
    pages together.
  - The hosted tests and the UI suites assert English copy, so they assume a
    simulator whose language is English, as CI's is.
- **OpenHikes Pro is one monthly subscription.**
  - **`MapEntitlementStore.productID` (`…pro.maps.monthly`) never changes.**
    It is recorded against every purchase.
  - **`MapPaywallView` lists everything Pro unlocks and unlocks everything it
    lists**, because App Review checks both directions. Today that is the paid
    map styles (Stadia Outdoors, Stamen Terrain, Thunderforest Outdoors), offline
    Stadia maps, and Stadia elevation where a trail has none. A change updates
    the paywall, `OpenHikes.storekit`, `docs/terms/` and `docs/support/` in
    every language, the home page in `docs/`, the README and App Store Connect
    together.
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
  (`Reminders/MovementReminderController.swift`). With reminders off, or
  before the first fix, GPS stops. Otherwise the app uses the cheapest
  delivery that still notices a departure: significant-change monitoring with
  Always access, or a 100-meter feed with When In Use.
- **An auto-pause keeps its feed** (`HikeRecorder+AutoPause.swift`), because
  the first fixes of the walk away are the next segment's. Spending less on a
  long stop needs a device measurement first.
- **Junction warnings spend what a recording spends, and only when asked**
  (`Hikes/Walks/Junctions/JunctionLocationFeed.swift`): a feed of its own,
  only with the switch on and a walk following a line that has junctions.
- **The screen stays awake only on a claim, and only if asked**
  (`General/ScreenWake.swift`). `SettingsKey.keepScreenAwake` is off by default.
  `ScreenWakeCoordinator` counts claims and is the only writer of
  `isIdleTimerDisabled`.
- **A backgrounded recording draws nothing and ticks nothing.**
  `MapView.Coordinator` defers overlay work until the app returns, driven by
  `UIApplication` notifications rather than SwiftUI. The 1 Hz `TimelineView`
  exists only while the scene is `.active`. The location background mode keeps
  the app running, so iOS will not stop those timers for you.
- **Terrain goes under the tiles only while the map is tilted**
  (`Map/MapCoordinator+TerrainUnderTiles.swift`). MapKit keeps fetching the
  map a replacing tile overlay hides, so terrain under the tiles costs Apple's
  satellite imagery on every view.

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
  (`OverpassTrailGraphProvider.cacheFormat`), and a region in another format
  reads as expired.
- **Revisit this policy only when installs must survive upgrades.** Then
  freeze the actual model and every encoded type, write a real migration
  plan, and test previous-version stores from disk. Never put a new version
  number on today's model.

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
- **Deployment state, checked 2026-11-21.** Development and production both
  export `md5 74a5b5d91372f08c92c3af7402df7892`. Both have the two
  trail-square record types, `CuratedTrailCell` and `CuratedTrailManifest`,
  neither with an index. Both hold the same build of all four sets of
  squares, from OpenStreetMap as of 2026-11-17 23:00 UTC, each marked as the
  whole world under its own manifest (checked 2026-11-18): `trails1_manifest`,
  `routes1_manifest`, `places1_manifest` and `graph1_manifest`. Builds
  v1.5-1 to v1.7-1 read them, and nothing later does (*The trail squares*).
  Both have a
  column for every attribute in `MirroredCloudKitSchema.recordTypes`. The
  only live columns the contract does not name are SwiftData's own
  `CD_entityName`, the to-one reference columns that the contract lists as
  relationships, and the `CD_route_ckAsset`, `CD_rawRoute_ckAsset` and
  `CD_originalRoute_ckAsset` asset fields of the three external-storage
  attributes. Re-export before believing these numbers, and update this
  paragraph when they move. Deployment facts live here, not in code.

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
| `CuratedTrailCell` (OpenStreetMap's day hikes, the hiking-routes layer, the places and the trail graph, by map square) | `reviewer` / `reviewer` | **none** |
| `CuratedTrailManifest` (what the squares cover) | `reviewer` / `reviewer` | **none** |

- **A submission is write-once.** A listing points at its submission, so an
  author who could write would be able to swap an approved route. Amending a
  route means a removal request plus a fresh share, and a takedown is a
  reviewer's delete. A reviewer may correct only the title (on the listing)
  and which photographs go (`keepOnlyPhotos`, before the listing exists).
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
- **The last two types hold nothing a hiker made.** They are a copy of
  OpenStreetMap's routes, places and trails that a script uploads, which
  builds v1.5-1 to v1.7-1 read and later builds read from the tile server
  instead; see *The trail squares*.

### Rules that hold it up

- **A suite must never reach the real transport.** There is no sandbox for a
  public database. Under `isRunningTests` (UI tests included),
  `OpenHikesModel.makeCommunityTransport()` returns `nil`, which removes the
  share button and the list. The only way past that is
  `--ui-test-community=<scenario>`, which selects the `DEBUG`-only
  `SeededCommunityTransport`.
- **The feature is free**, including publishing and photo contributions.
  Nothing on the publish path checks an entitlement. Do not add one back
  without the decision being made again in the open; only the schema decides
  what reaches other people.
- **The server decides who reviews.** No role is stored. `reviewQueue()`
  reports a refusal as `.notPermitted`, not as an empty list, and
  `CommunityReviewQueue.isReviewer` only hints at what to draw.
- **Publication has three derived states.** `CommunityPublicationState` derives
  `notShared`, `awaitingReview` or `published` from two columns on `Hike`. A
  decline leaves no record, so the UI never says *rejected*. Un-publishing
  happens only through an explicit *Check Whether It's Still Live*, and
  `forgetPublication` clears both columns only after the listing is confirmed
  gone, because queries are eventually consistent.
- **Reporting is an email; blocking is device-local.** Both follow from
  account-free browsing. `CommunityBlockList` keeps blocks in unsynced
  `UserDefaults`, keyed on `CommunityHike.authorID` (the CloudKit creator,
  which the app copies at publication), never on a typed name. A listing
  without an `authorID` is dropped, and blocked authors are excluded before a
  page's `limit` is spent (`CommunityPageBudget`). Report and Block sit on
  the content's screen, never on a row.
- **A submission and its review notice are two saves, and a failed notice must
  not lose the upload** (`CommunityUploadQueueing`).
  - *Finish Sending* saves the notice and nothing else; it never re-uploads.
    The notice is named `notice-<submissionID>`, so a retry saves the same
    record.
  - `.serverRecordChanged` reads as *already queued*. A permission failure is
    never read as success.
  - Two server answers are assumed and not yet observed: `.serverRecordChanged`
    for a re-save without a change tag, and `.referenceViolation` for a notice
    about a deleted submission. Check both against the development container
    before a promote, never from a test (`CommunityRecordWriting` is the seam
    the suites script).
- **Photos can be added to an already-listed trail** as a second pair of record
  types, not as an edit. Contributions load when a hike opens, never for a
  list.
- **What is sent is stated, and the statements move together.**
  `CommunityShareDisclosureTests` holds the share footer to the payload. The
  privacy manifest, `docs/privacy/` and `docs/terms/`, with their translated
  copies, change whenever what is sent changes, what a reviewer may do
  changes, the removal, *Check Whether It's Still Live*, reset or *Finish
  Sending* flows change, what the Commons requests ask for or keep changes,
  or `CommunityPublisher.maximumPhotos` (36) changes. App Store Connect's own
  privacy answers are separate, and the manifest does not update them.

### OpenStreetMap and Wikimedia Commons

- **Two sources feed the list.** `MergedCommunityTransport` combines CloudKit
  with `CuratedTrailSourcing`: OpenStreetMap's `route=hiking` relations, read
  from the pre-built squares where they have an answer and from Overpass where
  they do not (*The trail squares*).
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
  `CommunityQueryPolicy` turns a pan into an *offer*, never a request, and
  nothing is fetched until the *Community* tab opens. All requests share
  `OverpassConversation`'s gate and its single retry.
- **Stadia elevation is Pro-only and never fetched for a list.**
  `StadiaElevationSource` is billed per call, so it refuses before forming a
  request unless `MapEntitlement.current` is entitled (`.unknown` refuses too).
- **Commons photographs** fill a curated route's strip and the area search
  (`CommonsPhotoSourcing`, live only from the composition root).
  - Keep only CC BY, CC0 or public-domain files, credited with
    `PhotoLicenseCredit`.
  - Fetch over HTTPS from the two hosts the privacy policy names
    (`CommonsPhotoQuery.imageHosts`), sending `TileCache.userAgent`.
  - Make one Action API request at a time, across the whole app
    (`CommonsRequestGate`), and fetch nothing in Low Data Mode.
  - Never offer one for community sharing: `HikePhoto.isOwn` is false.
  - A saved copy whose file this device lacks is downloaded again where it
    is shown, never for a list, and only as the revision its credit
    describes (`HikePhotoLicense.fileSHA1`, `CommonsCopy`). It is reached
    only through `HikePhotoStore.shared` (`CommonsPhotoRefetch`).
- **Wikipedia on a place's card** (`Hikes/Places/Wikidata/`) is asked for when
  a card opens, never for a list, and never in Low Data Mode. What comes back
  is kept in memory only (`WikidataPlaceLookup`): the words are Wikipedia's,
  under CC BY-SA, so they are shown with their credit and link and never
  written to the device, copied into a hike or shared.
- **Shared hikes draw as lines and pins.** MapKit never hit-tests overlays, so
  the app does (`RouteHitTest`). Pins stay, because a polyline is not an
  accessibility element.

### The trail squares

A curated search used to wait in Overpass's queue, so its answer is built
ahead of time: OpenStreetMap's waymarked day hikes, filed by quarter-degree
square, one tile a square of a PMTiles archive on the tile server, fetched
by name. `TrailCellGrid` argues the grid and has the measurements,
`SquareArchive` says where a square is in its archive, and
`SquareArchiveServer` reads it. The three sets after this one are built,
packed and read on the same terms.

- **An answer is complete or it is not given** (`TrailCellLibrary`). A search
  is answered from the squares only when the server lists an archive of them
  this build reads, and every square within reach of the search was read or
  has no tile. Otherwise `CuratedTrailSource` asks Overpass as it did before.
  So an empty answer from the squares means *no trails here*. A downloaded
  area's squares are read first (*The offline countries*).
- **Only a build of the whole planet goes up.** A square with no tile is read
  as ground with nothing on it, so `pack` and `upload-archive` refuse a build
  without `--world`.
- **Each set has a list of its own in the server's manifest**: `routing`,
  `trails`, `routes` and `places`, newest first (*Tiles*). A build reads the
  first archive of its set's generation and zoom, a new build is a new
  archive name, never one replaced in place, and a 410 has the manifest read
  again and every square of that call asked again, so that a call's squares
  are one build's. A call is held to its library's limit for a whole
  request, and keeps what arrived by then (`SquareArchiveServer`).
- **A square is a tile at its row and column** (`SquareArchive`), at the
  shallowest zoom that holds every square of its grid, one zoom a
  hiking-routes level. The trail graph's tiles are its regions. The zooms
  are a storage contract (`SquareArchiveTests`).
- **The squares reach further than Overpass is asked**
  (`CuratedTrailQuery.maximumRadiusMeters` against
  `maximumOverpassRadiusMeters`). Between the two, a search the squares cannot
  answer fails as a search does, and Overpass is asked nothing.
- **A square holds relations as OpenStreetMap has them**, not assembled
  lines. Which ways are the route stays `CuratedTrailDecoding`'s, applied to a
  square as it is to an Overpass answer (`CuratedTrailSourceTests+Cells` holds
  the two to one result).
- **`CuratedTrailQuery`'s day-hike figures are the grid's**, spelled once:
  raising them without rebuilding the squares would offer nothing more.
- **The file's generation is in every square's name** (`trails1_…`) and in
  its archive's entry in the manifest. A file an installed build cannot read
  goes up as the next generation, beside the old one, which stays listed
  for the builds that read only that.
- **The tool compiles the app's grid, file and archive files**
  (`tool_sources` in `Scripts/trail-cells.sh`). They import nothing of the
  app's, and `Scripts/run-script-tests.sh` builds the tool, which is what
  holds them to that.
- **Building and publishing** is `Scripts/trail-cells.sh`, whose header has
  every option:
  1. `update-planet <planet.osm.pbf>`. The planet is downloaded once and then
     kept current with the hourly changes openstreetmap.org publishes,
     because the volunteers who serve it asked that it not be downloaded
     again for each refresh.
  2. `build <planet.osm.pbf> --world`, `build-routes`, `build-places` and
     `build-routing`, each with `--world`.
  3. `pack <dir>` for the first three; `build-routing` writes its archive
     itself.
  4. `upload-archive <dir>` for all four, then `Scripts/vector-archives.sh
     use` with each name, `publish`, and commit the manifest (*Tiles*).
- **The public database's copies are for builds v1.5-1 to v1.7-1.** Those
  read the squares as `CuratedTrailCell` records, under the same names
  (*Persisted identifiers*), and nothing later does. `upload` refreshes them,
  and `prune` takes a set down once those builds are gone: it marks the
  set's manifest incomplete first, so they fall back to Overpass, deletes
  the squares, and deletes the manifest record last, because it is the only
  list of them. Both record types were added by schema import before the
  first upload, for the reason *A new field arrives indexed* gives.
- **No suite reaches any of the squares.** Each set's source is `nil` under
  `isRunningTests`: `makeCommunityTransport()`,
  `HikingRouteSquares.forThisLaunch()`, `makeTrailPointSource()` and
  `TrailGraphSquareLibrary.forThisLaunch()`.

### The hiking-routes layer

*Hiking Routes*, chosen on *Map Modes*, draws every `route=hiking` relation
OpenStreetMap has over whichever map is selected, colored by its network. The
app draws it (`HikingRoutesRenderer`) from squares kept beside the trail
squares. `RouteSquareGrid` argues the design and has the measurements.

- **On unless the hiker turns it off, and nothing of it is a tile.** Auto-save
  and downloads ask the selected map alone.
- **Names of their own.** A routes square is `routes1_z<zoom>_<row>_<col>`,
  in the `routes` archive, one zoom of it a level. The build writes
  `routes-manifest.json`, never `manifest.json`, because a tool from before
  the layer reads only that name and would take the layer's squares for the
  day hikes'.
- **Drawn only from a set that is the whole world** (`HikingRouteSquares`).
- **A tile waits for every square it overlaps**, so a line never stops at the
  edge of a square that has not come. Nothing on MapKit's drawing threads
  waits on the disk or the network, and the redraw is asked for on the main
  thread.
- **Ways are joined end to end when a square loads** (`DrawnRouteSquare`).
  Stroked one way at a time, a zoomed-out tile stalled every overlay on the
  map, the base map's tiles included.
- **The look is Waymarked Trails', figure for figure** (`HikingRoutesStyle`),
  and the caption on *Map Modes* credits it (`HikingRoutesPicker`): the
  figures were read out of the map style that project publishes under the
  GPL, and the owner settled on a credit in the caption, in every language.
  It stays for as long as the look does.
- **Every size is in tile pixels** (`1 / zoomScale` map points), because
  MapKit hands a phone tiles one to two zooms deeper than its screen.
- **Signs are placed once for a square and a zoom, never tile by tile**
  (`DrawnRouteSquare+Waymarks.swift`), so a sign across two tiles is whole in
  both.

### The place squares

What a place search offers (*Search this area*, *Places Around Trail*, *Add
Place* and *Places Nearby*) is built ahead of time the same way: every element
`TrailPointQuery` asks Overpass for, filed by one-degree square, one tile a
square of the `places` archive, named `places1_<row>_<col>`.
`PlaceSquareGrid` argues the size and has the measurements.

- **The squares first, Overpass second** (`TrailPointSource`, through
  `PlaceSquareLibrary`), on the trail squares' terms.
- **The tool keeps the kinds and the tags in lists of its own**
  (`PlaceSquareFile.kinds` and `keptTagKeys`), because it cannot compile
  `TrailPointQuery`. `PlaceSquareFileTests` holds them to the query's kinds
  and to what a place card reads; a new kind or fact is a rebuild.
- **The symbol is the app's.** A square holds tags, and
  `TrailPointDecoding.place(…)` reads them as it reads an Overpass element.

### The trail graph

What a recording is matched against, a hike's surface and difficulty are read
from, a route is colored by, and the trail maker and *Edit Route*'s redrawn
stretches route over is one graph: every trail and every road that joins
trails (`TrailGraphHighway.all`), as an Overpass answer for a region holds
it. It is built from the planet into one PMTiles archive on the tile server,
a z12 tile a region, each tile a `TrailGraphSquareFile`, and read on the
trail squares' terms. `RoutingGraphArchive` argues the design.

- **One library, two providers** (`OpenHikesModel.makeTrailGraphProviders()`).
  The recorder's provider and the maker's read the same tiles through one
  `TrailGraphSquareLibrary`, and ask Overpass only for a region the server
  cannot answer. Overpass's `429` stops only a region that would ask
  Overpass, in both, which share its deadline (`OverpassRetryDeadline`).
- **A reader that wants trails keeps the trail edges**
  (`TrailGraphEdge.isTrail`), as it always did with an Overpass answer, which
  carries the roads too.
- **The providers keep their regions apart**: the recorder's in
  `TrailGraphTrails`, which builds v1.5-1 to v1.7-1 filled from the public
  database's trails-only squares (`graph1_z10_<x>_<y>`), and the maker's in
  `TrailGraphs`, which never held a region without its roads.
- **A region read from a tile is the graph Overpass gives** for the same
  ways, joined at the same node ids, so the two merge in the provider's cache
  (`SquareArchiveServerTests`, `TrailGraphSquareLibraryTests`). The walking
  and hiking-route rules are written once, in `TrailGraphSquareFile`, for the
  decoder and the tool.
- **The tile is the trail graph's file.** A change to
  `TrailGraphSquareFile`, `TrailGraphHighway` or the walking rules is a new
  archive, and one an installed app would read wrong goes up under the next
  generation.
- **The build streams bands of longitude** (`build-routing`), because no
  index of every such node's position in the planet fits in memory. The
  bands' edges, and the time and the disk a planet's build takes, are
  measured in `Scripts/trail-cells.sh`'s header.

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
- **A phone recording outranks the watch's own.** The watch refuses to start
  while the phone records. The reverse is unguarded: the phone never learns of
  a watch recording.
- **Which `WCSession` door a payload uses is a decision.** The library goes as
  the application context (latest wins). The live recording mirror goes by
  `sendMessage` with no reply and is dropped when the watch is out of reach,
  because a late reading is a wrong one. Commands use `sendMessage` with a
  reply handler and have no fallback: a button press delivered late is worse
  than none. Everything else goes by `transferUserInfo`, because `sendMessage`
  fails out of range. `WatchLink` is the only encoder, with one function pair
  per `WatchMessageKind`.
- **No transfer leaves before activation completes**, because
  `transferUserInfo` on a session that has not activated is a programmer
  error (`WatchLinkActivation` on the watch, `WatchSessionActivation` on the
  phone).
- **A recorded walk is written before it is sent.** `WatchStore` queues it on
  disk and drops it only on a `WatchWalkReceipt`. The phone's import is
  idempotent on `HikeLocalState.watchSessionID`, and deleting the hike leaves
  a `DeletedWatchWalk` in the same save, so a retry still earns its receipt
  and does not bring the hike back. Until Stop, `WatchRecorder` journals
  fixes, pauses and resumes. The import keeps a session's first arrival, so
  the drain never sends a walk the recorder may still replace: none while
  the launch reads the journal or cannot, and never the session the
  recorder holds (`WatchQueueHold`). A journal that cannot be read is not
  a missing one, and holds Start until it reads or the hiker discards it.
- **The watch matches against the trail itself.** `WatchRouteTracker` uses one
  polyline. It is not `TrailMatcher` and must not grow toward it. Its
  thresholds are `RouteProfile`'s (`WatchFixPolicyParityTests`).
- **The workout session only keeps the app alive.** Its builder is always
  discarded, because the phone's `HealthKitWorkoutWriter` is the walk's only
  Health writer. The session is read for heart rate alone, and its data
  source collects nothing else (`WatchWorkoutCollection`).
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
  (`group.tappium.com.OpenHikes.watch`).
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
  `Activity` is boxed in a `nonisolated` `@unchecked Sendable` handle,
  `ActivityState` is matched positively, and a running activity is adopted,
  never requested twice.
- **A live recording outranks the selected trail, on every surface, without
  qualification** (*The app* names the places that hold the rule).
  - The widget replaces the trail rather than badging it, and a paused
    recording keeps the widget. The takeover writes nothing, so the trail
    returns the moment the recording clears.
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
  (`PhotoUnavailability`), and its page offers no retry, since there is no
  file to wait for. The photograph itself is the synced hike's, so the
  gallery's Delete is still offered there: it removes it from the hike on
  every device, and says so first (`PhotoUITests+Deletion.swift`). The
  community's public copies do not reopen this. A Wikimedia Commons copy is
  the one exception: it is somebody else's picture that Commons still holds,
  so a device without its file downloads it again
  (`HikePhotoStore.restore(_:)`).
- **The live average speed keeps its clock, and is spoken in full.** Every
  *Avg Speed* that is not named for a clock divides by the walk's active
  clock: the time between kept fixes, which leaves pauses out and counts a
  rest taken without one. A saved hike's two averages are named for their own
  clocks, *Overall* and *Moving*, so after a pause the live figure matches
  neither. Moving time live would need a moving-time rule for the watch in
  `OpenHikesShared` and a mirrored `HikeWalk` column for the share card to
  agree.
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
  - A synced `tileProviderID` cannot blank a keyless device
    (`TileProvider.renderable(id:)` falls back).
  - The two copies of `Color+Hex` are the widget's cost, and `ColorHexTests`
    holds them equal.
  - `.readWrite` photo access is required for reading and for limited access.
  - The bare `Task {}`s on main-actor types are main-actor work.
  - `aps-environment = development` is correct, because signing substitutes
    `production` on archive.
- **Load-bearing but never observed.**
  - The overzoom path, and the redraw that puts a refreshed tile over the
    saved copy drawn ahead of it, assume MapKit re-enters `draw` after
    every `setNeedsDisplay(_ mapRect:)`. Watched on an iOS 27.2 simulator,
    never on a device or on the floor.
  - Mirroring is assumed to carry `@Attribute(.externalStorage)` routes as
    `CKAsset`s. Nobody has watched a 20,000-point route cross a real container.
  - A tilted map's tiles assume MapKit drapes a replacing tile overlay, and
    every line above it, over the realistic satellite map's terrain. Watched
    on iOS 18.6 and 27.2 simulators, never on a device.
  - No search in the app has been watched reading a square from the tile
    server, on a device or in a TestFlight build, and nobody has watched the
    widest search on a cellular connection. Every set has been read from the
    live server through `SquareArchiveServer`, hosted in a simulator, each
    square identical to its build.

## Documentation

Each fact lives in one file:

| File | What it owns |
|---|---|
| `AGENTS.md` (this file) | Commands, architecture, conventions, policies, settled decisions, CloudKit deployment facts |
| `README.md` | What the app is and needs, and how to build it and find your way around. No engineering rationale. |
| `CONTRIBUTING.md` | A person's short path to a first change. It points here. |
| `SECURITY.md` | Vulnerability reporting, and what the public database grants to whom (the argument stays in `CommunitySchema.swift`) |
| `Screenshots/README.md` | The App Store screenshot set, its capture scripts, and the copies the home page shows |
| `docs/` | The GitHub Pages site: a home page, and the privacy, terms and support pages linked from the App Store listing. It is not a documentation folder; new prose goes at the repository root. |

- **Open work is a GitHub issue, never a checked-in list.**
- **This file takes rules, not descriptions.** What a feature does, how it
  was measured and why it is built that way go in the header of the type
  that owns it, and a script's procedure in the script's header. A feature
  earns a line here when a change somewhere else could break it, and the
  line names the type to read.
- **Cite this file by section name.** Code comments cite sections such as
  *Schema and migration policy*, *Settled decisions*, *Deliberate test seams*
  and *The watch app*, so keep those names stable. Never cite a number or a
  quoted figure; those go stale.
