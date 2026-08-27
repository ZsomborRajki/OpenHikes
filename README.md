# OpenHikes

OpenHikes is a local-first SwiftUI and SwiftData trail viewer for iPhone. It imports GPX tracks, displays them on a MapKit map, provides route statistics and an interactive elevation profile, and keeps selected map areas available offline.

## Features

- GPX import with track metadata, route statistics, elevation chart scrubbing, route styling, and direction chevrons. A downloaded `.gpx` file opens straight into the app from Files, AirDrop, or any share sheet, as well as through the in-app document picker.
- GPX export from a hike's detail view: the Share button hands the route, its elevations, its fix times, and its metadata to any share destination as a GPX 1.1 file, serialized off the main thread only once a destination is picked.
- Live hike recording with balanced location accuracy, background location, pause/resume, crash-safe recovery, motion-aware fix handling, barometric elevation fusion, and one-time SwiftData save.
- Bounded live trail matching from an extending cached OpenStreetMap walking graph, and a post-recording review where every section the matcher moved or found ambiguous can be kept as the mapped trail, handed back to the raw GPS trace, or swapped for an alternative route; unavailable matches preserve the GPS trace.
- Search across saved hikes and MapKit place suggestions.
- OpenStreetMap, Stadia Outdoors, and Thunderforest Outdoors tile providers, plus an Apple Maps option that draws MapKit's own base map and starts none of the tile pipeline — no fetching, no caching, no auto-save, no bulk download. Stadia and Thunderforest are commercial sources behind a yearly subscription with a free trial; OpenStreetMap is the default and stays free.
- Live location, trail auto-follow with a progress readout, and current WeatherKit conditions.
- Photos taken on a walk or picked from the library, pinned to where on the trail they were taken, shown as a gallery strip on the hike and as pins on the map, with an optional copy saved to the photo library.
- Pictures taken with the system camera during a recorded hike found afterwards from the photo library and pinned to the point of the trail the walker was on at that moment, matched against the recording's own timestamps and corroborated by the photograph's own location where it has one.
- Passive tile auto-save for browsed areas, plus bulk offline downloads where the provider's terms permit them — today OpenStreetMap and Stadia, the latter under the 100 MB per-device ceiling its licence sets.
- An iOS Home Screen widget with trail progress, a climb/descent/high-point stat line, live-recording takeover, recording deep links, and sparse location anchors that help repair degraded GPS gaps.
- Hikes and their photos sync across the walker's own devices through their private iCloud database, with the tile cache deliberately left out of it.
- Local SwiftData and App Group storage; OpenHikes has no backend and no account of its own.

## Requirements

- Xcode 26.5 or later.
- iOS 26.5. Every target ships iPhone-only (`TARGETED_DEVICE_FAMILY = 1`); the
  sources still carry their `canImport(AppKit)` and `#if os(iOS)` guards, but
  no iPad, Mac or visionOS destination is built or tested.
- An Apple development team that can sign the WeatherKit entitlement, the shared App Group, the iCloud container and the push entitlement.

OpenStreetMap is the keyless default, and Apple Maps needs no key either. Stadia
and Thunderforest require build-time API keys *and* a paid subscription with
each vendor: both are commercial sources whose terms forbid using them
free-of-charge in a shipping app. In OpenHikes they sit behind a yearly
subscription, which is what pays for them — a subscription rather than a single
payment because the vendors bill per map view, every month, for as long as
anyone keeps using them. A build without keys simply shows them
locked, and OpenStreetMap keeps working.

## Setup

1. Open `OpenHikes.xcodeproj`.
2. Set your development team for `OpenHikes` and `OpenWidgetExtension`.
3. If your team cannot use `group.tappium.com.OpenHikes`, replace it in both entitlement files and in `SharedStore.appGroupID`.
4. iCloud sync needs a CloudKit container. Xcode creates `iCloud.tappium.com.OpenHikes` on the first signed build; if your team cannot use that identifier, replace it in `OpenHikes/OpenHikes.entitlements` and in `CloudSyncCoordinator.containerIdentifier`. SwiftData's mirroring creates the development schema from the model on first run, so there is nothing to configure in the CloudKit dashboard until you ship.
5. Optionally enable Stadia or Thunderforest:

   ```sh
   cp Secrets.example.plist OpenHikes/Secrets.plist
   ```

   Add your keys to the copied file. `OpenHikes/Secrets.plist` is gitignored and must never be committed; unavailable providers remain disabled in Settings.

