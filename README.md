# OpenHikes

OpenHikes is a local-first SwiftUI and SwiftData trail viewer for iPhone. It imports GPX tracks, displays them on a MapKit map, provides route statistics and an interactive elevation profile, and keeps selected map areas available offline.

## Features

- GPX import with track metadata, route statistics, elevation chart scrubbing, route styling, and direction chevrons. A downloaded `.gpx` file opens straight into the app from Files, AirDrop, or any share sheet, as well as through the in-app document picker.
- GPX export from a hike's detail view: the Share button hands the route, its elevations, its fix times, and its metadata to any share destination as a GPX 1.1 file, serialized off the main thread only once a destination is picked.
- Live hike recording with balanced location accuracy, background location, pause/resume, crash-safe recovery, motion-aware fix handling, barometric elevation fusion, and one-time SwiftData save.
- Bounded live trail matching from an extending cached OpenStreetMap walking graph, and a post-recording review where every section the matcher moved or found ambiguous can be kept as the mapped trail, handed back to the raw GPS trace, or swapped for an alternative route; unavailable matches preserve the GPS trace.
- Search across saved hikes and MapKit place suggestions.
- OpenStreetMap, Stadia Outdoors, and Thunderforest Outdoors tile providers, plus an Apple Maps option that draws MapKit's own base map and starts none of the tile pipeline — no fetching, no caching, no auto-save, no bulk download.
- Live location, trail auto-follow with a progress readout, and current WeatherKit conditions.
- Photos taken on a walk or picked from the library, pinned to where on the trail they were taken, shown as a gallery strip on the hike and as pins on the map, with an optional copy saved to the photo library.
- Passive tile auto-save for browsed areas, plus bulk offline downloads where the provider permits them.
- An iOS Home Screen widget with trail progress, a climb/descent/high-point stat line, live-recording takeover, recording deep links, and sparse location anchors that help repair degraded GPS gaps.
- Hikes and their photos sync across the walker's own devices through their private iCloud database, with the tile cache deliberately left out of it.
- Local SwiftData and App Group storage; OpenHikes has no backend and no account of its own.

## Requirements

- Xcode 26.5 or later.
- iOS 26.5. Every target ships iPhone-only (`TARGETED_DEVICE_FAMILY = 1`); the
  sources still carry their `canImport(AppKit)` and `#if os(iOS)` guards, but
  no iPad, Mac or visionOS destination is built or tested.
- An Apple development team that can sign the WeatherKit entitlement, the shared App Group, the iCloud container and the push entitlement.

OpenStreetMap is the keyless default, and Apple Maps needs no key either. Stadia and Thunderforest require build-time API keys.

## Setup

1. Open `OpenHikes.xcodeproj`.
2. Set your development team for `OpenHikes` and `OpenWidgetExtension`.
3. If your team cannot use `group.tappium.com.OpenHikes`, replace it in both entitlement files and in `SharedStore.appGroupID`.
4. iCloud sync needs a CloudKit container. Xcode creates `iCloud.tappium.com.OpenHikes` on the first signed build; if your team cannot use that identifier, replace it in `OpenHikes/OpenHikes.entitlements` and in `CloudSyncSchema.containerIdentifier`. The app creates its own record types on first write, so there is nothing to configure in the CloudKit dashboard for development.
5. Optionally enable Stadia or Thunderforest:

   ```sh
   cp Secrets.example.plist OpenHikes/Secrets.plist
   ```

   Add your keys to the copied file. `OpenHikes/Secrets.plist` is gitignored and must never be committed; unavailable providers remain disabled in Settings.

