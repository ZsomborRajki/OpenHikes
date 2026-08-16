# OpenHikes code review

The current tree contains 227 first-party Swift files and 51,218 lines, plus
project and package configuration, scripts, entitlements, tests, and
documentation. The review focuses on correctness, concurrency, maintainability,
current API use, and especially battery, radio, CPU, and disk activity during a
hike.


## Test and project hygiene

The following open gaps remain:

| Gap | Impact |
|---|---|
| `SearchCompleter`, `WeatherManager`, `TrailBasemapRenderer`, `TopEdgeReader`, and `MainThreadWatchdog` lack direct suites | Timing, rendering, and stall behavior can regress. `SearchCompleter` and `MainThreadWatchdog` need an injectable seam before they can be tested at all — see the 2026-08-16 pass, §6.1 |
| Widget deep-link branches lack UI automation | Live recording, existing hike, and deleted hike routing are unguarded |
| Deleting a currently pushed hike lacks UI automation | Navigation cleanup is unguarded |
| No `.xcstrings` catalog exists | Localization will require a broad later migration |
| `OpenHikesModel`'s launch sweeps have no coverage | `trimTileCache` and `reclaimOrphanedPhotos` assemble the claim sets that authorize deletion, and nothing tests either — see the 2026-08-16 pass, §9.1 and §9.3 |

Strict SwiftLint passes, and every first-party Xcode target treats Swift
warnings as errors. The remaining warning debt is limited to duplicate
`@executable_path` runpath warnings emitted when Xcode links Thread Sanitizer
runtimes; normal debug and release builds are warning-free.

## API and dependency assessment

- For battery telemetry, prefer native Instruments, signposts, and current
  MetricKit reporting rather than an analytics SDK that adds its own network
  and background cost.

## Battery validation plan

Static review can identify unnecessary work but cannot certify battery life.
Run these scenarios on a physical device with a fixed route to validate the
P1/P2 energy remediations:

1. Foreground map browsing and live follow without recording.
2. Screen-locked background recording with normal connectivity.
3. Screen-locked recording with no service or a failing Overpass endpoint.
4. A 20-minute stationary pause.
5. Auto-save and a maximum-budget offline download.

Capture Energy Log/Power Profiler, Location activity, Network, CPU wakeups,
thermal state, and disk writes. Live matching, GPX parsing, location publication,
recording-trace rebuilds and Overpass graph prefetch now carry signposts, and
`PerformanceLog` will write them to a TSV alongside CPU and footprint samples
under `--ui-test-performance-log=`; tile planning
(`OfflineTileDownloader+Planning.swift`) and storage measurement
(`TileCache+StorageManagement.swift`) still need theirs. Compare against the
same device, route, screen state, and radio conditions rather than using a
universal percentage-per-hour target.

## Validation performed

Re-run on 2026-08-16 unless the row says otherwise. Rows marked *not re-run*
were last measured on the earlier pass and their numbers are no longer
trustworthy — the tree has grown by a whole feature domain since.

| Validation | Result |
|---|---|
| Strict SwiftLint | Passed (0.65.0, `--strict`) |
| Shared package tests | 57 tests in 9 suites passed |
| App and widget unit tests | 761 tests in 89 suites plus 19 widget tests in 3 suites passed |
| iOS debug build | Passed with first-party Swift warnings treated as errors |
| iOS release build | Not re-run |
| macOS compile | Not re-run |
| GPX Thread Sanitizer suite | Not re-run; previously passed, including concurrent timestamp parsing |
| UI automation and launch metrics | Not re-run. `OpenHikesUITests` now holds 7 tests and `AccessibilityUITests` 11 |
| Render and resource performance suite | Not re-run. `PerformanceUITests` now holds 7 tests; the `PERFORMANCE.md` baseline predates the Photos feature |
| Package resolution | Passed; CoreGPX is absent from `Package.resolved` |
| CI workflow | Every `xcodebuild` call in `ci.yml` carries `-skipPackagePluginValidation`; UI automation and the performance suite stay out of CI and run locally through their scripts |
| visionOS build | Not run; the visionOS 26.5 platform is not installed |
| Physical-device energy trace | Not run |

## Open product design decisions

These remain product choices rather than correctness findings:

1. **Pause semantics:** pausing stops accumulation but the persisted route stays
   a single segment.
2. **Shipped trail graphs:** cached Overpass regions do not provide offline
   matching in places the user has never visited.
3. **Widget takeover:** a live recording currently replaces the selected hike
   rather than appearing as a badge or secondary state.
