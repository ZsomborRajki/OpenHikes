# OpenHikes

OpenHikes is a local-first SwiftUI and SwiftData trail viewer for iPhone. It imports GPX tracks, displays them on a MapKit map, provides route statistics and an interactive elevation profile, and keeps selected map areas available offline.

## Features

- GPX import with track metadata, route statistics, elevation chart scrubbing, route styling, and direction chevrons. A downloaded `.gpx` file opens straight into the app from Files, AirDrop, or any share sheet, as well as through the in-app document picker.
- GPX export from a hike's detail view: the Share button hands the route, its elevations, its fix times, and its metadata to any share destination as a GPX 1.1 file, serialized off the main thread only once a destination is picked.
- Live hike recording with balanced location accuracy, background location, pause/resume, crash-safe recovery, motion-aware fix handling, barometric elevation fusion, and one-time SwiftData save.
- Bounded live trail matching from an extending cached OpenStreetMap walking graph, and a post-recording review where every section the matcher moved or found ambiguous can be kept as the mapped trail, handed back to the raw GPS trace, or swapped for an alternative route; unavailable matches preserve the GPS trace.
- Search across saved hikes and MapKit place suggestions.
- OpenStreetMap, Stadia Outdoors, and Thunderforest Outdoors tile providers.
- Live location, trail auto-follow with a progress readout, and current WeatherKit conditions.
- Photos taken on a walk or picked from the library, pinned to where on the trail they were taken, shown as a gallery strip on the hike and as pins on the map, with an optional copy saved to the photo library.
- Passive tile auto-save for browsed areas, plus bulk offline downloads where the provider permits them.
- An iOS Home Screen widget with trail progress, live-recording takeover, recording deep links, and sparse location anchors that help repair degraded GPS gaps.
- Local SwiftData and App Group storage; OpenHikes has no backend or account sync.

## Requirements

- Xcode 26.5 or later.
- iOS 26.5. Every target ships iPhone-only (`TARGETED_DEVICE_FAMILY = 1`); the
  sources still carry their `canImport(AppKit)` and `#if os(iOS)` guards, but
  no iPad, Mac or visionOS destination is built or tested.
- An Apple development team that can sign the WeatherKit entitlement and the shared App Group.

OpenStreetMap is the keyless default. Stadia and Thunderforest require build-time API keys.

## Setup

1. Open `OpenHikes.xcodeproj`.
2. Set your development team for `OpenHikes` and `OpenWidgetExtension`.
3. If your team cannot use `group.tappium.com.OpenHikes`, replace it in both entitlement files and in `SharedStore.appGroupID`.
4. Optionally enable Stadia or Thunderforest:

   ```sh
   cp Secrets.example.plist OpenHikes/Secrets.plist
   ```

   Add your keys to the copied file. `OpenHikes/Secrets.plist` is gitignored and must never be committed; unavailable providers remain disabled in Settings.

5. Build and run. For simulated location features, use Xcode's location controls or the recording demo below.

## Recording demo

Build and launch OpenHikes on a booted iOS Simulator, open **Record Hike**, and tap **Start Recording**. From the repository root, replay the first 60 points of the bundled Thumsee route:

```sh
Scripts/simulate-hike.sh start
```

The default is an accelerated roughly 1.7 km preview. Use `--full --speed 4` for the complete 9.3 km route at a more realistic pace. Stop and clear location playback with:

```sh
Scripts/simulate-hike.sh stop
```

Run `Scripts/simulate-hike.sh --help` to select a simulator, another GPX file, playback speed, update interval, or point count.

## Build and test

```sh
xcodebuild build \
  -project OpenHikes.xcodeproj \
  -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

xcodebuild test \
  -project OpenHikes.xcodeproj \
  -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Run simulator UI automation and launch metrics only
xcodebuild test \
  -project OpenHikes.xcodeproj \
  -scheme OpenHikesUI \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Or run one UI test on a simulator; --list shows the available tests
Scripts/run-ui-tests.sh --test testReviewsSnappedRouteAfterStopping
Scripts/run-ui-tests.sh --suite AccessibilityUITests --all
Scripts/run-ui-tests.sh --all

# Measure render, main-thread and resource behavior; writes a markdown report
Scripts/run-performance-tests.sh
Scripts/run-performance-tests.sh --test testLiveRecordingCostPerFix

swift test --package-path OpenHikesShared

Scripts/lint.sh
Scripts/lint.sh --fix
```

