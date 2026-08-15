# OpenHikes repository instructions

## Build and test

The main project requires Xcode 26.5+, the iOS 26.5 platform, and a development team capable of signing the WeatherKit entitlement. The shared package can be built and tested independently on macOS.

```sh
# Build the app and its embedded widget target
xcodebuild build \
  -project OpenHikes.xcodeproj \
  -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Run all app-hosted tests
xcodebuild test \
  -project OpenHikes.xcodeproj \
  -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Run one app test suite or one test method
xcodebuild test -project OpenHikes.xcodeproj -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:OpenHikesTests/HikeStatisticsTests
xcodebuild test -project OpenHikes.xcodeproj -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:OpenHikesTests/HikeStatisticsTests/elevationGainAndLoss

# Run just the widget bundle
xcodebuild test -project OpenHikes.xcodeproj -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:OpenWidgetTests

# Run simulator UI automation and launch performance metrics
xcodebuild test -project OpenHikes.xcodeproj -scheme OpenHikesUI \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Run the standalone shared-package suite
swift test --package-path OpenHikesShared

# Run one shared-package suite or test
swift test --package-path OpenHikesShared --filter MercatorTests
swift test --package-path OpenHikesShared \
  --filter 'OpenHikesSharedTests.MercatorTests/tileIndicesUnchanged'
```

Unit and integration tests use Swift Testing (`@Suite`, `@Test`, `#expect`). The `OpenHikesUITests` simulator bundle uses XCTest/XCUITest because Apple's UI automation and performance metrics are not available through Swift Testing. The main `xcodebuild test` action runs the two app-hosted bundles, `OpenHikesTests` and `OpenWidgetTests`, plus `OpenHikesUITests`; the dedicated `OpenHikesUI` scheme runs only UI automation. `OpenWidgetTests` compiles `OpenWidget/TrailWidget.swift` into itself, since an app extension cannot host a test bundle.

App tests use the in-memory SwiftData fixtures in `OpenHikesTests/General/TestSupport.swift`. A suite that touches the tile pipeline builds a `TileSandbox` — its own `TileCache` directories and its own `AutoSaveTileStore` — rather than `TileCache.shared`; the singletons belong to the app, and suites run in parallel. Likewise `BackgroundTrailTracker`, `LocationManager` and `OfflineTileDownloader` take injectable location, defaults, clock and transport, so no test depends on wall-clock time, a real connection, or the host app's settings.

UI-test app launches pass `--ui-testing`, which selects an in-memory SwiftData store and isolated `UserDefaults`. Additional launch arguments can expand the sheet (`--ui-test-expanded-sheet`), enable real simulator Core Location (`--ui-test-enable-location`), import a bundled GPX fixture (`--ui-test-import-gpx=ThumseeLoopFast`), match against a bundled trail graph instead of Overpass (`--ui-test-trail-graph=ThumseeRidgePath`), or open a performance log for a named scenario (`--ui-test-performance-log=<scenario>`). XCUITest drives static locations through `XCUIDevice.shared.location`; longer route playback remains available through `Scripts/simulate-hike.sh`. `Scripts/run-ui-tests.sh` boots one UI test (or `--all`) against a named simulator.

`PerformanceUITests` is a measurement suite rather than a correctness one. `--ui-test-performance-log=<scenario>` makes `PerformanceLog` write every signpost mark and interval, every `MainThreadWatchdog` stall and a 1 Hz CPU/footprint sample to `Documents/PerformanceLogs/<scenario>.tsv`; the test additionally sets `RENDER_SIGNPOST_LOG=1` in `launchEnvironment`, since a test plan's environment reaches the runner and not the app. Because the test is out of process, it reads live counters through the `performance-counters` accessibility probe. `Scripts/run-performance-tests.sh` runs the suite, pulls the TSVs with `simctl get_app_container`, and renders a report through `Scripts/perf-report.py`. Baseline numbers and the open work live in `PERFORMANCE.md`.

Neither UI automation nor the performance suite runs in CI — both drive a booted simulator through real gestures and timing-sensitive waits, which a shared runner makes slow and flaky, and the performance suite needs `simctl privacy grant location-always` plus stable hardware for its numbers to mean anything. `PerformanceUITests` is listed in `skippedTests` for `OpenHikes.xctestplan`, so `xcodebuild test -scheme OpenHikes` does not pay for it; the `OpenHikesUI` scheme autocreates its plan and therefore still sees it, which is how `Scripts/run-performance-tests.sh` selects it. `Scripts/run-ui-tests.sh --all` scopes to `OpenHikesUITests/OpenHikesUITests` for the same reason. A new UI test class added to that bundle inherits none of this and must be placed on the correct side of it.