4. **Two foreground location managers** (originally finding 20): `LocationManager`
   and `SystemRecordingLocationSource` each own a `CLLocationManager`, and both
   receive updates during an active recording. This was verified rather than
   assumed — the foreground manager never stops once started, and the recording
   source asks for `kCLLocationAccuracyBest` with a 10 m filter against the
   foreground manager's ten-meter/25 m baseline. iOS coalesces same-process
   location demand to the most demanding request, so this does not imply twice
   the GPS hardware power; what it duplicates is delegate dispatch,
   authorization handling, and actor hops. The separation is kept deliberately:
   the recording source owns background semantics (`allowsBackgroundLocationUpdates`,
   a `CLBackgroundActivitySession`, and no automatic pausing) that must not
   leak into ordinary map browsing. Revisit only if a device energy trace shows
   meaningful CPU overhead, and preserve those background semantics if the two
   are ever consolidated.

---

# Review pass — 2026-08-16

Scope: every feature domain, with a deliberate bias toward **stale, legacy or
simply wrong comments** — in code and in markdown alike. The comments in this
tree are largely AI-generated, so each one was treated as an unverified claim
and checked against the code it describes rather than believed. Findings that
could not be confirmed by reading the actual code path were dropped or are
labelled `UNVERIFIED`.

No fixes were applied. Two new test suites and one regression test were added
(see §7).

## 0. What this pass removed

The Photos block that used to close this document — 15 findings across bugs,
incompleteness and doc/code mismatches — has been deleted: every one of them
was re-checked against the current sources and every one was already fixed by
commit `d06ff4b`. The sections above have likewise been corrected in place
(file and line counts, the test-suite gap table, the signpost list in the
battery plan, and the validation table, which now says which rows were
actually re-run rather than presenting stale numbers as current).

**Two items from that deleted block were *not* fixed** and are carried forward
here rather than lost: photos are absent from every storage UI (§4.1), and the
photo screens have no UI or accessibility automation (§6.2).

The lesson worth keeping: this file drifted further from the code than any
source comment in the tree did. A finding is only useful while it is true, so
a review pass should start by deleting what has since been fixed.

## 1. Stale or wrong comments in code

**1.1 Medium — `OpenHikes/Recording/HikeRecorder+Energy.swift:56` refers to a type that does not exist**

```swift
/// Re-arms after every change, the same shape ``MapCoordinator`` uses:
```

There is no `MapCoordinator`. The type is `MapView.Coordinator`
(`MapCoordinator.swift:17`, `final class Coordinator` inside `extension
MapView`). The file is *named* `MapCoordinator.swift`, which is where the
confusion comes from. This is the only dangling DocC symbol link in the whole
tree — every other ``…`` reference in 227 files resolves — so it is worth
fixing rather than tolerating. Note the same name is used prose-style in
`.github/copilot-instructions.md` ("`MapCoordinator` uses `withObservationTracking`"),
which is fine as prose but means a reader searching for the type finds nothing.

**1.2 Low — `OpenHikes/Map/MapCoordinator.swift:345-346` undercounts what it owns**

```swift
/// Applies the live recording's immutable chunks plus its bounded tail,
/// then re-registers for the next revision.
func observeRecordingTrace(_ trace: RecordingTrace, on mapView: MKMapView) {
```

Two overlays are named; three are managed. The same entry point also creates
and tears down `recordingReviewOverlay` (declared `:26`, reset `:437-442`,
rebuilt `:490-499`, matched in the renderer lookup `:620`). A reader trusting
this doc would not know the review segment is drawn from here.

**1.3 Low — `OpenHikesUITests/{OpenHikesUITests,AccessibilityUITests,PerformanceUITests}.swift` link to a file as if it were a symbol**

All three headers write ``UITestSupport``. That is a file name, not a type, so
the link resolves to nothing. Cosmetic, but it is the same class of drift as
1.1 and shows up in the same automated sweep.

**1.4 Note — `OpenHikesShared/.../Color+Hex.swift:14` claims parity that nothing enforced**

```swift
/// Mirrors the app target's own `Color.init?(hex:)` exactly.
```

The claim is **true today** — the two parsers were diffed line by line — but
the app's suite (`RouteAppearanceTests`) tests its copy through `hexRGBA`,
which the package deliberately does not carry, so the two could have drifted
without a single test going red. Closed on this pass (§7).

## 2. Stale or wrong documentation

**2.1 High — `README.md:14` fuses two feature bullets into one**

```
… with an optional copy saved to the photo library.- Passive tile auto-save for browsed areas, …
```

The newline before `- Passive tile auto-save` was dropped when the Photos
bullet was inserted (commit `d06ff4b`), so tile auto-save no longer renders as
a feature at all — it renders as the tail of the photos sentence.

