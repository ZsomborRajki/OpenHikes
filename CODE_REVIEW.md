# OpenHikes code review

The current tree contains 236 first-party Swift files and 53,675 lines, plus
project and package configuration, scripts, entitlements, tests, and
documentation. The review focuses on correctness, concurrency, maintainability,
current API use, and especially battery, radio, CPU, and disk activity during a
hike.


## Test and project hygiene

The following open gaps remain:

| Gap | Impact |
|---|---|
| `SearchCompleter`, `WeatherManager`, `TrailBasemapRenderer`, `TopEdgeReader`, and `MainThreadWatchdog` lack direct suites | Timing, rendering, and stall behavior can regress. `SearchCompleter` and `MainThreadWatchdog` need an injectable seam before they can be tested at all — see the 2026-08-16 pass, §1 |
| Widget deep-link branches lack UI automation | The *routing rules* are covered — `TrailWidgetDeepLinkTests` for URL round-tripping and `.recording` vs `.hike`, `SheetRouteTests` for the recording branch's effect, `HikeDeletionTests.deepLinkToDeletedHikeResolvesToNothing` for the deleted one. What is unguarded is only the call site, `openWidgetLink`/`openHike`, which are private `View` methods |
| No `.xcstrings` catalog exists | Localization will require a broad later migration |

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

Re-run on 2026-08-25 unless the row says otherwise. Rows marked *not re-run*
were last measured on the earlier pass and their numbers are no longer
trustworthy — the tree has grown by a whole feature domain since.

| Validation | Result |
|---|---|
| Strict SwiftLint | Passed (0.65.0, `--strict`) |
| Shared package tests | 57 tests in 9 suites passed |
| App and widget unit tests | 779 tests in 91 suites plus 19 widget tests in 3 suites passed, and the app bundle run four times over to confirm a flake was gone rather than hiding |
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

## 0. What has been fixed, and what this document is now

**Everything this pass found has been implemented except the three items in
§1–§3 below.** Twenty-three findings — the two High-severity launch-sweep bugs,
the licensing-policy hole, the silent search failure, the two stale doc
comments, three dead symbols, the shared-preferences test leak, four
documentation errors and the rest — were fixed and their sections deleted. The
commits carry the detail; repeating it here would just start the drift again.

That is the rule this file now follows, learned from the pass before it: **a
finding is only useful while it is true.** This document drifted further from
the code than any source comment in the tree did, because fixed findings were
left in place. So a section is deleted the moment its fix lands, and what
survives below is only what is still true today.

One of those twenty-three was a product decision rather than a fix, and the
decision is recorded here because it is the kind that a later unused-symbol
sweep will re-open: `RouteMotion` — collected on every recorded fix, persisted
in every route, read by nothing — **is kept deliberately**. The intended use is
flagging or excluding vehicle-assisted segments, and Core Motion's judgement
cannot be reconstructed after the fact, so recording it now is what lets that
feature ever apply to hikes people have already walked. The reasoning now lives
on the type itself (`HikeSupportingTypes.swift`), which is where it will still
be found.

What is left is deliberately small: two gaps that need a *seam* before they can
need a test, one automation hook, and one localization prerequisite. None of
them is a bug.

## 1. Two components need a seam before they can need a test (Low)

Both are listed as uncovered in this document's gap table, and both would stay
uncovered no matter how much test-writing effort was spent, because neither is
reachable from a test as written. The honest next step is the seam, not the
test.

| Component | Why no hermetic test exists |
|---|---|
| `SearchCompleter` | The `MKLocalSearchCompleter` is a `private let` (`SearchCompleter.swift:23`) and `MKLocalSearchCompletion` cannot be constructed, so nothing can drive `suggestions` to a non-empty value. Injecting the completer is the work. Its *failure* path is now covered — `SearchFailureTests` pins the error-to-copy mapping, which was extracted into a pure value type precisely so it could be. |
| `MainThreadWatchdog` | `start()` spawns a `Thread` running `while true` with hard-coded intervals and no injectable clock (`MainThreadWatchdog.swift:66-118`). A test could only start a real watchdog it cannot stop. |

Three further components remain uncovered but are *not* blocked in this way —
`WeatherManager` (only `WeatherPollState` is covered, by `WeatherPollingTests`),
`TrailBasemapRenderer`, and `TopEdgeReader`, which needs a hosted SwiftUI
hierarchy.