6. The paid maps also need a purchase to unlock them. `OpenHikes.storekit` at the
   repository root describes that purchase, and the shared `OpenHikes` scheme
   already points its Run action at it — so a local build has a working paywall
   with no Apple account involved. Nothing has to be configured to build or
   test; the rest of this step is only for shipping.

   Selling it for real needs an **auto-renewable subscription** in App Store
   Connect (Monetization → Subscriptions) in a group named `Pro Maps`, with a
   yearly duration, a 1-week free-trial introductory offer, and a product ID
   exactly equal to `MapEntitlementStore.productID`. It also needs an active
   Paid Apps agreement under Business → Agreements, Tax, and Banking — without
   one, `Product.products(for:)` returns nothing and the paywall's buy button
   stays disabled. No entitlement or capability is needed; iOS App IDs carry
   In-App Purchase by default.

   Two more things App Review checks. `MapPurchaseLinks.privacyPolicy` has to
   resolve to a real page before submission — it is linked from the paywall
   because Guideline 3.1.2(a) requires it, and a 404 there fails the whole
   binary. And the paywall must keep stating the price, the period and the
   renewal; `MapSubscriptionTermsTests` is what holds that wording in place.

   That product ID is written into every past purchase, so it can never change
   without stranding every existing customer's entitlement — the same rule the
   App Group, CloudKit container and widget kind follow. It appears in three
   places — the constant, `OpenHikes.storekit`, and App Store Connect — and all
   three have to agree.

   `--ui-test-entitled` grants the unlock without StoreKit, which is how the
   tests reach the paid providers.

7. Build and run. For simulated location features, use Xcode's location controls or the recording demo below.

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
| `PhotoUITests` | The library picker opening over the permanently presented sheet, the camera pill leaving with the screen that offered it, the seeded gallery and its viewer, deletion, showing a photo on the map, and reopening the gallery from the pin's callout. |
| `SettingsUITests` | Provider policy (no bulk download on OpenStreetMap or Thunderforest, no tile controls at all on Apple Maps), toggles that must hold their value across a reopen, and the field-report list, export sheet and delete. |
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
| `--ui-test-photo-library=<count>` | Reads a stub photo library of that many pictures instead of the real one. Absent means the real library; `0` is a real answer — a library with nothing in it. |
| `--ui-test-seed-metrics=<count>` | Seeds the field-metrics store with reports, since a real one takes a walk to fill. |
| `--ui-test-fail-first-save` | Fails the first save of a finished recording, so the retry path can be driven. |
| `--ui-test-weather` | Serves a fixed forecast instead of WeatherKit, which needs a network and a signed entitlement. |
| `--ui-test-entitled` | Grants the paid map sources without StoreKit, which has no purchase to make in a test. |
| `--ui-test-performance-log=<scenario>` | Writes signposts, stalls and samples to `Documents/PerformanceLogs/<scenario>.tsv`. |

`AccessibilityUITests` and `AccessibilityLabelUITests` are the VoiceOver half
of that bundle. The first runs `performAccessibilityAudit` per screen — the
sweep catches unnamed controls, tap targets below 44pt and elements it cannot
reach — over the map and sheet, a hike's details, settings, the recording
screen, route review, the photo gallery, the library-photo review grid and the
empty state. The second asserts the labels, values and traits this app
promises: that a hike row reads as one
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
| `OpenHikes/Photos/` | Photo capture and import, library discovery and time-to-place matching, the file store behind them, trail anchoring, the gallery and viewer, and the pins they draw on the map. |
| `OpenHikes/Sync/` | iCloud sync status and control, and the settings key-value mirror. |
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

SwiftData does the syncing. `Hike` lives in a store configured with
`cloudKitDatabase: .automatic`, and mirroring uploads, downloads, merges and
deletes from inside Core Data — there is no queue this app owns, no change
token it persists and no record mapping it writes. `OpenHikes/Sync/` is what
mirroring does *not* do: report what is happening, and remember whether the
user wanted it.