**2.2 Medium — `README.md:116-119` describes 5 of the 7 UI tests**

The sentence beginning "coverage includes app/settings smoke navigation…"
accounts for `testLaunchesMapAndOpensSettings`, `testImportsBundledGPXAndOpensItsDetails`,
`testSimulatedLocationStartsRecording`, `testReviewsSnappedRouteAfterStopping`
and `testLaunchPerformance`. It never mentions `testPicksARouteLinePattern`
(`OpenHikesUITests.swift:136`) or `testOpensAndClosesThePhotoLibraryPickerOverTheSheet`
(`:175`) — the latter added by the same commit that edited this README section.

**2.3 Medium — the `--ui-test-offline` launch argument is documented nowhere**

`AppLaunchEnvironment.swift:20` declares `offlineArgument = "--ui-test-offline"`.
The launch-argument lists in both `README.md` and
`.github/copilot-instructions.md` enumerate the other five
(`--ui-test-expanded-sheet`, `--ui-test-enable-location`, `--ui-test-import-gpx=`,
`--ui-test-trail-graph=`, `--ui-test-performance-log=`) and omit this one. A
list that is *almost* complete is worse than no list, because it is read as
exhaustive.

**2.4 Medium — `PERFORMANCE.md:604` quotes a test count from before the Photos feature**

```
| App and widget unit tests | **658 passed** (639 + 19) |
```

Actual today: 752 + 19. The whole "Baseline — 2026-08-14" section predates
commit `d06ff4b`, so every render, energy and launch number in it was measured
against a build without the photo pipeline, the gallery strip or the map pins.
The document does not say so.

**2.5 Medium — `SOCIAL.md` is untracked but `README.md` links to it**

`git status` reports `?? SOCIAL.md` and `M README.md`. The README's
"See [`SOCIAL.md`](SOCIAL.md)" link is a dangling link for every other clone
and for CI. Commit the two together or drop the link.

**2.6 Low — no `.xcstrings` catalog exists** (carried forward, still true).
The app is full of `String(localized:)` and `LocalizedStringKey` call sites
with no catalog behind them, so the strings are extractable in principle and
localizable in practice by nobody.

## 3. Bugs and correctness risks

> The highest-severity findings on this pass are in §9 and §10, which arrived
> after this section was written: `trimTileCache` can delete a hike's offline
> maps when a fetch fails (§9.1), the launch sweeps run against the real store
> during a hosted unit-test run (§9.3), and the OpenStreetMap bulk-download
> prohibition is enforced only inside a SwiftUI body (§10.1).

**3.1 Medium — search failure is completely silent (`OpenHikes/Map/MapSheet.swift:367-376`)**

```swift
searchTask = Task {
    guard let response = try? await MKLocalSearch(request: request).start(),
          !Task.isCancelled else { return }
```

No network, a rate limit, or a query MapKit cannot resolve all produce the same
result: nothing happens. No message, no detent change, no log. This is notable
because the *same file* treats the analogous case as a bug worth fixing — the
`.fileImporter` failure handler at `:122-126` says "dropping it here would be
the same silent no-op the import path itself was just fixed for." No test
covers this path.

**3.2 Medium — two widget-feed suites write to the host app's real preferences**

`BackgroundTrailTracker.init`'s own doc (`BackgroundTrailTracker.swift:176-178`)
says:

```swift
///   - defaults: … A test passes a suite of its
///     own rather than editing the ones the host app is using.
```

`WidgetFeedTests.swift:37` and `WidgetFeedBudgetTests.swift:33` both call
`BackgroundTrailTracker(container: container)` with no `defaults:`, so both run
against `UserDefaults.standard`, and both clean up by removing
`SettingsKey.lastMatchedDistance` from it in `deinit`. `BackgroundTrackingTests`
does it correctly (`:100`, `:123`, `:246` all pass `defaults:`).

The immediate effect is that these suites read and write the simulator's real
app preferences: a developer whose app has Background Trail Tracking on, or a
stored `selection.lastHikeID`, is running these tests against that state rather
than against a blank one. Cross-suite interference is *currently* prevented by
something incidental — both are nested inside
`@Suite("Widget feeds", .serialized, …)` (`WidgetFeedTests.swift:24`), and
`.serialized` is recursive, so the two subsuites cannot overlap. That is a
property of the parent suite's trait, not of the defaults being isolated:
un-nesting either suite, or adding a third suite elsewhere that touches the
same key, reintroduces the race with nothing to catch it. Passing a
per-suite `UserDefaults` is the fix the initializer's own doc already asks for.

