# OpenHikes

OpenHikes is a local-first SwiftUI and SwiftData trail viewer for iPhone. It imports GPX tracks, records live hikes, displays them on a MapKit map, provides route statistics and an interactive elevation profile, and keeps selected map areas available offline.

There is no backend and no OpenHikes account. Everything lives on the device, and what syncs travels through the walker's own private iCloud database.

## Features

- **GPX import and export.** A downloaded `.gpx` opens straight into the app from Files, AirDrop or any share sheet, with track metadata, route statistics — overall and moving-time average speed side by side, so a long lunch stop does not read as a slow walk — elevation-chart scrubbing, route styling and direction chevrons. The Share button hands a hike back out as GPX 1.1.
- **Live recording.** Background location, pause and resume, crash-safe recovery, motion-aware fix handling and barometric elevation fusion.
- **Trail matching and review.** Bounded live matching against a cached OpenStreetMap walking graph, then a post-recording review where every section the matcher moved or found ambiguous can be kept, handed back to the raw GPS trace, or swapped for an alternative.
- **Maps.** OpenStreetMap, Stadia Outdoors and Thunderforest Outdoors tile providers, plus an Apple Maps option that draws MapKit's own base map. Passive tile auto-save for browsed areas, and bulk offline downloads where the provider's terms permit them.
- **Photos.** Pictures taken on a walk or picked from the library, pinned to where on the trail they were taken, shown as a gallery strip and as map pins. Photos taken with the system camera during a recording are found afterwards and matched against the recording's own timestamps. Granting access to only some photos is handled rather than treated as a refusal.
- **Live context.** Current location, trail auto-follow with a progress readout, and search across saved hikes and MapKit place suggestions. WeatherKit conditions sit over the map as a badge that opens the forecast in full; temperatures and speeds are spelled in the units the reader's own locale uses.
- **Home Screen widget.** Trail progress, a climb/descent/high-point stat line, live-recording takeover, recording deep links, and sparse location anchors that help repair degraded GPS gaps.
- **Live Activity.** The same figures on the Lock Screen and in the Dynamic Island while a recording runs or a trail is being followed, ticking their own clock so a walk costs no updates while it is simply going well.
- **iCloud sync.** Hikes and their metadata follow the walker across their own devices, through their own private CloudKit database. Photo files and the tile cache stay on the device that produced them.

## Requirements

- Xcode 26.5 or later, and iOS 26.5.
- An Apple development team that can sign the WeatherKit entitlement, the shared App Group, the iCloud container and the push entitlement.
- iPhone only. Every target sets `TARGETED_DEVICE_FAMILY = 1`.

OpenStreetMap is the keyless default and Apple Maps needs no key either. Stadia and Thunderforest require build-time API keys *and* a paid subscription with each vendor, whose terms forbid using them free of charge in a shipping app — in OpenHikes they sit behind a yearly subscription, which is what pays for them. A build without keys shows them locked, and OpenStreetMap keeps working.

## Setup

1. Open `OpenHikes.xcodeproj` and set your development team for `OpenHikes` and `OpenWidgetExtension`.
2. If your team cannot use `group.tappium.com.OpenHikes`, replace it in both entitlement files and in `SharedStore.appGroupID`.
3. iCloud sync needs a CloudKit container. Xcode creates `iCloud.tappium.com.OpenHikes` on the first signed build; to use another identifier, replace it in `OpenHikes/OpenHikes.entitlements` and in `CloudSyncCoordinator.containerIdentifier`. SwiftData's mirroring creates the development schema from the model on first run.
4. Optionally enable Stadia or Thunderforest:

   ```sh
   cp Secrets.example.plist OpenHikes/Secrets.plist
   ```

   Add your keys to the copied file. `OpenHikes/Secrets.plist` is gitignored and must never be committed; unavailable providers stay disabled in Settings.

5. Build and run. `OpenHikes.storekit` at the repository root describes the paid-maps purchase and the shared scheme already points its Run action at it, so a local build has a working paywall with no Apple account involved.

Shipping the paid maps for real additionally needs a matching auto-renewable subscription in App Store Connect and an active Paid Apps agreement; `.github/copilot-instructions.md` carries the exact contract, including the product ID that can never change.

## Recording demo

Launch OpenHikes on a booted iOS Simulator, open **Record Hike**, tap **Start Recording**, and replay the bundled Thumsee route:

```sh
Scripts/simulate-hike.sh start          # ~1.7 km accelerated preview
Scripts/simulate-hike.sh --full --speed 4   # the complete 9.3 km route
Scripts/simulate-hike.sh stop           # stop and clear location playback
```

`--help` selects a simulator, another GPX file, playback speed, update interval or point count.

## Build and test

```sh
# Build the app and its embedded widget
xcodebuild build -project OpenHikes.xcodeproj -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Unit and integration tests, app and widget
xcodebuild test -project OpenHikes.xcodeproj -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# The standalone shared-package suite
swift test --package-path OpenHikesShared

# Simulator UI automation; --list shows the available tests
Scripts/run-ui-tests.sh --all

# Render, main-thread and resource measurement; writes a markdown report
Scripts/run-performance-tests.sh

# Strict SwiftLint, the same one CI runs; --fix applies what it can correct
Scripts/lint.sh
```

