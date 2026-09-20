# OpenHikes

OpenHikes is a local-first SwiftUI and SwiftData trail viewer for iPhone, with a companion app for Apple Watch. It imports GPX tracks, records live hikes, displays them on a MapKit map, provides route statistics and an interactive elevation profile, and keeps selected map areas available offline.

That is local-first with one deliberate exception. There is no OpenHikes account and no server holding your hikes: everything lives on the device, and what syncs travels through the hiker's own private iCloud database. The exception is sharing a hike, which publishes it to a public CloudKit database other people browse. `OpenHikes/PrivacyInfo.xcprivacy` and [the privacy policy](https://zsomborrajki.github.io/OpenHikes/privacy/) describe exactly what that sends.

## Features

- **GPX import and export.** A downloaded `.gpx` opens straight into the app from Files, AirDrop or any share sheet, with track metadata, route statistics — overall and moving-time average speed side by side, so a long lunch stop does not read as a slow walk — elevation-chart scrubbing, route styling and direction chevrons. The Share button hands a hike back out as GPX 1.1.
- **Live recording.** Background location, pause and resume, crash-safe recovery, motion-aware fix handling and barometric elevation fusion.
- **Recording controls.** Start, pause, resume, stop and check a recording through Siri, Shortcuts or Spotlight, plus a state-aware start/stop control in Control Center.
- **Trail matching and review.** Bounded live matching against a cached OpenStreetMap walking graph, then a post-recording review where every section the matcher moved or found ambiguous can be kept, handed back to the raw GPS trace, or swapped for an alternative.
- **Walking a trail.** A saved hike can be walked as well as read. Following one accrues the coverage of its route as the walk goes, pauses and resumes with it, and ends in a summary — coverage, active time, the furthest point reached — that stays in that hike's own History.
- **Surface and difficulty.** What OpenStreetMap knows about a route underfoot, and how demanding it is, folded into the handful of categories a hiker plans around: the Swiss Alpine Club's six grades and a short surface vocabulary. Measured once, the first time a hike is opened, and simply absent when the map has nothing to say about that valley.
- **Maps.** OpenStreetMap, Stadia Outdoors and Thunderforest Outdoors tile providers, plus an Apple Maps option that draws MapKit's own base map. Passive tile auto-save for browsed areas, and bulk offline downloads where the provider's terms permit them.
- **Photos.** Pictures taken on a walk or picked from the library, pinned to where on the trail they were taken, shown as a gallery strip and as map pins. Photos taken with the system camera during a recording are found afterwards and matched against the recording's own timestamps. Granting access to only some photos is handled rather than treated as a refusal.
- **Live context.** Current location, trail auto-follow with a progress readout, and search across saved hikes and MapKit place suggestions. WeatherKit conditions sit over the map as a badge that opens the current reading and the next twelve hours in full; temperatures, speeds, distances and elevations are spelled in the units the reader's own locale uses.
- **Home Screen widget.** Trail progress, a climb/descent/high-point stat line, live-recording takeover, recording deep links, and sparse location anchors that help repair degraded GPS gaps.
- **Live Activity.** The same figures on the Lock Screen and in the Dynamic Island while a recording runs or a trail is being followed, ticking their own clock so a walk costs no updates while it is simply going well.
- **Apple Watch.** A trail imported on the phone is sent to the watch and walked from the wrist: the route drawn as a line, how far along you are, how much is left, and how far off the trail you have wandered — matched on the watch itself, so it keeps working with the phone in a rucksack or out of range. A hike recorded on the phone shows on the watch as it runs, and pauses, resumes and stops from there; the phone stays the one thing that owns that recording, and the watch drives it through the same controls Siri and Control Center use. The watch also records a hike entirely on its own, with a workout session keeping it running through a six-hour walk and the screen dark, and hands the finished walk to the phone when it is next in range. A walk that cannot be sent yet waits on the watch until it can.
- **iCloud sync.** Hikes and their metadata follow the hiker across their own devices, through their own private CloudKit database. Photo files and the tile cache stay on the device that produced them.
- **Health.** A finished hike is written into the hiker's own Health store as a workout, behind a switch that is off until they turn it on. The app only ever writes: it asks for no read access at all.
- **Community hikes.** Shared hikes are found by panning the map and asking, or by typing a name, and are drawn as lines rather than only as pins. Opening one shows the same statistics a hike of your own gets; saving it copies its route and photographs into your library. Publishing your own is free and is reviewed by a person before anyone else can see it; every published hike can be reported or its author blocked, and a hiker can ask for their own to be taken down. Browsing needs no account. Photographs travel the other way too: pictures brought back from a trail somebody else published — or from a waymarked OpenStreetMap route, which has none of its own — can be offered to it, are reviewed the same way a hike is, and carry the name of whoever took them. Saving such a hike brings the contributed photographs home with it.
- **Waymarked trails from OpenStreetMap.** The same list also offers the signposted routes OpenStreetMap already knows about nearby, so it has something in it before anyone has published anything. They carry what a signpost carries and a stranger's upload cannot — the blaze to follow, whether it loops back to the car, and the two places it runs between — and they are marked as coming from OpenStreetMap rather than from a person: there is no author to credit or block, no photographs, and a link to the route's own page for anyone who wants to correct it. Long-distance paths are left out; what is offered is the length of a day.

