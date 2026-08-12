# OpenTrails

OpenTrails is a local-first SwiftUI and SwiftData trail viewer for iOS, iPadOS, macOS, and visionOS. It imports GPX tracks, displays them on a MapKit map, provides route statistics and an interactive elevation profile, and keeps selected map areas available offline.

## Features

- GPX import with track metadata, route statistics, elevation chart scrubbing, route styling, and direction chevrons.
- Search across saved hikes and MapKit place suggestions.
- OpenStreetMap, Stadia Outdoors, and Thunderforest Outdoors tile providers.
- Live location, trail auto-follow with a progress readout, and current WeatherKit conditions.
- Passive tile auto-save for browsed areas, plus bulk offline downloads where the provider permits them.
- An iOS Home Screen widget with a pre-rendered basemap, trail progress, deep linking, and optional low-power background updates.
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

5. Build and run. For simulated location features, use Xcode's location controls or `OpenTrails/SimulatedLocations/ThumseeLoopFast.gpx`.

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

swift test --package-path OpenTrailsShared
```

Tests use Swift Testing. There is no separate lint or formatting command.

## Project layout

| Path | Purpose |
|---|---|
| `OpenTrails/` | SwiftUI/SwiftData app, MapKit integration, location, weather, GPX import, and tile storage. |
| `OpenTrailsShared/` | Local Swift package shared by the app and widget. |
| `OpenWidget/` | iOS Home Screen widget. |
| `OpenTrailsTests/` | App-hosted test suite. |

See [`.github/copilot-instructions.md`](.github/copilot-instructions.md) for architecture and repository conventions. See [`CODE_REVIEW.md`](CODE_REVIEW.md) for verified build status, known issues, and remaining engineering work.

## Current limitations

- Live hike recording is not implemented; routes are imported from GPX files.
- Sign in with Apple is a disabled placeholder, and hikes do not sync between devices.
- Third-party tile keys can only be supplied at build time.
- CI, widget-target tests, MapKit integration tests, and several testability seams remain open; details are tracked in `CODE_REVIEW.md`.
