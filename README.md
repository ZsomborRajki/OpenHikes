# OpenHikes

OpenHikes is a local-first SwiftUI and SwiftData trail viewer for iPhone. It imports GPX tracks, records live hikes, displays them on a MapKit map, provides route statistics and an interactive elevation profile, and keeps selected map areas available offline.

There is no backend and no OpenHikes account. Everything lives on the device, and what syncs travels through the walker's own private iCloud database.

## Features

- **GPX import and export.** A downloaded `.gpx` opens straight into the app from Files, AirDrop or any share sheet, with track metadata, route statistics, elevation-chart scrubbing, route styling and direction chevrons. The Share button hands a hike back out as GPX 1.1, serialized off the main thread once a destination is picked.
- **Live recording.** Balanced location accuracy, background location, pause and resume, crash-safe recovery, motion-aware fix handling and barometric elevation fusion, saved to SwiftData once.
- **Trail matching and review.** Bounded live matching against an extending cached OpenStreetMap walking graph, then a post-recording review where every section the matcher moved or found ambiguous can be kept as the mapped trail, handed back to the raw GPS trace, or swapped for an alternative. Unavailable matches preserve the GPS trace.
- **Maps.** OpenStreetMap, Stadia Outdoors and Thunderforest Outdoors tile providers, plus an Apple Maps option that draws MapKit's own base map and starts none of the tile pipeline. Passive tile auto-save for browsed areas, and bulk offline downloads where the provider's terms permit them.
- **Photos.** Pictures taken on a walk or picked from the library, pinned to where on the trail they were taken, shown as a gallery strip and as map pins. Photos taken with the system camera during a recording are found afterwards from the photo library and matched against the recording's own timestamps, corroborated by the photograph's location where it has one.
- **Live context.** Current location, trail auto-follow with a progress readout, WeatherKit conditions, and search across saved hikes and MapKit place suggestions.
- **Home Screen widget.** Trail progress, a climb/descent/high-point stat line, live-recording takeover, recording deep links, and sparse location anchors that help repair degraded GPS gaps.
- **iCloud sync.** Hikes and their metadata follow the walker across their own devices. The tile cache is deliberately left out of it.

## Requirements

- Xcode 26.5 or later, and iOS 26.5.
- An Apple development team that can sign the WeatherKit entitlement, the shared App Group, the iCloud container and the push entitlement.
- iPhone only. Every target sets `TARGETED_DEVICE_FAMILY = 1`; the sources still carry their `canImport(AppKit)` and `#if os(iOS)` guards, but no iPad, Mac or visionOS destination is built or tested.

OpenStreetMap is the keyless default and Apple Maps needs no key either. Stadia and Thunderforest require build-time API keys *and* a paid subscription with each vendor, whose terms forbid using them free of charge in a shipping app — in OpenHikes they sit behind a yearly subscription, which is what pays for them. A build without keys shows them locked, and OpenStreetMap keeps working.

## Setup

1. Open `OpenHikes.xcodeproj` and set your development team for `OpenHikes` and `OpenWidgetExtension`.
2. If your team cannot use `group.tappium.com.OpenHikes`, replace it in both entitlement files and in `SharedStore.appGroupID`.
3. iCloud sync needs a CloudKit container. Xcode creates `iCloud.tappium.com.OpenHikes` on the first signed build; to use another identifier, replace it in `OpenHikes/OpenHikes.entitlements` and in `CloudSyncCoordinator.containerIdentifier`. SwiftData's mirroring creates the development schema from the model on first run, so there is nothing to configure in the CloudKit dashboard until you ship.
4. Optionally enable Stadia or Thunderforest:

   ```sh
   cp Secrets.example.plist OpenHikes/Secrets.plist
   ```

   Add your keys to the copied file. `OpenHikes/Secrets.plist` is gitignored and must never be committed; unavailable providers stay disabled in Settings.

5. Build and run. Nothing else is required — `OpenHikes.storekit` at the repository root describes the paid-maps purchase and the shared scheme already points its Run action at it, so a local build has a working paywall with no Apple account involved.