6. Build and run. For simulated location features, use Xcode's location controls or the recording demo below.

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
| `SettingsUITests` | Provider policy (no bulk download on OpenStreetMap, no tile controls at all on Apple Maps), toggles that must hold their value across a reopen, and the field-report list, export sheet and delete. |
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
reviewer, and because all but two of their tests are launch, tap and assert
against an in-memory store with no location and no measurement. That job is `continue-on-error` for now: UI
automation on a shared runner has to demonstrate a flake rate before it is
allowed to block a merge. The functional UI automation and the performance
suite stay out — both lean harder on real gestures and timing-sensitive waits.
Run those locally with `Scripts/run-ui-tests.sh` and
`Scripts/run-performance-tests.sh` before a change that touches recording, the
map, or render isolation.

`PerformanceUITests` measures rather than asserts correctness: it drives the app
through eight scenarios — idle, map-browsing, offline browsing, chart-scrub,
live and backgrounded recording, the photo gallery, and launch and steady-state
resources — while the
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
| `OpenHikes/Sync/` | CloudKit sync engine, record mapping, and the settings key-value mirror. |
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

## iCloud sync

Hikes follow the walker rather than the phone. There is no OpenHikes account
and no server: everything travels through the user's own private CloudKit
database, so the app never sees it and nobody has to sign up for anything.

| Travels | Stays on the device |
|---|---|
| Hike title, custom name, date, distance, style, symbol, auto-follow and GPX metadata | Auto-saved and offline tiles, and the download records that describe them |
| The matched route and the raw GPS trace | Whether tile auto-save is on for a hike |
| Surface and difficulty breakdowns | A recording in progress |
| Photos — pixels and trail anchor alike | Whether Background Trail Tracking is on |
| Map tile provider, and the save-to-photo-library switch | Which hike this device has selected, and where it is along it |

Tiles are the reason this uses `CKSyncEngine` rather than SwiftData's CloudKit
mirroring. Mirroring syncs a whole row with no way to hold a column back, and
half of `Hike` describes files in *this* device's Application Support — a
second device restoring them would believe it holds offline maps it never
downloaded, bill the user for phantom bytes on the storage screen, and free
nothing when they deleted them. `HikeSyncPayload` is the single readable list
of what leaves the device. SwiftData's own mirroring is switched off
explicitly, in `ModelConfiguration+OpenHikes.swift`, because the iCloud
entitlement would otherwise turn it on by itself.

Settings ride separately, on `NSUbiquitousKeyValueStore`, because two
preferences do not need a record type and a conflict policy. The list is an
allowlist: a setting that describes *this* device — a granted location
permission, where this phone is in the app — deliberately does not travel.

Sync is on by default and can be turned off in Settings, where the same section
says what it is doing and, when it isn't, why. Turning it off stops the engine
and forgets its change token; it never deletes a hike. Neither does a zone
deleted from iCloud settings: the library is simply uploaded again.

Photos travel as their own records, keyed by photo, so adding one picture does
not re-upload the other twenty. Routes travel compressed, inline under 400 KB
and as a `CKAsset` above it.

Two kinds of local change cannot be re-derived by looking at the device later,
so both are written down the moment they happen rather than only queued with
the engine. A **deletion** leaves nothing behind that a later scan could notice
is missing, while iCloud still holds a copy that the next fetch would bring
back — so its tombstone even outlives turning sync off, which is what stops a
hike deleted in that state from reappearing when it is turned on again. An
**edit** to a hike iCloud already knows about is invisible to reconciliation,
which only asks whether a record exists. Both matter because the engine is not
up for the first moments of a launch: it waits on an iCloud account check
first. Going the other way, a fetched change is offered exactly once, so one
whose write to SwiftData fails is held on disk and retried rather than logged
and lost.

## Current limitations

- Offline trail matching is limited to Overpass graph regions that were cached previously; prebuilt regional graph bundles are not shipped.
- iCloud sync carries hikes, their metadata and their photos; downloaded map tiles stay on the device that downloaded them, by design.
- The Simulator cannot receive CloudKit push notifications, so a second simulator only picks up changes when it is brought to the foreground.
- The SwiftData store is not migrated across schema changes.
- Third-party tile keys can only be supplied at build time.