That `UNVERIFIED` item about `waitForSelectionPublish()` is settled: it was
true, it was worse than described, and it is fixed. See the 2026-08-25 pass.

## 2. The photo screens have almost no functional automation (Medium)

*Rewritten on 2026-08-25. The previous version of this section was wrong in
its central claim and stale in half its evidence — see that pass's §B.*

The unblocking change this section asked for **exists**: `--ui-test-seed-photos=N`
(`AppLaunchEnvironment.swift:21`, `SeededPhotoFixture.swift`) seeds a hike with
up to 24 generated photos, so the gallery, the viewer and the map pins are
reachable in a simulator that has no camera and no in-process picker.

What is still missing is the functional tests downstream of it. The hook has
exactly one consumer, `PerformanceUITests+Photos.swift`, which is a
*measurement* suite: it is in `skippedTests` for `OpenHikes.xctestplan` and is
kept out of `Scripts/run-ui-tests.sh --all`, so nothing that runs on a normal
day exercises a photo screen. `hike-photo-<uuid>` is therefore driven only by a
suite nobody runs by default, and `photo-viewer`, `hike-photo-strip` and
`map-camera-button` are driven only by `AccessibilityUITests`. Paging,
delete-and-dismiss and the show-on-map action have no coverage at all.

Cross-referencing all 35 `accessibilityIdentifier`s in the app against the UI
test bundle, these are defined and driven by nothing:

`cellular-tiles-toggle`, `delete-offline-tiles-button`, `difficulty-bar`,
`difficulty-section`, `hike-title-field`, `import-gpx-button`,
`offline-download-button`, `photo-delete-button`, `photo-show-on-map-button`,
`recording-retry-save`, `review-next-section`, `review-previous-section`,
`save-photos-to-library-toggle`, `surface-bar`, `surface-section`,
`weather-badge`.

The three interpolated identifiers — `hike-photo-\(uuid)`,
`provider-row-\(id)`, `route-pattern-\(rawValue)` — are all matched by prefix
somewhere in the bundle and are *not* part of that list.

## 3. No localization catalog exists (Low)

Carried forward from the previous pass and still true. The app is full of
`String(localized:)` and `LocalizedStringKey` call sites with no `.xcstrings`
behind them, so the strings are extractable in principle and localizable in
practice by nobody. The expensive half of the work — routing every user-facing
string through a localization API in the first place — is already done.

## 4. Deliberate test seams, listed so they are not re-flagged

Each of these looks unused from production and is not. They are recorded here
so a future unused-symbol sweep does not delete them.

- `OpenHikesModel.loadContainer(persistent:fallback:)` — the only way to make
  the persistent-store-open failure testable.
- `OpenHikesModel.tileClaims(fetchingHikes:)` and `photoClaims(fetchingHikes:)`
  — same pattern, for the two launch sweeps. Both `throw` rather than returning
  an empty set, because an empty claim set authorizes deleting every durable
  tile and every photo in the app.
- `AutoSaveTileStore.setActiveHike(_:)` — labelled in place; the app drives it
  through `AutoSaveController`.
- `TileCache` and `AutoSaveTileStore`'s injectable roots, and `TileSandbox` in
  the test bundle, which exist so a suite never touches `TileCache.shared`.
- `BackgroundTrailTracker`, `LocationManager` and `OfflineTileDownloader`'s
  injectable location, defaults, clock and transport.
- `BackgroundTrailTracker.isPublishingSelection` — reports whether a selection
  publish is still outstanding. Added 2026-08-25 because the bug it now pins
  was invisible from outside: a leaked task handle silences the live widget
  feed, and nothing else in the type's surface says so.

## 5. Nice to have

1. **A `--baseline` flag for `Scripts/perf-report.py`.** `PERFORMANCE.md`'s own
   TODO asks for it, and the reason it matters is now written into that file:
   the baseline predates the Photos feature and there is no mechanical way to
   notice that from a run.
2. **Re-measure `PERFORMANCE.md` against a build that includes Photos.** The
   section is now date-stamped and carries a caveat saying what it does not
   cover, which is the honest interim state, not a fix.