**3.3 Low, `UNVERIFIED` — `waitForSelectionPublish()` may resolve on a superseded task**

`BackgroundTrailTracker.swift:278` awaits whatever `selectionPublishTask` held
at the moment of the call. If `hikeSelectionChanged(to:)` runs again and
reassigns that property, an already-pending waiter resolves as soon as the
*cancelled* task exits its guards, rather than when the newest selection is
actually published. The only production caller (`HikeDetailView.swift:253`)
awaits it specifically "so the first fix cannot race and be overwritten by the
trail's initial snapshot". **What would settle it:** a test that calls
`hikeSelectionChanged` twice in quick succession and asserts a
`waitForSelectionPublish()` awaited after the first does not resolve until the
second selection's snapshot is on disk.

## 4. Incompleteness

**4.1 Medium — photos are invisible to every storage surface** (carried forward)

`HikePhotoStore.byteCount(of:)` (`HikePhotoStore.swift:246`) exists, is
documented as "What these photos cost on disk, thumbnails included", and is
called by **six test assertions and nothing else**. Neither
`SettingsView`'s storage section nor `HikeDetailView+OfflineStorage` reads it.
Full-size captures at 0.9 JPEG quality plus thumbnails accumulate under
Application Support — deliberately *not* excluded from backup
(`HikePhotoStore.swift:8-13`) — with no number anywhere in the UI and no cap.
Tiles get `diskUsage(claimedBy:)`, a delete button and a trim; photos get none
of the three.

**4.2 Low — `SearchCompleter` swallows its error (`SearchCompleter.swift:50-52`)**

```swift
func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
    suggestions = []
}
```

`error` is bound and discarded, with no `Logger` line — unlike every other
error path in this domain. Showing nothing is the right *UX*; leaving no
diagnostic trail if the completer starts failing systematically is not.

**4.3 Low — selecting a suggestion fires one more completer request than it needs**

`MapSheet.swift:346-351` sets `searchText = completion.title` *after*
`completer.clear()`, which re-triggers the `.onChange(of: searchText)` at
`:187` and issues a fresh `MKLocalSearchCompleter` query for a search the user
has already committed to. Harmless (the list is gated on focus, already
cleared) but it is a wasted round-trip on the radio, in a file whose whole
design brief is not spending power.

## 5. Dead code and unused API

Confirmed by whole-tree grep, including tests:

**5.1 Medium — `OpenHikes/Recording/HikeRecorder+Persistence.swift:442`**

```swift
func scheduleAndPublishAfterPoint(_ point: RecordingPoint) {
```

Never called. It bundles four side effects — journal append, flush schedule,
widget fix merge, snapshot publish — and the live path performs the same
sequence inline at `HikeRecorder+Lifecycle.swift:243-247`. This is the
dangerous kind of dead code: it reads like the canonical way to record a point,
so a future change is likely to call it *in addition to* the inline sequence
and double-append to the recovery journal.

**5.2 Low — `OpenHikes/Recording/RecordingModels.swift:108`**

```swift
static let preferredHorizontalAccuracy: CLLocationAccuracy = 20
```

Sits among the `RecordingFixPolicy` constants that genuinely gate fixes
(`maximumHorizontalAccuracy`, `maximumSpeed`, `minimumDisplacement`, …) and is
referenced by nothing at all — not by `accepts(_:after:motionState:)`, not by
`RecordingEnergyPolicy`, not by a test. It reads as policy and is inert.

**5.3 Low — `OpenHikes/General/LiquidGlass.swift:120`**

```swift
func glassUnion(id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View
```

Zero call sites. Its documented partner `GlassStack` is used in 8 places
(including `MapSheet.swift:85` and `MapSheetHikes.swift:122`), none of which
attach it — so the "reads as one pane rather than several tiles" behaviour the
doc describes is not something this app currently does anywhere.

**5.4 Note — deliberate test seams, listed so they are not re-flagged**

`TileCache.performMaintenance`, `TileCache+Network.{setReachable,setNetworkConditions,memoryLimits}`,
`TileLoadGate.{budgets,testState}`, `TileFailureLog.retryTime`,
`AutoSaveController.waitForActivation`, `AutoSaveTileStore.setActiveHike`,
`OfflineTileDownloader.{waitForCurrentRun,waitForPlanning}`,
`SharedStore.clearPendingRecordingFixes`, `PowerState.isConserving` and
`Hike.routeStatistics` are all production symbols reached only from tests.
Every one of them is an intentional seam, and `Hike.routeStatistics`
(`Hike+Statistics.swift:203-208`) documents in so many words that the app's own
numbers deliberately do not come through it. Left alone.

