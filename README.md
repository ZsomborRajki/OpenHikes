# OpenTrails

OpenTrails is a local-first SwiftUI and SwiftData trail viewer for iOS, iPadOS, macOS, and visionOS. It imports GPX tracks, displays them on a MapKit map, provides route statistics and an interactive elevation profile, and keeps selected map areas available offline.

## Features

- GPX import with track metadata, route statistics, elevation chart scrubbing, route styling, and direction chevrons.
- Live hike recording with balanced location accuracy, background location, pause/resume, crash-safe recovery, motion-aware fix handling, barometric elevation fusion, and one-time SwiftData save.
- Bounded live trail matching from an extending cached OpenStreetMap walking graph and post-recording A/B/GPS review for ambiguous legs; unavailable matches preserve the GPS trace.
- Search across saved hikes and MapKit place suggestions.
- OpenStreetMap, Stadia Outdoors, and Thunderforest Outdoors tile providers.
- Live location, trail auto-follow with a progress readout, and current WeatherKit conditions.
- Passive tile auto-save for browsed areas, plus bulk offline downloads where the provider permits them.
- An iOS Home Screen widget with trail progress, live-recording takeover, recording deep links, and sparse location anchors that help repair degraded GPS gaps.
- Local SwiftData and App Group storage; OpenTrails has no backend or account sync.

## Requirements

- Xcode 26.5 or later.
- iOS/iPadOS 26.5, macOS 26.5, or visionOS 26.5.
- An Apple development team that can sign the WeatherKit entitlement and the shared App Group.

OpenStreetMap is the keyless default. Stadia and Thunderforest require build-time API keys.

## Setup

1. Open `OpenTrails.xcodeproj`.
2. Set your development team for `OpenTrails` and `OpenWidgetExtension`.
3. If your team cannot use `group.tappium.com.OpenTrails`, replace it in both entitlement files and in `SharedStore.appGroupID`.
4. Optionally enable Stadia or Thunderforest:

   ```sh
   cp Secrets.example.plist OpenTrails/Secrets.plist
   ```

   Add your keys to the copied file. `OpenTrails/Secrets.plist` is gitignored and must never be committed; unavailable providers remain disabled in Settings.

5. Build and run. For simulated location features, use Xcode's location controls or the recording demo below.

## Recording demo

Build and launch OpenTrails on a booted iOS Simulator, open **Record Hike**, and tap **Start Recording**. From the repository root, replay the first 60 points of the bundled Thumsee route:

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
  -project OpenTrails.xcodeproj \
  -scheme OpenTrails \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

xcodebuild test \
  -project OpenTrails.xcodeproj \
  -scheme OpenTrails \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Run simulator UI automation and launch metrics only
xcodebuild test \
  -project OpenTrails.xcodeproj \
  -scheme OpenTrailsUI \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

swift test --package-path OpenTrailsShared
```

Unit and integration tests use Swift Testing. `OpenTrailsUITests` uses
XCTest/XCUITest because Apple's UI automation and launch-performance metrics
are not available through Swift Testing. UI-test launches use an in-memory
SwiftData store and isolated preferences; coverage includes app/settings smoke
navigation, bundled GPX import, programmatic simulator location, recording
startup, and `XCTApplicationLaunchMetric`. There is no separate lint or
formatting command.

## Project layout

Following Apple's [Food Truck](https://github.com/apple/sample-food-truck) and
[Backyard Birds](https://github.com/apple/sample-backyard-birds) samples, app
source is organized by product domain rather than generic `Managers`, `Models`,
and `Views` layers. `OpenTrailsModel` is the composition root injected into the
SwiftUI environment; feature-specific state and behavior remain in their
domain folders.

| Path | Purpose |
|---|---|
| `OpenTrails/App/` | App entry point, shared app model, configuration, deep-link routing, and root navigation. |
| `OpenTrails/Hikes/` | Persisted hike model, GPX import, route profile, statistics, and hike screens. |
| `OpenTrails/Recording/` | Live recording, recovery journal, sensors, trail matching, and recording UI. |
| `OpenTrails/Map/` | MapKit bridge, map state, search, location tracking, and map rendering. |
| `OpenTrails/Tiles/` | Tile provider policy, cache, auto-save, offline downloads, and overlay rendering. |
| `OpenTrails/Weather/` | WeatherKit polling and presentation state. |
| `OpenTrails/Settings/` | User-facing app, recording, map, and storage settings. |
| `OpenTrails/General/` | Cross-domain extensions and diagnostics. |
| `OpenTrailsShared/` | Domain-foldered local Swift package shared by the app and widget. |
| `OpenWidget/` | iOS Home Screen widget. |
| `OpenTrailsTests/` | App-hosted tests mirroring the app's domain folders. |
| `OpenWidgetTests/` | App-hosted tests for the widget's timeline, families, and basemap pairing. |
| `OpenTrailsUITests/` | iOS Simulator UI automation, location spoofing, and launch metrics. |

See [`.github/copilot-instructions.md`](.github/copilot-instructions.md) for architecture and repository conventions. See [`CODE_REVIEW.md`](CODE_REVIEW.md) for verified build status, known issues, and remaining engineering work.

## Current limitations

- Offline trail matching is limited to Overpass graph regions that were cached previously; prebuilt regional graph bundles are not shipped.
- Sign in with Apple is a disabled placeholder, and hikes do not sync between devices.
- Third-party tile keys can only be supplied at build time.
- There is no CI, so the test suites are only as protected as the person running them; details are tracked in `CODE_REVIEW.md`.