3. **Signpost tile planning and storage measurement** — the two items left on
   this document's own battery-validation list that genuinely have none.

## 6. Coverage and honesty about this pass

Verified directly: the whole Photos domain, the `App/`, `Hikes/` and
`Settings/` screens, all markdown documentation, CI workflow, scripts, the test
plan, the shared package, the widget, every `accessibilityIdentifier` in the
app cross-referenced against the UI test bundle, every ``…`` DocC reference in
all Swift files cross-referenced against declared symbols, a whole-tree
unused-symbol sweep, and the Map, Location, Weather and General domains.

**Reviewed less deeply:** `Recording/` only — beyond the dead code removed on
this pass, one corrected comment and the `RouteMotion` write in §1. Its
delegated deep-dive never returned, so it has had a targeted mechanical pass —
dangling doc links, dead symbols, settings-key read/write audit — rather than a
line-by-line reading. A follow-up pass should start there, and nowhere else is
outstanding.

*That follow-up happened on 2026-08-25 and is recorded below. `Recording/` is
no longer the outstanding domain; it is where two of that pass's three
High-severity findings came from.*

Everything above rests on a single reading plus verification against the
source, which is why every claim cites the line it came from.

---

# Review pass — 2026-08-25

Scope: the `Recording/` domain the previous pass named as outstanding, plus
`Tiles/`, `Photos/` and `Weather/`, plus a reconciliation of this document and
`PERFORMANCE.md` against the code they describe.

Method, and the reason the sections below are shorter than the last pass's:
**every claim inherited from the previous pass was re-checked before being
kept, and every claim produced by this one was re-checked before being
written.** Two delegated domain reviews contributed candidates; none of their
findings were written down until the cited code had been read directly. Several
did not survive that, and are not here.

Where a fix was made, a test that fails against the unfixed source was written
first wherever the bug was reachable from one. Three were not reachable — the
tile-renderer re-arm needs a draw pass, the DocC links need a documentation
build, and the logging change has nothing to assert — and are marked as
verified by inspection.

## A. What was fixed

Following this file's own rule, each of these is recorded once here and its
finding is not carried forward.

### 1. `BackgroundTrailTracker` silently killed the live widget feed (High)

Three defects in one method, the first of which is the one nobody had noticed.

`hikeSelectionChanged(to:)` assigns `trackedHikeID = hike?.id` at the top, then
guards its degenerate-hike branch on `trackedHikeID == nil`. For a hike with
one point that guard is *false*, so the method returned early — after
`SharedStore.clear()` but before `TrailBasemapRenderer.invalidate()` and
`WidgetCenter.reloadTimelines()`. Worse, it returned leaving `selectionPublishTask`
non-nil, and `publishLiveFix` reads a non-nil handle as "a snapshot is landing,
don't race it". A single-point hike therefore stopped the widget receiving live
fixes for as long as it stayed selected. The guard now compares against the
selection actually being cleared.

The handle was leaked on every path, not just that one: it was cleared only on
the two success paths. It is now released in a revision-guarded `defer` on both
tasks, so cancellation and failure release it too, and a stale task cannot
clear a newer task's handle.

`waitForSelectionPublish()` awaited whatever `selectionPublishTask` held when
it was called. A selection landing mid-wait cancels that task, which then
returns through its own guards almost immediately — so the wait resolved
*earlier* than an undisturbed one, which is the opposite of what its only
production caller (`HikeDetailView.swift:253`) wants: it awaits specifically so
a first fix cannot be overwritten by the trail's initial snapshot. It now loops
until `selectionRevision` stops moving.

This settles the previous pass's `UNVERIFIED` item, which was correct as far as
it went and understated the consequence.

*Tests:* `WidgetFeedTests.degenerateHikeClears` extended, and
`waitSpansASelectionArrivingMidWait` added. Both were run against the unfixed
source and both failed.

### 2. One untrusted fix disabled barometric elevation for a whole hike (High)

`RecordingElevationFilter.elevation(for:)` committed `relativeAnchor` before
`guard let gpsAltitude else { return nil }`. A cold-start fix whose vertical
accuracy is past the 15 m limit — the ordinary case in the first seconds
outdoors, and CoreMotion is usually already reporting by then — left the filter
with a relative anchor and no elevation anchor. Every later call then took
`guard let elevationAnchor else { return gpsAltitude }`, a path that never
assigns an anchor, so the filter never recovered: raw GPS altitude for the rest
of the recording, and the barometer's contribution silently discarded.
`resume()` re-entered the same trap, because it restarts from a `nil` elevation.