`Scripts/lint.sh` is the same strict SwiftLint the CI `quality` job runs, at
the version pinned in `.swiftlint-version` — CI invokes the script rather than
`swiftlint` directly, so the two cannot disagree. The Xcode build additionally
runs SwiftLint through SwiftLintPlugins' `SwiftLintBuildToolPlugin`, attached to
the app, widget and both unit-test targets, but it lints without `--strict` and
at the version the package resolves to, so it surfaces violations as warnings
rather than deciding whether a change is clean. `Scripts/lint.sh` stays the
authority; `Scripts/install-git-hooks.sh` installs an opt-in pre-push hook that
runs it for you (bypass with `git push --no-verify`).

A build tool plugin only runs once its package fingerprint is trusted, and that
trust is recorded per user in `~/Library/org.swift.swiftpm/security/plugins.json`
— outside the repository. A fresh CI machine therefore fails with `Plugin
"SwiftLintBuildToolPlugin" ... must be enabled before it can be used` until it is
told otherwise. GitHub Actions passes `-skipPackagePluginValidation` to every
`xcodebuild` call; Xcode Cloud composes its own invocation and cannot take that
flag, so `ci_scripts/ci_post_clone.sh` sets the equivalent Xcode preference
instead. Add the flag to any new `xcodebuild` step in `ci.yml`, and keep the
post-clone script if a workflow builds through Xcode Cloud.

Unit and integration tests use Swift Testing. `OpenHikesUITests` uses
XCTest/XCUITest because Apple's UI automation and launch-performance metrics
are not available through Swift Testing. UI-test launches use an in-memory
SwiftData store and isolated preferences. The bundle is split by subject
rather than kept in one file, because a suite runs as a unit and the slow,
location-driven half should not have to run to check a search field:

| Class | Covers |
| --- | --- |
| `OpenHikesUITests` | Map and sheet navigation, GPX import, search, rename, delete, route line patterns, the surface and difficulty breakdowns, the weather badge, `XCTApplicationLaunchMetric`. |
| `RecordingUITests` | Recording start, pause and resume, discard, the record → review → save round trip, walking between review sections, and retrying a save that failed. |
| `PhotoUITests` | The library picker opening over the permanently presented sheet, the seeded gallery and its viewer, deletion, and showing a photo on the map. |
| `SettingsUITests` | Provider policy (no bulk download on OpenStreetMap), toggles that must hold their value across a reopen, and the field-report list, export sheet and delete. |
| `AccessibilityUITests` | `performAccessibilityAudit` per screen. |
| `AccessibilityLabelUITests` | The labels, values and traits the app promises. |
| `PerformanceUITests` | Measurement only; excluded from the test plan. |

The bundle's fixtures, launch helpers and gestures live in
`UITestSupport.swift`, and the audit types, the MapKit filter and the shared
report formatting live in `AccessibilityAuditSupport.swift`, so a new UI test
reaches a screen — and reports an audit failure — the same way the existing
ones do. `Scripts/run-ui-tests.sh` names its functional classes explicitly, so
a new class has to be added to that list to be reachable through the script.

The app recognises these launch arguments, all of which take effect only
alongside `--ui-testing`:

| Argument | Effect |
| --- | --- |
| `--ui-testing` | In-memory SwiftData store and isolated `UserDefaults`. |
| `--ui-test-expanded-sheet` | Opens with the map sheet already expanded. |
| `--ui-test-enable-location` | Uses real simulator Core Location instead of the stub. |
| `--ui-test-offline` | Empty tile storage root and no network monitor, so every tile is a genuine miss. |
| `--ui-test-import-gpx=<name>` | Imports a bundled GPX fixture at launch. |
| `--ui-test-trail-graph=<name>` | Matches against a bundled trail graph instead of Overpass. |
| `--ui-test-seed-photos=<count>` | Seeds a hike with generated photos, since the Simulator has no camera. |
| `--ui-test-seed-metrics=<count>` | Seeds the field-metrics store with reports, since a real one takes a walk to fill. |
| `--ui-test-fail-first-save` | Fails the first save of a finished recording, so the retry path can be driven. |
| `--ui-test-weather` | Serves a fixed forecast instead of WeatherKit, which needs a network and a signed entitlement. |
| `--ui-test-performance-log=<scenario>` | Writes signposts, stalls and samples to `Documents/PerformanceLogs/<scenario>.tsv`. |