| Travels | Stays on the device |
|---|---|
| Hike title, custom name, date, distance, style, symbol, auto-follow and GPX metadata | Auto-saved and offline tiles, and the download records that describe them |
| The matched route and the raw GPS trace | Whether tile auto-save is on for a hike |
| Surface and difficulty breakdowns | Photo pixels — only a photo's metadata travels |
| Photo metadata, including the trail anchor | Whether Background Trail Tracking is on |
| Map tile provider, and the save-to-photo-library switch | Which hike this device has selected, and where it is along it |

Mirroring syncs a whole *row* and resolves conflicts last-writer-wins, with no
way to hold a column back — so anything describing files in this device's
Application Support has to live somewhere the mirror cannot reach. That is
`HikeLocalState`: a second `@Model` in a second, unmirrored `ModelConfiguration`,
holding the tile inventory and the per-hike auto-save switch. It is not
tidiness. `TileOwnership` builds the tile claim set from exactly those two
arrays and `TileCache.trimCache(claimedBy:)` deletes whatever no hike claims, so
a second device's inventory overwriting this one's would strip this device of
offline maps it really had downloaded, at the next launch, silently. The two
rows are in different stores and so cannot be related, which is why deleting a
hike calls `deleteLocalState()` by hand — nothing cascades.

Routes are `@Attribute(.externalStorage)` so mirroring carries them as a
`CKAsset`. A day's recording is some twenty thousand points, which is a couple
of megabytes encoded, and a `CKRecord`'s fields have to add up to less than one;
without this the longest hikes would be exactly the ones that failed to sync.

Two constraints ride along with `.automatic` and are easy to trip over later.
Mirroring refuses to open a store with a mandatory attribute that has no
default, and it forbids uniqueness constraints outright — every non-optional
column on `Hike` carries an inline default for that reason, and a new one has
to.

Settings ride separately, on `NSUbiquitousKeyValueStore`, because two
preferences do not need a record type and a conflict policy. The list is an
allowlist: a setting that describes *this* device — a granted location
permission, where this phone is in the app — deliberately does not travel.

Sync is on by default and can be turned off in Settings, where the same section
says what it is doing and, when it isn't, why. A `ModelConfiguration` decides
whether it mirrors when it is built, so the switch cannot take effect until the
app is next launched; `CloudSyncCoordinator.pendingRelaunch` is what makes that
gap a sentence on the screen rather than something the user discovers. Turning
it off never deletes a hike.

The status row is driven by `NSPersistentCloudKitContainer.eventChangedNotification`,
which is the only window SwiftData leaves open onto mirroring — an event says a
setup, import or export began or ended and whether it succeeded, and nothing
about what was in it. `CloudSyncOutcome` reduces one to the four things the row
can say, and filters CloudKit's own retry vocabulary out of it: a device in a
tunnel is not a device with a sync problem, and the retry that succeeds is
silent, so a transient error promoted to a headline would stay on the screen.

### What this costs

Letting SwiftData own sync gave up things a hand-written engine had. They are
deliberate, and they are the whole of the trade:

- **Photo pixels do not travel.** They are files under `HikePhotoStore`, not a
  SwiftData column, and mirroring only carries columns. A second device gets a
  photo's metadata and finds no file behind it.
- **Whole-row uploads.** Renaming a hike re-uploads its routes and its photo
  metadata, where the old engine sent one small record.
- **No draft filtering.** A recording in progress is a row like any other, so a
  walk is uploaded as it happens and a second device shows a hike whose line is
  still being drawn.
- **Last-writer-wins.** There is no hook to prefer an unsent local edit, and
  none to stop a remote copy landing on a hike this device is recording.
- **The CloudKit schema is now permanent.** It is append-only in production, so
  a column added to `Hike` cannot later change type or go away.

## Current limitations

- Offline trail matching is limited to Overpass graph regions that were cached previously; prebuilt regional graph bundles are not shipped.
- iCloud sync carries hikes and their metadata; photo pixels and downloaded map tiles stay on the device that produced them, by design.
- Turning iCloud sync on or off takes effect on the next launch.
- The Simulator cannot receive CloudKit push notifications, so a second simulator only picks up changes when it is brought to the foreground.
- The SwiftData store is not migrated across schema changes.
- Third-party tile keys can only be supplied at build time.

## Contact

For feedback and suggestions, email [zsombor.rajki@gmail.com](mailto:zsombor.rajki@gmail.com)
or visit the [OpenHikes project on GitHub](https://github.com/ZsomborRajki/OpenHikes).