The anchor is now committed only once there is an absolute reference to pair it
with.

*Test:* `RecordingElevationTests.untrustedFirstFixDoesNotDisableFusion`. Against
the unfixed source it reports 602 m where the barometer says 650 m — a 48 m
error on a single leg, compounding across a hike's gain and loss.

### 3. A tile deep in backoff could lose its retry timer for good (Medium)

`CachingTileOverlayRenderer.scheduleRetryWake()` had exactly one call site: the
failure branch. But the wake task clears its own handle when it fires, so
consider two tiles, one 5 s into backoff and one 5 minutes in. The 5 s wake
fires and clears itself; the redraw it triggers loads that tile successfully,
recording no new failure; nothing re-arms. The 5-minute tile now has no timer
behind it and stays a hole in the map until the user pans or the network
reconnects — which is precisely the situation `TileRetryTests`' header says the
retry log exists to fix.

Re-arming now happens at the end of every draw pass, making the invariant
unconditional: after any draw, the soonest surviving deadline has a timer on
it. That required `TileFailureLog.earliestRetry(after:)` to exclude deadlines
already in the past, because a draw pass asks while the tiles that just came
due are still in flight, and a wake scheduled for a past instant fires
immediately, redraws, and finds the same past deadline — one redraw per draw,
the exact loop the backoff exists to prevent.

*Tests:* `TileRetryTests.pastDeadlinesAreExcluded` and
`aDeepBackoffKeepsItsDeadlineWhenAShallowOneSucceeds`. The renderer's own
re-arm is verified by inspection; it needs a draw pass to exercise.

### 4. The photo thumbnail cache was bounded by count, not bytes (Medium)

`HikePhotoStore`'s `NSCache` had `countLimit = 200` and no `totalCostLimit`,
and neither `setObject` call passed a cost. A thumbnail is decoded at 512 px
with `kCGImageSourceShouldCacheImmediately`, so it is held as an uncompressed
bitmap of roughly 0.75 MB rather than as the JPEG it came from: an effective
ceiling near 150 MB, sitting alongside `TileCache`'s own memory tier.

This is the pattern `TileCache.swift:136-141` documents having explicitly
rejected — "a limit expressed in images says nothing about the resource being
spent". The tier is now bounded at 32 MB of decoded bytes, measured through the
existing `TileCache.decodedByteCost(of:)` rather than a second copy of it, and
inserted through a single private method so no future call site can forget the
cost and exempt its entries.

### 5. `WeatherManager` swallowed every failure (Medium)

The file contained no `Logger` at all, and every WeatherKit failure mode —
network, entitlement, quota, decode — collapsed into `return false`. A user
whose weather never appears produced no evidence anywhere. It now logs the
error. Verified by inspection; there is no behavioural assertion to make.

### 6. Deleting a pushed hike was a rule with no name (Low)

The gap table listed navigation cleanup as unguarded, and it was — but the
reason was that the rule lived inline in `MapSheet.delete(_:among:)`, so the
test that existed had to *mirror* it, and said so in a caveat. The rule is now
`SheetRoute.removeHike(_:selectedHike:from:)` and `HikeDeletionTests` calls it
directly, with a third case added for a hike that is pushed but not selected.
The gap-table row is deleted rather than reworded.

### 7. Smaller confirmed defects

- **An unreachable branch.** `HikeRecorder.dismissFailure()` guards on
  `!canRetrySave`, and `canRetrySave` is `pendingPreparedSave != nil ||
  pendingReviewSave != nil`. Past that guard `pendingReviewSave` is necessarily
  nil, so the `else if pendingReviewSave != nil { phase = .reviewing }` below it
  could never be taken. Removed, with the reasoning left in its place.