## 6. Test-coverage gaps

**6.1 The gap table's own entries, re-checked**

| Type | Still uncovered? | Note |
|---|---|---|
| `DirectionalPolylineRenderer` | **No** | suite added this pass (§7) |
| `WeatherManager` | Yes | `WeatherPollingTests` covers `WeatherPollState` only |
| `TrailBasemapRenderer` | Yes | — |
| `TopEdgeReader` | Yes | SwiftUI layout reader; needs a hosted hierarchy |
| `SearchCompleter` | Yes — **and untestable as written** | the `MKLocalSearchCompleter` is a `private let` (`SearchCompleter.swift:17`) and `MKLocalSearchCompletion` cannot be constructed, so no hermetic test can drive `suggestions` to a non-empty value. The gap is a *missing seam*, not a missing test; injecting the completer is the actual work |
| `MainThreadWatchdog` | Yes — **and untestable as written** | `start()` spawns a `Thread` running `while true` with hard-coded intervals and no injectable clock (`MainThreadWatchdog.swift:66-118`). A test could only start a real watchdog it cannot stop |

**6.2 Medium — the photo screens have no automation at all** (carried forward)

Cross-referencing every `accessibilityIdentifier` in the app against every
identifier used in `OpenHikesUITests`: `photos-section`, `photo-viewer`,
`photo-delete-button`, `photo-show-on-map-button`, `hike-photo-strip`,
`hike-photo-<uuid>` and `map-camera-button` are defined and **never driven**.
The one photo UI test that exists
(`testOpensAndClosesThePhotoLibraryPickerOverTheSheet`) stops at the picker's
Cancel button. There is also no launch argument to seed a hike with photos, so
the gallery, the viewer, paging, delete-and-dismiss and the map pins are
unreachable in the simulator — no camera, out-of-process picker. A
`--ui-test-seed-photos` hook is the unblocking change.

The same sweep found these identifiers defined but never exercised by any UI or
accessibility test: `weather-badge`, `difficulty-section`, `difficulty-bar`,
`surface-section`, `surface-bar`, `hike-title-field`, `import-gpx-button`,
`recording-retry-save`, `review-next-section`, `review-previous-section`,
`offline-download-button`, `delete-offline-tiles-button`,
`cellular-tiles-toggle`, `save-photos-to-library-toggle`.

**6.3 Low — `MapSheet.startSearch` has no coverage**, which is how 3.1 stayed
invisible.

## 7. Tests added on this pass

No production code was changed.

- **`OpenHikesTests/Map/DirectionalPolylineRendererTests.swift`** — 7 tests.
  Closes a gap this document listed, now removed from the table above. Drives
  `draw(_:zoomScale:in:)` into a
  bitmap `CGContext` (no `MKMapView` needed) and asserts: chevron patterns ink
  the context and non-chevron ones do not, a non-positive zoom scale and a
  one-point line are refused rather than dividing by zero, an off-screen
  segment at deep zoom returns promptly — which is the only observable
  difference between the closed-form spacing carry
  (`DirectionalPolylineRenderer.swift:104-110`) and the per-chevron loop its
  comment says it replaced — and that skipping an off-screen segment still
  leaves the visible tail drawn.
- **`OpenHikesShared/Tests/OpenHikesSharedTests/General/ColorHexTests.swift`** —
  6 tests. The shared `Color(hex:)` had none, while claiming to mirror the
  app's copy exactly (§1.4). Covers six- and eight-digit forms, the optional
  `#`, whitespace trimming, and rejection of everything else.
- **`OpenHikesTests/Tiles/TileCacheTierTests.swift`** — 1 test,
  `trimWithNoClaimsEvictsDurableTiles`, added next to the existing
  claimed-tile trim test. It pins the consequence behind §9.1: with an empty
  claim set, `trimCache` deletes a *durably saved* tile, not just browsing
  residue. It passes today, because the hazard is in the caller that produces
  the empty set rather than in `trimCache` itself — which is exactly why the
  hazard is easy to miss by reading either one alone.
- **`OpenHikesTests/Tiles/TileProviderTests.swift`** — 1 test,
  `policyIsRecoverableFromASource`, parameterised over every provider. It pins
  that `supportsBulkDownload` can be recovered from an `ActiveTileSource`'s
  `providerID` alone, which is the seam a fix for §10.1 needs and which
  `ActiveTileSource` currently drops. Added to that suite specifically because
  its header already frames the flag as a licensing promise rather than a
  feature toggle.

