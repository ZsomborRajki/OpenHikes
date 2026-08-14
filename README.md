# OpenHikes

OpenHikes is a local-first SwiftUI and SwiftData trail viewer for iOS, iPadOS, macOS, and visionOS. It imports GPX tracks, displays them on a MapKit map, provides route statistics and an interactive elevation profile, and keeps selected map areas available offline.

## Features

- GPX import with track metadata, route statistics, elevation chart scrubbing, route styling, and direction chevrons. A downloaded `.gpx` file opens straight into the app from Files, AirDrop, or any share sheet, as well as through the in-app document picker.
- GPX export from a hike's detail view: the Share button hands the route, its elevations, its fix times, and its metadata to any share destination as a GPX 1.1 file, serialized off the main thread only once a destination is picked.
- Live hike recording with balanced location accuracy, background location, pause/resume, crash-safe recovery, motion-aware fix handling, barometric elevation fusion, and one-time SwiftData save.
- Bounded live trail matching from an extending cached OpenStreetMap walking graph, and a post-recording review where every section the matcher moved or found ambiguous can be kept as the mapped trail, handed back to the raw GPS trace, or swapped for an alternative route; unavailable matches preserve the GPS trace.
- Search across saved hikes and MapKit place suggestions.
- OpenStreetMap, Stadia Outdoors, and Thunderforest Outdoors tile providers.
- Live location, trail auto-follow with a progress readout, and current WeatherKit conditions.
- Passive tile auto-save for browsed areas, plus bulk offline downloads where the provider permits them.
- An iOS Home Screen widget with trail progress, live-recording takeover, recording deep links, and sparse location anchors that help repair degraded GPS gaps.
- Local SwiftData and App Group storage; OpenHikes has no backend or account sync.

## Requirements

- Xcode 26.5 or later.
- iOS/iPadOS 26.5, macOS 26.5, or visionOS 26.5.
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
Scripts/run-ui-tests.sh --all

# Measure render, main-thread and resource behavior; writes a markdown report
Scripts/run-performance-tests.sh
Scripts/run-performance-tests.sh --test testLiveRecordingCostPerFix

swift test --package-path OpenHikesShared

swiftlint lint --strict
```

Unit and integration tests use Swift Testing. `OpenHikesUITests` uses
XCTest/XCUITest because Apple's UI automation and launch-performance metrics
are not available through Swift Testing. UI-test launches use an in-memory
SwiftData store and isolated preferences; coverage includes app/settings smoke
navigation, bundled GPX import, programmatic simulator location, recording
startup, the record → review → save round trip, and
`XCTApplicationLaunchMetric`.

CI runs strict SwiftLint, the shared package suite, the app and widget unit
tests, warning-free debug/release builds, and the concurrent GPX parser under
Thread Sanitizer. It deliberately does not run the simulator UI automation or
the performance suite: both drive real gestures against a booted simulator with
timing-sensitive waits, which a shared runner makes slow and flaky. Run those
locally with `Scripts/run-ui-tests.sh` and `Scripts/run-performance-tests.sh`
before a change that touches recording, the map, or render isolation.

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
| `OpenHikes/Weather/` | WeatherKit polling and presentation state. |
| `OpenHikes/Settings/` | User-facing app, recording, map, and storage settings. |
| `OpenHikes/General/` | Cross-domain extensions and diagnostics. |
| `OpenHikesShared/` | Domain-foldered local Swift package shared by the app and widget. |
| `OpenWidget/` | iOS Home Screen widget. |
| `OpenHikesTests/` | App-hosted tests mirroring the app's domain folders. |
| `OpenWidgetTests/` | App-hosted tests for the widget's timeline, families, and basemap pairing. |
| `OpenHikesUITests/` | iOS Simulator UI automation, location spoofing, and launch metrics. |

See [`.github/copilot-instructions.md`](.github/copilot-instructions.md) for architecture and repository conventions. See [`CODE_REVIEW.md`](CODE_REVIEW.md) for the open code-quality action plan and unresolved design decisions.

## Current limitations

- Offline trail matching is limited to Overpass graph regions that were cached previously; prebuilt regional graph bundles are not shipped.
- Sign in with Apple is a disabled placeholder, and hikes do not sync between devices.
- Third-party tile keys can only be supplied at build time.