- **Five broken DocC references.** ``loadTile(forKey:url:)`` at
  `TileCache.swift:174`, `:419` and `:638` — the declaration takes a `purpose:`
  and line 428 gets it right. ``AutoSaveController/activate(hike:)`` in
  `AutoSaveTileStore.swift`, which is really a `private func activate(_:)` and
  so cannot be linked from another type at all. ``byteCount(of:)-(_)`` in
  `HikePhotoStore.swift`, whose disambiguator matches both overloads. The two
  unlinkable ones are now code voice rather than a link that promises to
  resolve and doesn't.
- **Two comments describing a gesture that does not exist.**
  `ElevationChartView.swift` explained a "drag target" and a hit area "kept on
  the same view as the gesture". There is no `DragGesture` anywhere in the app;
  scrubbing is `.chartXSelection(value:)`. Corrected here and in
  `PERFORMANCE.md`, where the same false premise had become a finding's stated
  cause.

### 8. A test that asserted something MapKit is allowed to violate (Low)

`MapCoordinatorTests.coalescingDoesNotCrossCommands` set the map to New York,
issued two `followUser()` commands, and asserted the centre was still New York
— reading that as "the route was not re-fitted". But `.follow` moves the map to
the user *by definition*, and the simulator's user is in San Francisco. The
assertion held only while the location fix had not arrived yet, and adding five
tests elsewhere in the bundle was enough to lose that race: the failure was
`40.71 - 2.924166`, and 37.7858 is San Francisco, identical on every run.

Two changes. The route fixture moves to the Alps, 10° from any simulator
location, so "followed the user" and "re-fitted the route" become separable and
the assertion means what it says. And the wait now names the effect it is
waiting for — `settleDelegateHop`'s condition form — instead of spinning a
fixed number of scheduler turns, which is the anti-pattern
`OpenHikesTests/General/SettleSupport.swift` was written to eliminate and which
this call site had never been converted to. Confirmed by running the full
bundle four times before and after.

## B. Corrections to this document and to `PERFORMANCE.md`

Recorded rather than quietly edited, because a review document that is wrong
about the code is the failure mode both of these files exist to avoid, and
because knowing *how* they drifted is what stops it happening again.

| Claim | Status |
|---|---|
| "227 first-party Swift files and 51,218 lines" | Wrong. 236 files, 53,675 lines. |
| §2: "There is also no launch argument to seed a hike with photos" | **Wrong, and contradicted by this repo's own other document** — `PERFORMANCE.md` describes `--ui-test-seed-photos` as an implemented finding. The hook exists. §2 rewritten. |
| §2's list of identifiers "defined and never driven" | Stale in four of seven: `photos-section` no longer exists at all, and `photo-viewer`, `hike-photo-strip` and `map-camera-button` are now driven. List recomputed. |
| Gap table: "Widget deep-link branches … are unguarded" | Overstated. The routing rules are covered in three suites; only the private `View` call site is not. Row reworded. |
| Gap table: "Deleting a currently pushed hike … Navigation cleanup is unguarded" | Was true, is now false. Row deleted; see §A.6. |
| §1: `SearchCompleter.swift:17` | Wrong line. It is `:23`. |
| §1's `UNVERIFIED` note on `waitForSelectionPublish()` | Confirmed true, and understated. Fixed; see §A.1. |
| `PERFORMANCE.md` Finding 4: "The gesture is drag-only" | The stated cause is false — there is no hand-written gesture in the app. The *symptom* is not resolved and the finding stays open with its cause marked unknown. |
| `PERFORMANCE.md`: "Audit the app for any remaining periodic work" | Now performed; result recorded there. |

Claims that were checked and **survived**: no `.xcstrings` catalog exists;
`Scripts/perf-report.py` still has no `--baseline`; `OfflineTileDownloader+Planning.swift`
and `TileCache+StorageManagement.swift` still carry no signposts (the whole
`Tiles/` tree has them only in `TileCache.swift`); `isIdleTimerDisabled` is
never set; `SearchCompleter` and `MainThreadWatchdog` genuinely lack a seam;
`WeatherManager`, `TrailBasemapRenderer` and `TopEdgeReader` have no test
references; and all four §4 test seams still exist.

## C. Verified, open, deliberately not fixed

Each of these was reproduced or confirmed by reading the code. None is fixed,
and in every case the reason is that the right fix is a design decision rather
than a correction.

### 1. A cancelled trail-graph prefetch keeps running (Medium)