Verified after adding them: `Scripts/lint.sh` → `SwiftLint clean (0.65.0, --strict)`;
`swift test --package-path OpenHikesShared` → 57 tests in 9 suites passed;
`xcodebuild test … -only-testing:OpenHikesTests -only-testing:OpenWidgetTests`
→ 759 tests in 89 suites plus 19 in 3, all passed. The two later tile tests
(§9.1 and §10.1) were verified by re-running the whole bundle: **761 tests in
89 suites plus 19 in 3, all passed**, with `Scripts/lint.sh` clean.

## 8. Nice to have

0. **Not a nice-to-have, listed here only so the ordering is honest:** fix
   §9.1 first. It is a two-character change (`?? []` to a `guard … else
   { return }`) against a failure that silently deletes offline maps, and §7
   already ships the test that proves the consequence.
1. **`Scripts/run-performance-tests.sh` is the only `xcodebuild`-invoking script
   without `-skipPackagePluginValidation`.** Every call in `.github/workflows/ci.yml`
   has it and `Scripts/run-ui-tests.sh` handles the same problem explicitly, so a
   contributor who runs the performance script before ever opening the project in
   Xcode hits `Plugin "SwiftLintBuildToolPlugin" … must be enabled`.
2. **A `--baseline` flag for `Scripts/perf-report.py`.** `PERFORMANCE.md`'s own
   TODO already asks for it, and 2.4 shows why it matters: the baseline is
   already stale and there is no mechanical way to notice.
3. **Re-measure `PERFORMANCE.md` against a build that includes Photos**, and
   date-stamp the section so the next reader knows what it does and does not
   cover.
4. **Give `SearchCompleter` an injectable completer and `MainThreadWatchdog` an
   injectable clock** (6.1). Both are listed as untested; neither can be tested
   until it has a seam, so the honest next step is the seam.
5. **Signpost tile planning and storage measurement** — the two items left on
   this document's own battery-validation list that genuinely have none.
6. **Log the discarded `SearchCompleter` error** (4.2) — one `Logger` line.
7. **Show photo storage in Settings** (4.1), reusing `byteCount(of:)`, which
   already exists and is already tested.
8. **A localization catalog.** Every user-facing string already goes through
   `String(localized:)` / `LocalizedStringKey`, so the expensive half of the
   work is done; without an `.xcstrings` none of it is reachable.

## 9. `App/`, `Hikes/` and `Settings/` — the launch sweeps

This domain's deep-dive returned late; the findings below were each re-verified
against the sources before being recorded here.

### 9.1 (High) `trimTileCache` turns a failed fetch into "nothing is claimed"

`OpenHikesModel.swift:287-290`:

```swift
let claims = (try? modelContext.fetch(FetchDescriptor<Hike>()))?
    .filter(\.hasStoredTiles)
    .map(TileOwnership.init) ?? []
```

If the fetch throws, `try?` yields `nil`, the chain short-circuits, and `?? []`
produces an **empty claim set** — which the code then hands to
`TileCache.shared.trimCache(claimedBy: keys)`. `trimCache` distinguishes a
saved tile from browsing residue by nothing but that set
(`TileCache+StorageManagement.swift:155-160`), so an empty one makes every
durable tile — a hike's downloaded offline map — eligible for oldest-first
eviction once the total passes `cacheByteLimit` (500 MB,
`:132`). That is the one outcome the same file calls unaffordable at
`:128-129`: *"deleting it to stay under a number is the one failure this app
can't afford."*

It also violates the invariant stated in `.github/copilot-instructions.md`:
*"both driven at launch from a complete claim set — a fetch that fails must
sweep nothing rather than sweep with an empty set."*

The author clearly knew the rule. The *inner* loop gets it exactly right —
`guard let claimed = try? ownership.tileKeys() else { return }`
(`OpenHikesModel.swift:296`) abandons the whole trim rather than proceed with a
partial set, and the comment above it explains why. Only the outer fetch was
missed. The sibling `reclaimOrphanedPhotos` gets it right too:
`guard let hikes = try? … else { return }` (`:302`).

Bounded to installs holding more than 500 MB of tiles, but that is precisely
the population that has downloaded offline maps.

**§7 adds a test pinning the consequence** — an empty claim set does delete a
durably saved tile — so a fix has a failing assertion waiting for it at the
call site rather than only in review prose.

### 9.2 (High) The doc comment above it claims a parity that does not exist

`OpenHikesModel.swift:312-314`, on `reclaimOrphanedPhotos`:

> "A fetch that fails sweeps nothing rather than sweeping with an empty claim
> set — **the same rule the tile trim follows**, and for the same reason."

The tile trim does not follow that rule (9.1). The comment is true of the
function it is attached to and false about the function it cites, which is the
worst combination: it is the reason a reader checking the tile path would
conclude it had already been handled.

