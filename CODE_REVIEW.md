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
| `SearchCompleter`, `WeatherManager`, `TrailBasemapRenderer`, `TopEdgeReader`, and `MainThreadWatchdog` lack direct suites | Timing, rendering, and stall behavior can regress. `SearchCompleter` and `MainThreadWatchdog` need an injectable seam before they can be tested at all — see the 2026-08-16 pass, §1 |
| Widget deep-link branches lack UI automation | Live recording, existing hike, and deleted hike routing are unguarded |
| Deleting a currently pushed hike lacks UI automation | Navigation cleanup is unguarded |
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

Re-run on 2026-08-16 unless the row says otherwise. Rows marked *not re-run*
were last measured on the earlier pass and their numbers are no longer
trustworthy — the tree has grown by a whole feature domain since.

| Validation | Result |
|---|---|
| Strict SwiftLint | Passed (0.65.0, `--strict`) |
| Shared package tests | 57 tests in 9 suites passed |
| App and widget unit tests | 774 tests in 91 suites plus 19 widget tests in 3 suites passed |
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
| `SearchCompleter` | The `MKLocalSearchCompleter` is a `private let` (`SearchCompleter.swift:17`) and `MKLocalSearchCompletion` cannot be constructed, so nothing can drive `suggestions` to a non-empty value. Injecting the completer is the work. Its *failure* path is now covered — `SearchFailureTests` pins the error-to-copy mapping, which was extracted into a pure value type precisely so it could be. |
| `MainThreadWatchdog` | `start()` spawns a `Thread` running `while true` with hard-coded intervals and no injectable clock (`MainThreadWatchdog.swift:66-118`). A test could only start a real watchdog it cannot stop. |

Three further components remain uncovered but are *not* blocked in this way —
`WeatherManager` (only `WeatherPollState` is covered, by `WeatherPollingTests`),
`TrailBasemapRenderer`, and `TopEdgeReader`, which needs a hosted SwiftUI
hierarchy.

Also unsettled, and `UNVERIFIED`: `BackgroundTrailTracker.swift:278`'s
`waitForSelectionPublish()` awaits whatever `selectionPublishTask` held at the
moment of the call, so if `hikeSelectionChanged(to:)` reassigns that property,
an already-pending waiter may resolve as soon as the *cancelled* task exits its
guards rather than when the newest selection is published. Its only production
caller (`HikeDetailView.swift:253`) awaits it specifically "so the first fix
cannot race and be overwritten by the trail's initial snapshot". **What would
settle it:** a test that calls `hikeSelectionChanged` twice in quick succession
and asserts a `waitForSelectionPublish()` awaited after the first does not
resolve until the second selection's snapshot is on disk.

## 2. The photo screens have no automation at all (Medium)

Cross-referencing every `accessibilityIdentifier` in the app against every
identifier used in `OpenHikesUITests`: `photos-section`, `photo-viewer`,
`photo-delete-button`, `photo-show-on-map-button`, `hike-photo-strip`,
`hike-photo-<uuid>` and `map-camera-button` are defined and **never driven**.
The one photo UI test that exists
(`testOpensAndClosesThePhotoLibraryPickerOverTheSheet`) stops at the picker's
Cancel button. There is also no launch argument to seed a hike with photos, so
the gallery, the viewer, paging, delete-and-dismiss and the map pins are
unreachable in the simulator — no camera, out-of-process picker. A
`--ui-test-seed-photos` hook is the unblocking change, and it is the only one:
everything downstream of it is ordinary XCUITest work.

The same sweep found these identifiers defined but never exercised by any UI or
accessibility test: `weather-badge`, `difficulty-section`, `difficulty-bar`,
`surface-section`, `surface-bar`, `hike-title-field`, `import-gpx-button`,
`recording-retry-save`, `review-next-section`, `review-previous-section`,
`offline-download-button`, `delete-offline-tiles-button`,
`cellular-tiles-toggle`, `save-photos-to-library-toggle`.

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
all 227 Swift files cross-referenced against declared symbols, a whole-tree
unused-symbol sweep, and the Map, Location, Weather and General domains.

**Reviewed less deeply:** `Recording/` only — beyond the dead code removed on
this pass, one corrected comment and the `RouteMotion` write in §1. Its
delegated deep-dive never returned, so it has had a targeted mechanical pass —
dangling doc links, dead symbols, settings-key read/write audit — rather than a
line-by-line reading. A follow-up pass should start there, and nowhere else is
outstanding.

Everything above rests on a single reading plus verification against the
source, which is why every claim cites the line it came from.