## Requirements

- Xcode 26.5 or later — development is on Xcode 27. Every target deploys to
  iOS 26.0, which is also what `OpenHikesShared/Package.swift` declares; CI
  builds on Xcode 26.6.
- An Apple development team that can sign the WeatherKit entitlement, the shared App Group, the iCloud container, the push and Time Sensitive Notifications entitlements and HealthKit.
- iPhone, plus an optional Apple Watch app. The phone targets set
  `TARGETED_DEVICE_FAMILY = 1`; `OpenHikesWatch` sets `4` and deploys to
  watchOS 26.0. The watch app is embedded in the phone app, so building the
  `OpenHikes` scheme builds it too.

OpenStreetMap is the keyless default and Apple Maps needs no key either. Stadia and Thunderforest require build-time API keys *and* a paid subscription with each vendor, whose terms forbid using them free of charge in a shipping app — in OpenHikes they sit behind a monthly subscription, OpenHikes Pro, which is what pays for them, along with saving a whole route's Stadia map for offline use — Thunderforest's licence reserves pre-caching for a plan this app is not on. Everything else in the app, the community feature included, is free. A build without keys shows them locked, and OpenStreetMap keeps working.

## Setup

1. Open `OpenHikes.xcodeproj` and set your development team for `OpenHikes`, `OpenWidgetExtension` and `OpenHikesWatch`.
2. Enable WeatherKit for the app's App ID in Certificates, Identifiers & Profiles, in both **App Services** and **App Capabilities**, then refresh its signing assets. The capability and entitlement are checked in, but Apple still returns HTTP 401 until the App ID itself is enabled.
3. If your team cannot use `group.tappium.com.OpenHikes`, replace it in both entitlement files and in `SharedStore.appGroupID`.
4. HealthKit needs no portal step in the ordinary case: the capability and both usage strings are checked in, and the App ID picks it up when Xcode refreshes signing assets. Enable it by hand in **App Capabilities** if signing refuses. The app only ever *writes* a finished hike into the hiker's own store — `HealthKitWorkoutWriter` asks for share types and no read types — and the switch is off until they turn it on.
5. Time Sensitive Notifications needs no portal step in the ordinary case either, and the entitlement is checked in. Without it the two warnings the app can send — a severe-weather alert and leaving the trail — are delivered at the ordinary level, which any Focus mode silences; nothing reports that, so the symptom is a warning a hiker never sees.
6. iCloud sync needs a CloudKit container. Xcode creates `iCloud.tappium.com.OpenHikes` on the first signed build; to use another identifier, replace it in `OpenHikes/OpenHikes.entitlements` and in `CloudSyncCoordinator.containerIdentifier`. SwiftData's mirroring creates the development schema from the model on first run.
7. Optionally enable Stadia or Thunderforest:

   ```sh
   cp Secrets.example.plist OpenHikes/Secrets.plist
   ```

   Add your keys to the copied file. `OpenHikes/Secrets.plist` is gitignored and must never be committed; unavailable providers stay disabled in Settings.

8. Build and run. `OpenHikes.storekit` at the repository root describes the OpenHikes Pro subscription and the shared scheme already points its Run action at it, so a local build has a working paywall with no Apple account involved.