### 9.3 (Medium) Launch sweeps guard on `isUITesting`, not `isRunningTests`

`AppLaunchEnvironment.swift:83-92` documents `isHostingTests` as the flag that
keeps startup writers out of a hosted test run — *"It's a race no test can
win, so the writers stay behind this flag."* Five call sites use the narrower
`isUITesting` instead:

| Site | Work performed |
|---|---|
| `OpenHikesView.swift:183` | `trimTileCache` + `reclaimOrphanedPhotos` |
| `OpenHikesView.swift:189` | `pollWeather()` |
| `OpenHikesModel.swift:204` | `backgroundTracker.refreshBasemaps()` |
| `OpenHikesModel.swift:234` | `backgroundTracker.hikeSelectionChanged(to:)` |
| `OpenHikesApp.swift:29` | `TileCache.shared.removeExpiredTiles()` |

`isRunningTests` is `isHostingTests || isUITesting`
(`AppLaunchEnvironment.swift:99`), so `!isUITesting` is strictly weaker. During
a hosted `OpenHikesTests` run `isHostingTests` is true and `isUITesting` is
false, and `OpenHikesModel.convenience init()` only special-cases
`isUITesting` (`:50`) — so it falls through to `Self.loadDefaultContainer()`,
the **real on-disk SwiftData store**, and real `UserDefaults.standard`. Every
row above therefore runs against real user data on whatever machine runs the
unit tests: a real tile trim, a real expired-tile sweep, a real photo
reclamation, and a real WeatherKit request.

Exactly one site gets it right — `restoreLastSelectedHike` at
`OpenHikesModel.swift:244` uses `guard !AppLaunchEnvironment.isRunningTests`,
and it is the one the conventions doc happens to name. `OpenHikesApp.swift:24`
(`MainThreadWatchdog.start()`) is deliberate and argued in place; it is not
part of this finding.

Nothing in `OpenHikesTests/` references `trimTileCache`,
`reclaimOrphanedPhotos` or `isHostingTests`, so neither the guard nor the
sweeps have any coverage.

### 9.4 (Medium) `RouteMotion` is captured, persisted forever, and never read

`HikeSupportingTypes.swift:50-60` declares `RouteMotion` and
`RouteCoordinate.motion`. `RecordingModels.swift:99` writes it, tagging every
fix Core Motion judged non-pedestrian, and it is persisted in every `Hike`'s
route. No production code ever reads it: a grep for `.motion` and `RouteMotion`
across `OpenHikes/`, `OpenHikesShared/Sources/` and `OpenWidget/` returns only
the declaration and that one write. The only readers are two tests
(`HikePersistenceTests.swift:205`, `HikeRecorderTests+Sensors.swift:59`).

Statistics, the elevation chart, the surface and difficulty breakdowns and GPX
export all ignore it. Either it is a half-finished feature — flagging or
excluding vehicle-assisted segments is the obvious intent — or it is dead
weight in the persisted schema. Worth deciding which, because it costs a column
in every route point either way.

### 9.5 (Low) Sign in with Apple is an inert placeholder — correctly labelled

`SettingsView.swift:103-125`. Recorded only to confirm it is *not* a finding:
the row is `.allowsHitTesting(false)`, reads "Coming soon", carries a matching
`accessibilityValue`, and its doc comment says so. This is how an unfinished
feature should be presented.

## 10. `Tiles/` — policy enforcement and reclaim paths

This domain's deep-dive also returned late. It reached §9.1 independently and
by the same reasoning, which is worth recording: two separate readings of
`trimTileCache` found the same `?? []`. Its own new findings follow, each
re-verified.

### 10.1 (Medium) The bulk-download policy is enforced only in a view

`.github/copilot-instructions.md` states the rule as a domain guarantee:
*"`TileProvider.supportsBulkDownload` gates prefetching: OpenStreetMap is
passive auto-save only."* `TileProviderTests.swift:6-10` puts it more strongly
still — *"not a feature flag, it's a promise to the tile host… a change that
flips that flag is a licensing problem, not a UI one."*

`supportsBulkDownload` appears in exactly four places
(`TileProvider.swift:28,62,74,86` for the declaration and the three catalog
entries) plus two consumers — **both in a view**: `HikeDetailView.swift:341`
hides the download button, and `:416` computes `canDownload`.
`OfflineTileDownloader.start(route:source:scale:)`
(`OfflineTileDownloader.swift:87`) never mentions it. Its guards cover an
in-flight download, a one-point route and being offline; none covers the
provider's policy.