`AccessibilityUITests` and `AccessibilityLabelUITests` are the VoiceOver half
of that bundle. The first runs `performAccessibilityAudit` per screen — the
sweep catches unnamed controls, tap targets below 44pt and elements it cannot
reach — over the map and sheet, a hike's details, settings, the recording
screen, route review, the photo gallery and the empty state. The second
asserts the labels, values and traits this app promises: that a hike row reads as one
element and reports which route the map is drawing, that a stat tile reads as
a label and a number rather than as spelled-out capitals, that the elevation
graph is a single adjustable element which speaks the point under the tracker,
and that the selected tile provider is more than a checkmark. The audit
excludes `.contrast`, `.textClipped` and `.dynamicType`, each for a reason
recorded next to the exclusion; MapKit's own subviews are filtered out of the
results rather than fixed, since the app does not draw them.

CI runs strict SwiftLint, the shared package suite, the app and widget unit
tests, warning-free debug/release builds, and the concurrent GPX parser under
Thread Sanitizer. It also runs both accessibility
classes, because a VoiceOver regression is invisible to a unit test and to a
reviewer, and because all but one of their tests are launch, tap and assert
against an in-memory store with no location and no measurement. That job is `continue-on-error` for now: UI
automation on a shared runner has to demonstrate a flake rate before it is
allowed to block a merge. The functional UI automation and the performance
suite stay out — both lean harder on real gestures and timing-sensitive waits.
Run those locally with `Scripts/run-ui-tests.sh` and
`Scripts/run-performance-tests.sh` before a change that touches recording, the
map, or render isolation.

`PerformanceUITests` measures rather than asserts correctness: it drives the app
through idle, map-browsing, chart-scrub and live-recording scenarios while the
app writes every render signpost, main-thread stall and a 1 Hz CPU/memory sample
to a TSV in its container. `Scripts/run-performance-tests.sh` runs the suite,
pulls those logs off the simulator, and turns them into a markdown report.
[`PERFORMANCE.md`](PERFORMANCE.md) documents the measured baseline, what it
found, and what is worth doing about it. It is excluded from the `OpenHikes`
test plan, so a normal `xcodebuild test` run does not pay for it; the
`OpenHikesUI` scheme still sees it, which is how the script runs it.

## Project layout

Following Apple's [Food Truck](https://github.com/apple/sample-food-truck) and
[Backyard Birds](https://github.com/apple/sample-backyard-birds) samples, app
source is organized by product domain rather than generic `Managers`, `Models`,
and `Views` layers. `OpenHikesModel` is the composition root injected into the
SwiftUI environment; feature-specific state and behavior remain in their
domain folders.

| Path | Purpose |
|---|---|
| `OpenHikes/App/` | App entry point, shared app model, configuration, deep-link routing, and root navigation. |
| `OpenHikes/Hikes/` | Persisted hike model, GPX import and export, route profile, statistics, and hike screens. |
| `OpenHikes/Recording/` | Live recording, recovery journal, sensors, trail matching, and recording UI. |
| `OpenHikes/Map/` | MapKit bridge, map state, search, location tracking, and map rendering. |
| `OpenHikes/Tiles/` | Tile provider policy, cache, auto-save, offline downloads, and overlay rendering. |
| `OpenHikes/Photos/` | Photo capture and import, the file store behind them, trail anchoring, and the gallery and viewer. |
| `OpenHikes/Weather/` | WeatherKit polling and presentation state. |
| `OpenHikes/Settings/` | User-facing app, recording, map, and storage settings. |
| `OpenHikes/General/` | Cross-domain extensions and diagnostics. |
| `OpenHikesShared/` | Domain-foldered local Swift package shared by the app and widget. |
| `OpenWidget/` | iOS Home Screen widget. |
| `OpenHikesTests/` | App-hosted tests mirroring the app's domain folders. |
| `OpenWidgetTests/` | App-hosted tests for the widget's timeline, families, and basemap pairing. |
| `OpenHikesUITests/` | iOS Simulator UI automation, location spoofing, and launch metrics. |
| `ci_scripts/` | Xcode Cloud hooks, run automatically by name. |

See [`.github/copilot-instructions.md`](.github/copilot-instructions.md) for architecture and repository conventions. See [`CODE_REVIEW.md`](CODE_REVIEW.md) for the open code-quality action plan and unresolved design decisions. See [`SOCIAL.md`](SOCIAL.md) for the client-side plan to add optional trail publishing and discovery without weakening the offline-first guarantees.

## Current limitations

- Offline trail matching is limited to Overpass graph regions that were cached previously; prebuilt regional graph bundles are not shipped.
- Sign in with Apple is a disabled placeholder, and hikes do not sync between devices.
- Third-party tile keys can only be supplied at build time.