Three things that suite learned the hard way. Absolute memory readings taken under XCUITest are automation overhead, not the app's footprint — the same build launched by `simctl` sits ~130 MB lower — so only compare footprints within a run. The first hit-test against a newly presented screen makes SwiftUI evaluate bodies, so a phase must warm the accessibility tree before it starts counting or it is charged for the previous screen. And `stopMeasuring()` truncates `XCTApplicationLaunchMetric`'s signpost interval, which makes `harvestData` raise rather than report; let the measure block end on its own.

A UI test that spoofs a route has to respect `RecordingFixPolicy`: a static simulated location is delivered once, so a fix rejected for implied speed or displacement has to be set again, and the test waits on the `recording-point-count` element rather than on a fixed sleep. Accessibility identifiers belong on the leaf views automation taps — SwiftUI pushes a container's identifier down onto every descendant, which would leave a whole screen answering to one name.

A suite that genuinely cannot run without an environment capability (today: the App Group container) stays conditionally enabled, but must report the skip through `SuitePrecondition`; strict mode turns a missing precondition into a failure — `xcodebuild test … "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) REQUIRE_ALL_SUITES"` from a command line, or `OPENHIKES_REQUIRE_ALL_SUITES=1` in the scheme's test action from Xcode (a simulator-hosted test bundle inherits nothing from the invoking shell, which is why there are two).

Lint with `Scripts/lint.sh` (`--fix` applies what SwiftLint can correct). It runs strict SwiftLint at the version pinned in `.swiftlint-version`, and the CI `quality` job invokes that same script, so local and CI results cannot drift. The Xcode build also lints, through SwiftLintPlugins' `SwiftLintBuildToolPlugin` attached to `OpenHikes`, `OpenWidgetExtension`, `OpenHikesTests` and `OpenWidgetTests`, but it runs without `--strict` and at the version the package resolves to, so it warns rather than decides — `Scripts/lint.sh` is what a change has to pass. `Scripts/install-git-hooks.sh` installs an opt-in pre-push hook. There is no formatting command.