Shipping the subscription for real additionally needs a matching auto-renewable subscription in App Store Connect and an active Paid Apps agreement; `.github/copilot-instructions.md` carries the exact contract, including the product ID that can never change.

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
# Boot the simulator first — the test commands below need it awake
xcrun simctl boot "iPhone 18 Pro" || true
xcrun simctl bootstatus "iPhone 18 Pro" -b

# Build the app, its embedded widget and the watch app. The watch target is a
# dependency of the app, so this compiles it for watchOS as well — there is no
# separate build to remember, and no way to break it without breaking this.
xcodebuild build -project OpenHikes.xcodeproj -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'

# The watch app on its own, which is the faster loop while working on it
xcodebuild build -project OpenHikes.xcodeproj -scheme OpenHikesWatch \
  -destination 'generic/platform=watchOS Simulator'

# Unit and integration tests, app and widget
xcodebuild test -project OpenHikes.xcodeproj -scheme OpenHikes \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:OpenHikesTests -only-testing:OpenWidgetTests

# The standalone shared-package suite
swift test --package-path OpenHikesShared

# Simulator UI automation, across three simulator clones; --serial for one,
# and --list shows the available tests. A second run on the same machine needs
# its own of both: --device <name|udid> and --derived-data <path>
Scripts/run-ui-tests.sh --all

# Strict SwiftLint, the same one CI runs; --fix applies what it can correct
Scripts/lint.sh