Shipping the paid maps for real additionally needs an auto-renewable subscription in App Store Connect, in a group named `Pro Maps`, with a yearly duration, a 1-week free-trial introductory offer, and a product ID exactly equal to `MapEntitlementStore.productID`. It also needs an active Paid Apps agreement — without one, `Product.products(for:)` returns nothing and the buy button stays disabled. That product ID is written into every past purchase and can never change without stranding existing customers; it appears in the constant, in `OpenHikes.storekit` and in App Store Connect, and all three have to agree. `MapPurchaseLinks.privacyPolicy` must resolve to a real page before submission, because Guideline 3.1.2(a) requires it and a 404 there fails the binary.

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
Scripts/run-ui-tests.sh --test testReviewsSnappedRouteAfterStopping

# Render, main-thread and resource measurement; writes a markdown report
Scripts/run-performance-tests.sh

# Strict SwiftLint, the same one CI runs; --fix applies what it can correct
Scripts/lint.sh
```

Unit and integration tests use Swift Testing; `OpenHikesUITests` uses XCUITest, because Apple's UI automation and launch metrics are not available through Swift Testing. UI-test launches use an in-memory SwiftData store and isolated preferences.

### Optional tooling

None of these are required to build, test or contribute; each one is used if present and skipped if not.

```sh
brew install xcbeautify periphery xcode-build-server
```

[`xcbeautify`](https://github.com/cpisciotta/xcbeautify) formats `xcodebuild` output. `Scripts/run-ui-tests.sh` and `Scripts/run-performance-tests.sh` use it when it is installed and fall back to their previous `grep` filter when it is not, and CI pipes through it to get compiler diagnostics as inline annotations. It is preinstalled on the `macos-26` runner at the version Homebrew installs, so local and CI output match. Both scripts keep the raw log as well, because xcbeautify does not emit `measured [...]` lines or the performance suite's `PERF-` markers.

[`periphery`](https://github.com/peripheryapp/periphery) reports declarations nothing references any more. `periphery scan` reads the checked-in `.periphery.yml`; it builds the whole project with indexing enabled, so it takes minutes and is deliberately not part of CI. Its output is a list of candidates to read rather than a pass/fail signal.

[`xcode-build-server`](https://github.com/SolaWing/xcode-build-server) lets an editor's `sourcekit-lsp` resolve symbols across the app target rather than only the shared package. It is per-machine — the generated `buildServer.json` records absolute DerivedData paths and is gitignored — so generate it locally, and again after adding or renaming a target:

```sh
xcode-build-server config -project OpenHikes.xcodeproj -scheme OpenHikes
```

CI runs strict SwiftLint, the shared package suite, the app and widget unit tests, warning-free debug and release builds, the concurrent GPX parser under Thread Sanitizer, and both accessibility UI classes. The functional UI automation and the performance suite stay out, because both lean on real gestures and timing-sensitive waits that a shared runner makes slow and flaky — run them locally before a change that touches recording, the map or render isolation.

[`PERFORMANCE.md`](PERFORMANCE.md) records what the app costs in frames and in battery, how that was measured, and what is still open. [`CODE_REVIEW.md`](CODE_REVIEW.md) is the open code-quality list. [`.github/copilot-instructions.md`](.github/copilot-instructions.md) holds the architecture and the repository conventions, including the launch arguments the UI suites use.

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
| `OpenHikes/Weather/` | WeatherKit polling and presentation state. |
| `OpenHikes/Settings/` | User-facing app, recording, map and storage settings. |
| `OpenHikes/General/` | Cross-domain extensions and diagnostics. |
| `OpenHikesShared/` | Domain-foldered local Swift package shared by the app and widget. |
| `OpenWidget/` | iOS Home Screen widget. |
| `OpenHikesTests/`, `OpenWidgetTests/` | App-hosted tests mirroring the app's domain folders. |
| `OpenHikesUITests/` | Simulator UI automation, location spoofing, launch metrics. |
| `ci_scripts/` | Xcode Cloud hooks, run automatically by name. |

## iCloud sync

Hikes follow the walker rather than the phone. There is no OpenHikes account and no server: everything travels through the user's own private CloudKit database, so the app never sees it and nobody has to sign up for anything.

SwiftData does the syncing. `Hike` lives in a store configured with `cloudKitDatabase: .automatic`, and mirroring uploads, downloads, merges and deletes from inside Core Data — there is no queue this app owns, no change token it persists and no record mapping it writes. `OpenHikes/Sync/` is what mirroring does *not* do: report what is happening, and remember whether the user wanted it.

| Travels | Stays on the device |
|---|---|
| Hike title, custom name, date, distance, style, symbol, auto-follow and GPX metadata | Auto-saved and offline tiles, and the download records that describe them |
| The matched route and the raw GPS trace | Whether tile auto-save is on for a hike |
| Surface and difficulty breakdowns | Photo pixels — only a photo's metadata travels |
| Photo metadata, including the trail anchor | Whether Background Trail Tracking is on |
| Map tile provider, and the save-to-photo-library switch | Which hike this device has selected, and where it is along it |

Anything describing files in *this* device's Application Support has to live where the mirror cannot reach, because mirroring syncs a whole row last-writer-wins with no way to hold a column back. That is `HikeLocalState`, a second model in a second unmirrored store. It is not tidiness: the tile claim set is built from exactly those fields, and a second device's inventory overwriting this one's would silently strip this device of offline maps it really had downloaded.

Sync is on by default and can be turned off in Settings, where the same section says what it is doing and, when it isn't, why. A store decides whether it mirrors when it is built, so the switch takes effect on the next launch. Turning it off never deletes a hike. Settings ride separately on `NSUbiquitousKeyValueStore` as an allowlist, so a preference describing *this* device deliberately does not travel.

Letting SwiftData own sync gave up things a hand-written engine had, deliberately:

- **Photo pixels do not travel.** They are files, and mirroring only carries columns. A second device gets a photo's metadata and finds no file behind it.
- **Whole-row uploads.** Renaming a hike re-uploads its routes and photo metadata.
- **No draft filtering.** A recording in progress is a row like any other, so a second device shows a hike whose line is still being drawn.
- **Last-writer-wins.** There is no hook to prefer an unsent local edit.
- **The CloudKit schema is permanent.** It is append-only in production, so a column added to `Hike` cannot later change type or go away.

## Current limitations

- Offline trail matching only covers Overpass graph regions that were cached previously; prebuilt regional graph bundles are not shipped.
- Photo pixels and downloaded map tiles stay on the device that produced them, by design.
- Turning iCloud sync on or off takes effect on the next launch.
- The Simulator cannot receive CloudKit push notifications, so a second simulator only picks up changes when it is brought to the foreground.
- The SwiftData store is not migrated across schema changes.
- Third-party tile keys can only be supplied at build time.
- The app is English-only; there is no string catalog yet.

## License

OpenHikes is released under the [MIT License](LICENSE).

That covers the source in this repository only. Map data and map tiles are not ours to license: OpenStreetMap data is © OpenStreetMap contributors and is published under the [Open Database License](https://www.openstreetmap.org/copyright), and the Stadia Maps and Thunderforest styles are used under their own terms. The app displays the credit each provider requires, which `OpenHikes/Tiles/TileAttribution.swift` is responsible for and its tests enforce. A fork that changes tile providers, or that redistributes cached tiles, takes on those obligations itself.

Dependencies: `swift-algorithms`, `swift-collections` and `swift-async-algorithms` are Apache-2.0 licensed and ship inside the app; SwiftLint is a build-time plugin and is not linked into the binary.

## Contact

For feedback and suggestions, email [zsombor.rajki@gmail.com](mailto:zsombor.rajki@gmail.com) or visit the [OpenHikes project on GitHub](https://github.com/ZsomborRajki/OpenHikes).
