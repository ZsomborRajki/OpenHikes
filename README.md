# OpenHikes

[![Download on the App Store](docs/images/app-store-badge.svg)](https://apps.apple.com/app/openhikes/id6787467479)

OpenHikes is a local-first hiking app for iPhone and Apple Watch, built with SwiftUI, SwiftData and MapKit. Record a hike, import a GPX file or draw a trail, then walk it, read its elevation profile and keep its map for when there is no signal.

There is no OpenHikes account and no server holding your hikes: they live on the device and sync through your own private iCloud database. The one exception is sharing a hike, which publishes it to a public database that other hikers browse. [The privacy policy](https://zsomborrajki.github.io/OpenHikes/privacy/) says exactly what that sends.

## Features

- **Recording** in the background, with pause and resume, crash recovery and barometric elevation. The track is matched to OpenStreetMap's paths, and any stretch the matcher moved waits for your review before the hike is saved.
- **GPX import and export**: open files from Files, AirDrop or any share sheet, one hike per track, and share any hike back as GPX, with its places as waypoints.
- **Drawing a trail**: press and hold to drop stops, or search for them by name. Each leg follows the paths OpenStreetMap has mapped.
- **Places** along a trail: huts, springs and waterfalls from OpenStreetMap, or places of your own, with your photographs and, where OpenStreetMap links one, the start of the place's Wikipedia article.
- **Walking a saved trail**, with progress along it, a history of past walks and a shareable photo card.
- **Statistics**: an interactive elevation profile, overall and moving average speed, surface and Swiss Alpine Club difficulty from OpenStreetMap, and yearly and all-time totals.
- **Maps**: OpenStreetMap, Apple's standard and satellite maps, Stadia Outdoors, Stamen Terrain and Thunderforest Outdoors, with an optional Waymarked Trails layer and every hike in your library drawn faintly on top. Tiles you browse are saved as you go, and a route's map can be downloaded where the provider allows it.
- **Photos** taken on a walk or picked from the library, pinned to where on the trail they were taken.
- **Weather** from WeatherKit: now, the next twelve hours and the week ahead.
- **Widget and Live Activity**: the trail, or the recording in progress, on the Home Screen, the Lock Screen and in the Dynamic Island.
- **Siri and Shortcuts** start, pause, resume and stop a recording, and a Control Center toggle starts and stops one.
- **Apple Watch**: follow a trail from the wrist, drive the phone's recording, or record on the watch alone.
- **iCloud sync** across your devices, through your private CloudKit database. Photo files and saved map tiles stay on the device that made them.
- **Health**: a finished hike can be saved as a workout, behind a switch that starts off.
- **Community**: browse what others published, with no account needed, and publish your own, which a person reviews before anyone else sees it. Waymarked routes from OpenStreetMap, with photos from Wikimedia Commons, fill the same list.
- **English and German**, following the device's language.

**OpenHikes Pro**, a monthly subscription, unlocks the paid map styles (Stadia Outdoors, Stamen Terrain and Thunderforest Outdoors), offline Stadia maps (Thunderforest's can't be downloaded ahead) and Stadia elevation for trails that have none. Everything else is free, the community included.

## Requirements

- Xcode 27 or later. The app deploys to iOS 18.4 on iPhone, and its embedded watch app to watchOS 11.0.
- An Apple development team that can sign WeatherKit, both App Groups, the iCloud container, push and Time Sensitive Notifications, and HealthKit.
- Optionally, API keys for Stadia and Thunderforest, each with a paid plan from its vendor. OpenStreetMap and Apple's maps need no key, and a build without keys shows the paid styles locked.

## Setup

1. Open `OpenHikes.xcodeproj` and set your team on the four shipping targets: `OpenHikes`, `OpenWidgetExtension`, `OpenHikesWatch` and `OpenHikesWatchWidgets`. On a team other than the project's, also replace the `tappium.com.OpenHikes` prefix of their bundle identifiers and of `WKCompanionAppBundleIdentifier` in `OpenHikesWatch/Info.plist`.
2. Enable WeatherKit for the app's App ID under both **App Services** and **App Capabilities** in Certificates, Identifiers & Profiles, then refresh signing. Until then WeatherKit answers HTTP 401.
3. If your team can't use the two App Groups, replace each one in its entitlements and its constant. A mismatch fails silently, leaving the widget or the complication nothing to draw.
   - `group.tappium.com.OpenHikes` (app and widget): `OpenHikes/OpenHikes.entitlements`, `OpenWidgetExtension.entitlements` and `SharedStore.appGroupID`
   - `group.tappium.com.OpenHikes.watch` (watch and complication): `OpenHikesWatch/OpenHikesWatch.entitlements`, `OpenHikesWatchWidgets/OpenHikesWatchWidgets.entitlements` and `WatchGlanceStore.appGroupID`
4. Xcode creates the iCloud container, `iCloud.tappium.com.OpenHikes`, on the first signed build, and SwiftData creates its development schema on first run. To use another container, replace it in `OpenHikes/OpenHikes.entitlements` and `CloudSyncCoordinator.containerIdentifier`.
5. For the paid map styles, `cp Secrets.example.plist OpenHikes/Secrets.plist` and add your keys. The copy is gitignored and must never be committed.
6. Build and run. The shared scheme runs against `OpenHikes.storekit`, so the Pro paywall works locally with no App Store Connect setup.

HealthKit and Time Sensitive Notifications need a portal step only if signing refuses them. Without the Time Sensitive entitlement, the severe-weather and off-trail warnings arrive at the ordinary level, which Focus silences. Keep your team's identifiers out of pull requests. Shipping Pro needs a matching subscription in App Store Connect and a Paid Apps agreement; *Platform contracts* in [`AGENTS.md`](AGENTS.md) has the rules.

## Recording demo

On a booted simulator, tap the record button on the map (*Record a hike*, under *Make a trail*) and replay the bundled Thumsee route:

```sh
Scripts/simulate-hike.sh start              # ~1.7 km accelerated preview
Scripts/simulate-hike.sh --full --speed 4   # the complete 9.3 km route
Scripts/simulate-hike.sh stop               # stop and clear location playback
```

`--help` lists the options for another simulator, route, speed, interval or point count.

## Build and test

```sh
# The app with its widget and watch app; a generic destination needs no simulator
xcodebuild build -project OpenHikes.xcodeproj -scheme OpenHikes \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData

# Strict SwiftLint, as CI runs it (--fix corrects what it can)
Scripts/lint.sh
```

The tests, the optional tools and what CI runs are under *Build and test* in [`AGENTS.md`](AGENTS.md), with each command written the way CI runs it.

## Documentation

- [`AGENTS.md`](AGENTS.md): how code is written here, with the commands, the architecture and the decisions already settled.
- [`CONTRIBUTING.md`](CONTRIBUTING.md): the short path to a first change.
- [`SECURITY.md`](SECURITY.md): reporting a vulnerability, and what the public community database grants to whom.
- [`Screenshots/README.md`](Screenshots/README.md): the App Store screenshot set.
- [Issues](https://github.com/ZsomborRajki/OpenHikes/issues): the open work.

## Project layout

| Path | What it holds |
|---|---|
| `OpenHikes/` | The iPhone app, one folder per product domain (`Hikes/`, `Recording/`, `Map/`, `Tiles/`, `Community/`…), with `App/` as the composition root |
| `OpenHikesData/` | A local package: what a hike is, with the SwiftData models, the schema and the route index |
| `OpenHikesShared/` | A local package compiled by the app, the widget and the watch |
| `OpenWidget/` | The Home Screen widget, the Live Activity and the Control Center toggle |
| `OpenHikesWatch/`, `OpenHikesWatchWidgets/` | The watch app, and its complication and Smart Stack widget |
| `OpenHikesTests/`, `OpenWidgetTests/` | App-hosted unit tests, in folders that mirror the app's |
| `OpenHikesUITests/` | UI automation |
| `Scripts/` | Lint, the test runners, the simulated hike, the screenshot capture and the gates CI runs |
| `Screenshots/` | The App Store screenshot set |
| `docs/` | The GitHub Pages site: the home, privacy, terms and support pages |

## License

The source is released under the [MIT License](LICENSE). The data and imagery the app shows are not ours to license:

- OpenStreetMap data is © OpenStreetMap contributors, under the [Open Database License](https://www.openstreetmap.org/copyright).
- The Stadia Maps and Thunderforest styles are used under their own terms, and the Waymarked Trails layer under CC BY-SA 3.0 DE.
- Wikimedia Commons photographs are shown under the licence each one names, with its credit. The Wikipedia text on a place's card is CC BY-SA 4.0, linked to its article, and is never stored or shared.

The app displays the credit each provider requires (`OpenHikes/Tiles/TileAttribution.swift`). A fork that changes tile providers, or redistributes cached tiles, takes on those obligations itself.

The app ships `swift-algorithms`, `swift-collections` and `swift-async-algorithms`, all Apache-2.0; `swift-numerics`, also Apache-2.0, reaches it only through `swift-algorithms`. SwiftLint runs at build time and is not linked.

## Contact

For feedback and suggestions, email [zsombor.rajki@gmail.com](mailto:zsombor.rajki@gmail.com) or open an [issue](https://github.com/ZsomborRajki/OpenHikes/issues).