Unit and integration tests use Swift Testing; `OpenHikesUITests` uses XCUITest, because Apple's UI automation and launch metrics are not available through Swift Testing.

`brew install xcbeautify periphery xcode-build-server` installs the optional tooling. None of it is required: each tool is used if present and skipped if not. `xcode-build-server` is per-machine — run `xcode-build-server config -project OpenHikes.xcodeproj -scheme OpenHikes` locally, and again after adding or renaming a target.

CI runs strict SwiftLint, the shared package suite in both debug and release, the app and widget unit tests with a coverage floor, warning-free debug and release builds, an unsigned device archive, the concurrency suites under Thread Sanitizer, and both accessibility UI classes. CodeQL and a dependency review run beside it. The functional UI automation and the performance suite stay out, because both lean on real gestures and timing-sensitive waits that a shared runner makes slow and flaky — run them locally before a change that touches recording, the map or render isolation.

## Documentation

- [`AGENTS.md`](AGENTS.md) and [`.github/copilot-instructions.md`](.github/copilot-instructions.md) — the architecture, the conventions, the energy policies, and the decisions already settled.
- [`CONTRIBUTING.md`](docs/CONTRIBUTING.md) — the short version for a first change.
- [`PERFORMANCE.md`](docs/PERFORMANCE.md) — what the app costs in frames and in battery, and how that was measured.
- [`SECURITY.md`](SECURITY.md) — how to report a vulnerability privately.
- [Issues](https://github.com/ZsomborRajki/OpenHikes/issues) — the open work: bugs, missing features, and product decisions that are still open.

## Project layout

Following Apple's [Food Truck](https://github.com/apple/sample-food-truck) and [Backyard Birds](https://github.com/apple/sample-backyard-birds) samples, app source is organized by product domain rather than by generic `Managers`, `Models` and `Views` layers. `OpenHikesModel` is the composition root injected into the SwiftUI environment; feature-specific state and behaviour stay in their domain folders.

| Path | Purpose |
|---|---|
| `OpenHikes/App/` | App entry point, shared app model, configuration, deep-link routing, root navigation. |
| `OpenHikes/Hikes/` | Persisted hike model, GPX import and export, route profile, statistics, hike screens. |
| `OpenHikes/Recording/` | Live recording, recovery journal, sensors, trail matching, recording UI. |
| `OpenHikes/Map/` | MapKit bridge, map state, search, location tracking, map rendering. |
| `OpenHikes/Tiles/` | Tile provider policy, cache, auto-save, offline downloads, overlay rendering. |
| `OpenHikes/Photos/` | Capture and import, library discovery and time-to-place matching, the file store, trail anchoring, gallery, viewer and map pins. |
| `OpenHikes/Sync/` | iCloud sync status and control, and the settings key-value mirror. |
| `OpenHikes/Weather/` | WeatherKit polling, the badge over the map and its detail sheet, unit formatting, and Apple Weather attribution. |
| `OpenHikes/Purchases/` | Paid-maps entitlement and its StoreKit state, the paywall, and the subscription terms and links. |
| `OpenHikes/Settings/` | User-facing app, recording, map and storage settings. |
| `OpenHikes/LiveActivity/` | When a Lock Screen activity starts, updates and ends, behind a seam that keeps ActivityKit out of the tests. |
| `OpenHikes/General/` | Cross-domain extensions and diagnostics. |
| `OpenHikesShared/` | Domain-foldered local Swift package shared by the app and widget. |
| `OpenWidget/` | iOS Home Screen widget and the Live Activity's Lock Screen and Dynamic Island views. |
| `OpenHikesTests/`, `OpenWidgetTests/` | App-hosted tests mirroring the app's domain folders. |
| `OpenHikesUITests/` | Simulator UI automation, location spoofing, launch metrics. |
| `ci_scripts/` | Xcode Cloud hooks, run automatically by name. |

## License

OpenHikes is released under the [MIT License](LICENSE).

That covers the source in this repository only. Map data and map tiles are not ours to license: OpenStreetMap data is © OpenStreetMap contributors and is published under the [Open Database License](https://www.openstreetmap.org/copyright), and the Stadia Maps and Thunderforest styles are used under their own terms. The app displays the credit each provider requires, which `OpenHikes/Tiles/TileAttribution.swift` is responsible for and its tests enforce. A fork that changes tile providers, or that redistributes cached tiles, takes on those obligations itself.

Dependencies: `swift-algorithms`, `swift-collections` and `swift-async-algorithms` are Apache-2.0 licensed and ship inside the app; SwiftLint is a build-time plugin and is not linked into the binary.

## Contact

For feedback and suggestions, email [zsombor.rajki@gmail.com](mailto:zsombor.rajki@gmail.com) or visit the [OpenHikes project on GitHub](https://github.com/ZsomborRajki/OpenHikes).