# The shell scripts' own tests, against stubbed xcrun/xcodebuild — nothing is
# built and no simulator is touched. CI runs this one too.
Scripts/run-script-tests.sh
```

Against a cold simulator, `xcodebuild test` fails with "The test runner hung before establishing connection" after several minutes without a single test having reported — which is why the boot is the first line above rather than an optional one.

The device name is the one thing these commands do not share with CI. `iPhone 18 Pro` is the Pro model an iOS 27 runtime ships, so an Xcode 26 install has no such simulator: name whichever device your own runtimes do have, which is what `.github/workflows/ci.yml` does when it pins `iPhone 17 Pro` for its Xcode 26.6 runner image.

Unit and integration tests use Swift Testing; `OpenHikesUITests` uses XCUITest, because Apple's UI automation and launch metrics are not available through Swift Testing.

`brew install xcbeautify periphery xcode-build-server` installs the optional tooling. None of it is required: each tool is used if present and skipped if not. `periphery` has to be the version in `.periphery-version` or newer — run it through `Scripts/periphery.sh`, which checks that first, because an older Periphery reads none of `.periphery.yml` and reports a clean scan anyway. `xcode-build-server` is per-machine — run `xcode-build-server config -project OpenHikes.xcodeproj -scheme OpenHikes` locally, and again after adding or renaming a target.

CI runs strict SwiftLint, the shell scripts' own smoke tests, the shared package suite in both debug and release, the app and widget unit tests with a coverage floor, warning-free debug and release builds, an unsigned device archive, the concurrency suites under Thread Sanitizer, and both accessibility UI classes. CodeQL and a dependency review run beside it. The functional UI automation stays out, because it leans on real gestures and timing-sensitive waits that a shared runner makes slow and flaky — run it locally before a change that touches recording, the map or render isolation.

## Documentation

- [`AGENTS.md`](AGENTS.md) and [`.github/copilot-instructions.md`](.github/copilot-instructions.md) — the architecture, the conventions, the energy policies, and the decisions already settled.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — the short version for a first change.
- [`SECURITY.md`](SECURITY.md) — how to report a vulnerability privately, and what the public community database grants to whom.
- [`Screenshots/README.md`](Screenshots/README.md) — capturing the App Store screenshot set, and the route and photographs the frames are built from.
- [`APP_REVIEW.md`](APP_REVIEW.md) — the notes the App Store listing carries for its reviewer, including why the app asks for background location.
- [Issues](https://github.com/ZsomborRajki/OpenHikes/issues) — the open work: bugs, missing features, and product decisions that are still open.

## Project layout

Following Apple's [Food Truck](https://github.com/apple/sample-food-truck) and [Backyard Birds](https://github.com/apple/sample-backyard-birds) samples, app source is organized by product domain rather than by generic `Managers`, `Models` and `Views` layers. `OpenHikesModel` is the composition root injected into the SwiftUI environment; feature-specific state and behaviour stay in their domain folders.

| Path | Purpose |
|---|---|
| `OpenHikes/App/` | App entry point, shared app model, configuration, deep-link routing, root navigation. |
| `OpenHikes/Hikes/` | Persisted hike model, GPX import and export, route profile, statistics, the surface and difficulty breakdowns, walks along a saved trail and their history, hike screens. |
| `OpenHikes/Recording/` | Live recording, recovery journal, sensors, trail matching, recording UI. |
| `OpenHikes/Map/` | MapKit bridge, map state, search, location tracking, map rendering. |
| `OpenHikes/Tiles/` | Tile provider policy, cache, auto-save, offline downloads, overlay rendering. |
| `OpenHikes/Community/` | Publishing a hike to the public database, browsing and searching what other people published, the waymarked routes fetched from OpenStreetMap that fill the same list, the map's lines and pins for both, importing one, offering photographs to a trail that is already public, reviewing what is waiting, reporting and blocking. |
| `OpenHikes/Photos/` | Capture and import, library discovery and time-to-place matching, the file store, trail anchoring, gallery, viewer and map pins. |
| `OpenHikes/Health/` | Writing a finished hike into the hiker's own Health store, behind a switch and behind a seam that keeps HealthKit out of the tests. |
| `OpenHikes/Sync/` | iCloud sync status and control, and the settings key-value mirror. |
| `OpenHikes/Weather/` | WeatherKit polling, the badge over the map and its detail sheet, unit formatting, and Apple Weather attribution. |
| `OpenHikes/Purchases/` | The Pro entitlement and its StoreKit state, the paywall, and the subscription terms and links. |
| `OpenHikes/Settings/` | User-facing app, recording, map and storage settings. |
| `OpenHikes/Reminders/` | Noticing that a paused hike has started moving again, or that a running one has stopped, and saying so once. |
| `OpenHikes/LiveActivity/` | When a Lock Screen activity starts, updates and ends, behind a seam that keeps ActivityKit out of the tests. |
| `OpenHikes/Intents/` | App Intents for controlling and querying a recording, the Siri and Spotlight shortcuts they are offered through, and the seam they perform behind. |
| `OpenHikes/General/` | Cross-domain extensions and diagnostics. |
| `OpenHikes/SimulatedLocations/` | The bundled GPX routes the simulated hike and the screenshot capture play back. |
| `OpenHikes/Watch/` | The phone's half of the watch link: sending the hiker's trails and one trail's geometry, and keeping the walks the watch recorded. |
| `OpenHikesShared/` | Domain-foldered local Swift package shared by the app, the widget and the watch. |
| `OpenWidget/` | iOS Home Screen widget and the Live Activity's Lock Screen and Dynamic Island views. |
| `OpenHikesWatch/` | The watchOS app: the link to the phone, the trail being followed, and recording a hike on the watch alone. |
| `OpenHikesTests/`, `OpenWidgetTests/` | App-hosted tests mirroring the app's domain folders. |
| `OpenHikesUITests/` | Simulator UI automation, location spoofing, launch metrics. |
| `Scripts/` | The gates and tools a contributor runs by hand: lint, the UI-test runner, the simulated hike, the App Store screenshot capture and its photo stamper, and the checks CI runs beside them. |
| `Screenshots/` | The App Store screenshot set: what each frame has to say, how it is captured, and where its photographs come from. |
| `docs/` | The published GitHub Pages site — the privacy, terms and support pages the App Store listing links. Not a documentation folder. |
| `ci_scripts/` | Xcode Cloud hooks, run automatically by name. |

## License

OpenHikes is released under the [MIT License](LICENSE).

That covers the source in this repository only. Map data and map tiles are not ours to license: OpenStreetMap data is © OpenStreetMap contributors and is published under the [Open Database License](https://www.openstreetmap.org/copyright), and the Stadia Maps and Thunderforest styles are used under their own terms. The app displays the credit each provider requires, which `OpenHikes/Tiles/TileAttribution.swift` is responsible for and its tests enforce. A fork that changes tile providers, or that redistributes cached tiles, takes on those obligations itself.

Dependencies: `swift-algorithms`, `swift-collections` and `swift-async-algorithms` are Apache-2.0 licensed and ship inside the app; SwiftLint is a build-time plugin and is not linked into the binary.

## Contact

For feedback and suggestions, email [zsombor.rajki@gmail.com](mailto:zsombor.rajki@gmail.com) or visit the [OpenHikes project on GitHub](https://github.com/ZsomborRajki/OpenHikes).