The root cause is a projection that drops the bit. `ActiveTileSource`
(`TileProvider.swift:103-107`) carries `providerID`, `urlTemplate` and
`maximumZ` — and not `supportsBulkDownload` — so by the time a route reaches
the downloader, the promise has been erased from the value it was travelling
in.

Safe today: there is exactly one production call site
(`HikeDetailView.swift:346`) and it is correctly gated. But an obligation to a
third party that is enforced by one `if` in one SwiftUI body, with no defence
in the domain that owns it, is one refactor away from a licensing violation
rather than a bug.

§7 adds a test pinning the lookup that would make enforcement possible —
`TileProvider.provider(id: source.providerID).supportsBulkDownload` — so a fix
has a supported seam and a regression has somewhere to fail.

### 10.2 (Medium) `DiskUsage.unclaimed`'s doc says "Only", and it isn't

`TileCache+StorageManagement.swift:19-22`:

> "Only the TTL sweep and ``trimCache(claimedBy:limit:)`` reclaim these."

`removeTiles(unclaimedBy:)` — 80 lines below in the same file, at `:104` —
reclaims precisely that bucket, wholesale, and it is what the user-facing
**Clear Map Cache** button calls (`SettingsView.swift:270` → `:410` →
`:468-470`). The
comment enumerates the two automatic reclaim paths and omits the manual one,
under a word that promises the list is exhaustive.

Worth fixing for the same reason as §9.2: a reader auditing what can delete a
tile is entitled to trust an enumeration that says "only".

### 10.3 (Low) `AutoSaveTileStore.setActiveHike` is a test-only entry point

`AutoSaveTileStore.swift:69` has no production callers — the only two are
`AutoSaveTileTests.swift:47,198`. Unlike the domain's other test hooks
(`waitForActivation()`, `waitForCurrentRun()`, `waitForPlanning()`, all
explicitly labelled), nothing marks it as one.

It also computes the corridor synchronously on the caller's thread, bypassing
the two-phase design `AutoSaveController.activate` uses — `beginActiveHike`
with an empty corridor, then an async `updateCorridor` off-main. So it is not
merely unused: it is a differently-shaped path that would defeat that design if
someone reached for it from production, which its unlabelled presence invites.

### 10.4 (Low) Three hot disk paths skip `assertOffMainThread`

`TileCache.swift:349` `loadTile`, `:416` `saveTileDurably` and `:631`
`promoteCachedTile` all perform synchronous disk I/O with no off-main
assertion, while every other disk-touching method in the domain has one —
`removeExpiredTiles` (`TileCache.swift:686`), and `removeTiles(unclaimedBy:)`,
`diskUsage(claimedBy:)`, `bytes(forKeys:)`, `trimCache(claimedBy:limit:)` in
`TileCache+StorageManagement.swift`.

All current callers do run off-main, so this is unenforced convention rather
than a live bug. It is listed because these three are the *hottest* paths in
the file — the ones a render miss would most plausibly be routed through by
mistake — and the conventions doc names exactly that mistake: *"Do not turn a
render miss into synchronous disk/network work."* The assertion is how that
rule is enforced everywhere else.

### 10.5 (Low) No test pins the downloader's side of the policy

Following from 10.1: no test exercises `OfflineTileDownloader` refusing a
`supportsBulkDownload == false` source. `OfflineTileDownloaderTests.swift` uses
`TileProvider.openStreetMap.id` freely, but only as tile-key math, never as
policy. The guarantee is currently pinned by `TileProviderTests.swift` (the
static flag value) and by UI wiring — never by the behaviour of the thing that
would do the downloading.

## 11. Coverage and honesty about this pass

Verified directly: the whole Photos domain, the `App/`, `Hikes/` and
`Settings/` screens, all markdown documentation, CI workflow, scripts, the test
plan, the shared package, the widget, every `accessibilityIdentifier` in the
app cross-referenced against the UI test bundle, every ``…`` DocC reference in
all 227 Swift files cross-referenced against declared symbols, a whole-tree
unused-symbol sweep, and the Map, Location, Weather and General domains.

**Reviewed less deeply:** `Recording/` only — beyond the dead code in §5, the
comment in §1.1 and the `RouteMotion` write in §9.4. Its delegated deep-dive
never returned, so it has had a targeted mechanical pass — dangling doc links,
dead symbols, settings-key read/write audit — rather than a line-by-line
reading. A follow-up pass should start there, and nowhere else is outstanding.

Two findings in this document were reached twice independently (§9.1, by both
the `App/` and `Tiles/` passes). That is the only corroboration of that kind
here; everything else rests on a single reading plus my own verification
against the source, which is why every claim cites the line it came from.