That plugin only runs once its package fingerprint is trusted, and the trust lives per user in `~/Library/org.swift.swiftpm/security/plugins.json`, outside the repository — so a fresh CI machine fails with `Plugin "SwiftLintBuildToolPlugin" ... must be enabled before it can be used`. The checked-in `AllowedPackagePlugins.json` covers opening the project locally; CI does not read it. Every `xcodebuild` call in `.github/workflows/ci.yml` therefore passes `-skipPackagePluginValidation`, and a new one must too. Xcode Cloud composes its own `xcodebuild` invocation and cannot take that flag, so `ci_scripts/ci_post_clone.sh` — which Xcode Cloud runs by name after cloning — sets `IDESkipPackagePluginFingerprintValidatation` (Apple's typo, not ours) and `IDESkipMacroFingerprintValidation` instead. Adding a package that ships a build tool plugin or a macro needs no further change; removing the SwiftLint plugin would make all of it dead weight.

A test that provokes a `nonisolated` delegate callback must wait through `settleDelegateHop(until:)` in `OpenHikesTests/General/SettleSupport.swift`, naming the effect it expects, rather than spinning a fixed number of `Task.yield()`s. The bundle is main-actor isolated project-wide and Swift Testing runs its suites in parallel in one process, so every main-actor test contends for one executor and a yield count buys an amount of progress that depends on machine load — which is how `Map coordinator` and `Location publishing` went red on CI while passing locally. The condition-less overload is best-effort only.

## Architecture

- Following Apple's Food Truck and Backyard Birds samples, `OpenHikes/` is organized by product domain rather than generic `Managers`, `Models`, and `Views` layers. `App/` is the composition root; `Hikes/`, `Recording/`, `Map/`, `Tiles/`, `Weather/`, and `Settings/` own their related models, services, and views.
- `OpenHikesApp` creates one `OpenHikesModel` and injects it through the SwiftUI environment. That model owns the single `ModelContainer` plus long-lived location, weather, background tracking, auto-save, and recording dependencies; `OpenHikesView` owns transient selection, map presentation, and navigation state. `Hike` is the persisted source of truth, while `RouteProfile` is the precomputed distance/elevation index used by both chart scrubbing and GPS route matching. Stopping a recording that the matcher moved or found ambiguous ends in `.reviewing` rather than in the store: `RouteReviewSection.sections(in:)` groups the per-fix legs into reviewable sections, `RecordingRouteReview` holds the per-section `TrailRouteChoice`, and only `saveReviewedRecording()` writes the `Hike`.
- The map is an imperative MapKit subsystem behind `MapView`. `MapCoordinator` observes stable controller objects and updates `MKMapView` directly. Tile drawing flows through `CachingTileOverlayRenderer` and `TileOverlay` into `TileCache`; passive durable saves go through `AutoSaveTileStore`, while policy-permitted bulk downloads go through `OfflineTileDownloader`.
- `OpenHikesShared` is a local Swift package consumed by the app and iOS widget. Its source and tests mirror the `Recording/`, `Trails/`, `Widget/`, and `General/` domains; put cross-target payloads, projections, deep links, and shared presentation logic there rather than duplicating them in targets.
- The app precomputes a compact `SharedTrailSnapshot`, writes it atomically through `SharedStore`, and reloads widget timelines. The iOS widget reads that App Group store directly and does not recompute route matching or read location itself.
- Target folders are Xcode file-system-synchronized groups. New Swift files under `OpenHikes/`, `OpenHikesTests/`, `OpenHikesUITests/`, `OpenWidget/`, or `OpenWidgetTests/` are discovered by their corresponding targets; place files in the target that should compile them. `OpenWidget/` is synchronized into two targets — the extension and `OpenWidgetTests` — with `OpenWidgetBundle.swift` excluded from the latter, since a test bundle must not carry a second `@main`.

## Repository-specific conventions

- Preserve render isolation. High-frequency GPS, sheet, chart-scrub, route-styling, and map-command state lives in stable `@Observable` reference types such as `RouteHighlight`, `SheetMetrics`, `RouteStyle`, `MapController`, `TrackerState`, and `LocationManager`. Parent SwiftUI bodies must not read their changing properties; `MapCoordinator` uses `withObservationTracking` to update only MapKit. Use `RenderSignpost` and the `RENDER_SIGNPOST_LOG=1` scheme variable when changing this flow.
- UI and SwiftData coordination are main-actor isolated. Delegate callbacks are `nonisolated` and explicitly hop to `Task { @MainActor in ... }`. Tile math, image encoding, disk enumeration, and other blocking pipeline work stay off the main thread; existing hot paths call `assertOffMainThread`. Keep shared off-main types `Sendable` and protect mutable singleton state with the existing lock pattern.
- Respect tile-provider policy. `TileProvider.supportsBulkDownload` gates prefetching: OpenStreetMap is passive auto-save only. Tile identity includes provider, zoom/x/y, and display scale. When deleting durable tiles, use `TileOwnership` so tiles shared by multiple hikes are not removed.
- `TileCache` intentionally has memory, ephemeral cache, and durable Application Support tiers. Do not turn a render miss into synchronous disk/network work, and do not move expensive storage measurement into a SwiftUI body.
- When adding non-optional properties to the SwiftData `Hike` model, give them inline declaration defaults as well as initializer defaults so lightweight migration can backfill existing stores.
- Keep persisted identifiers stable: provider IDs, `SettingsKey` strings, `SharedStore.appGroupID`, widget kind, cache-key shape, and deep-link format are shared across launches or targets. Update all entitlements/consumers together if an App Group contract changes.
- Both unit-test bundles are hosted by the app, so it launches and runs its `.task`s before any test does. Startup work that writes shared state — today `OpenHikesView.restoreLastSelectedHike()`, which publishes a widget payload — must stay behind the `isRunningTests` guard, or it races the suites that assert on that state. UI tests run out-of-process and identify the app-under-test with `--ui-testing`.
- The app ships for iPhone only: every target declares `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"` and `TARGETED_DEVICE_FAMILY = 1`. An embedded extension's device family has to stay a subset of its host's, so `OpenWidget` moves with the app rather than independently. The `canImport(UIKit)`/`canImport(AppKit)` aliases and `#if os(iOS)` guards in the existing sources are kept — they cost nothing and are what a later iPad, Mac or visionOS target would be rebuilt from — but nothing verifies those paths compile any more, so treat them as unbuilt rather than supported.
- Never commit `OpenHikes/Secrets.plist`. Copy `Secrets.example.plist` locally for Stadia or Thunderforest keys; OpenStreetMap remains the keyless default.