`cancelTrailGraphPrefetches()` cancels the recorder's wrapper tasks, but each
wrapper awaits `OverpassTrailGraphProvider.prefetch(around:)`, which awaits
`task.value` on an **unstructured** `Task` stored in `inFlight`. Unstructured
tasks do not inherit cancellation, so the network fetch continues, and the
`write` and `trimCache` that follow it run after the user stopped recording.
The entry also stays in `inFlight`, because the cleanup lives in the awaiting
path rather than in the task.

Why it is not a drive-by fix: `inFlight` exists to deduplicate, so a second
caller may legitimately be awaiting the same key, and cancelling on one
caller's behalf would break the other. Doing this correctly needs reference
counting, or a provider-level cancellation entry point that the protocol and
both other providers would have to gain.

Note for whoever takes it: `trailGraphPrefetchStopsWithRecording` passes today
only because the test stub awaits cancellably. It does not cover the real
provider.

### 2. `showReview` bumps its change tokens unconditionally (Low)

`RecordingObservables` documents its tokens as "Bumped only on a real change —
a token that moved for an identical geometry would defeat its own purpose", and
the live-recording paths honour that carefully. `showReview(route:highlightedSegment:)`
does not: it calls `replace(with:)`, which bumps `generation` and `revision`
unconditionally, then bumps `reviewRevision` and `revision` again. Re-tapping
the already-selected option in the route review therefore rebuilds every
`MKPolyline` to draw identical geometry.

Low severity — it is one tap, not a hot path — but it contradicts the
invariant the file states, and the cheap fix (guard `selectRouteChoice` on the
choice actually changing) is narrower than the correct one (give `replace` the
same change detection the other paths have).

### 3. Nineteen bare `settle()` calls remain in the map suites (Low)

§A.8 fixed the one that failed. The same condition-less `settleDelegateHop()`
is used at 19 other call sites in `MapCoordinatorTests` and its extensions,
each buying an amount of progress that depends on machine load. They pass
today. Converting them needs a per-call-site judgement about which effect to
name, and a wrong condition is worse than none, so this is listed rather than
done in bulk.

### 4. `RecordingSessionOptions` is a placeholder with tautological tests (Low)

The type is an **empty struct**. `load(from defaults: UserDefaults)` ignores
its parameter and returns `Self()`. It is written into every journal file as
`TrackJournalMetadata.recordingOptions` and read by nothing. Two tests assert
things that cannot fail: `RecordingSettingsTests.defaults` compares an empty
struct to an empty struct, as does `TrackJournalTests`' round-trip assertion.

Not removed, because it is a persisted `Codable` field and this is the same
shape of question as `RouteMotion` — a placeholder for intended work is a
product decision, not dead code, and the previous pass established that the
answer gets recorded on the type. The decision is: either give it a field and a
real `load`, or delete it and the two tests with it. Leaving it as an empty
struct with a parameter it ignores is the only option that is wrong.

## D. Coverage and honesty about this pass

Read directly and in full: `BackgroundTrailTracker`, `RecordingSensors`,
`TileFailureLog`, `CachingTileOverlayRenderer`'s retry path, `HikePhotoStore`'s
caching tier, `WeatherManager`, `HikeRecorder`'s failure and review lifecycle,
`RecordingObservables`, `OverpassTrailGraphProvider`'s prefetch path,
`SheetRoute`/`MapSheet` deletion, `ElevationChartView`'s selection path, and
both markdown documents end to end. Re-derived mechanically: file and line
counts, the `accessibilityIdentifier` cross-reference, the DocC symbol
cross-reference in the files touched, and an audit of every periodic timer in
the app.

**Not re-verified on this pass:** the domains the 2026-08-16 pass covered
deeply and this one had no reason to re-open — `App/`, `Settings/`, the widget,
the shared package, CI and the scripts. Their findings above are inherited, not
re-confirmed, with the specific exceptions listed in §B.

**Not run:** UI automation, the performance suite, and any physical-device
measurement. Both suites need a booted simulator and stable hardware, both are
out of CI by design, and no claim above rests on either.

What was run, four times over for the app bundle to distinguish a fix from a
coincidence: 779 app tests in 91 suites, 19 widget tests in 3 suites, 57
shared-package tests in 9 suites, and strict SwiftLint. All green.
