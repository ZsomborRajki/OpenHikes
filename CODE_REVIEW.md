# OpenTrails code review

Originally reviewed at `fd12790` on 2026-08-14 with Xcode 26.6 and an
iOS 26.5 iPhone 17 Pro simulator. P1 and P2 remediation was verified on
2026-08-14.

All P1 and P2 findings have been resolved and removed from this open-issues
document. The remaining P3 findings retain their original numbers so references
to the initial review remain stable.

The current tree contains 160 Swift files and 38,207 lines, plus project and
package configuration, scripts, entitlements, tests, and documentation. The
review focuses on correctness, concurrency, maintainability, current API use,
and especially battery, radio, CPU, and disk activity during a hike.

Priority meanings:

- **P1:** high user impact, sustained energy drain, or data-loss/error-recovery risk.
- **P2:** important correctness, concurrency, performance, or build reliability issue.
- **P3:** bounded issue, refactor, test gap, or measurement-driven optimization.

There are no outstanding P0, P1, or P2 findings. The recording pipeline is
generally disciplined: location and sensor lifetimes are explicit, matching
work is bounded and off-main, weather polling is backoff-driven, widget
sampling is sparse, and the tile pipeline has useful concurrency limits.

## P3 findings and refactors

### 15. `MapSheet` likely observes more SwiftData changes than it renders

**Evidence:** `OpenTrails/Map/MapSheet.swift:42-43`.

Its broad `@Query` returns full `Hike` models. Route-style writes and tile-key
updates can therefore invalidate the sheet even though rows do not render those
fields. This is plausible from SwiftData's observation model but should be
measured before redesigning.

**Action:** add the sheet-isolation test already proposed by the repository,
then narrow the observed projection only if the test confirms invalidation.

### 16. Per-key tile mutation versions grow for the process lifetime

**Evidence:** `OpenTrails/Tiles/Cache/TileCache+StorageManagement.swift:217-232`,
`OpenTrails/Tiles/Cache/TileCache.swift:167-174`.

Every deleted key increments an entry that is never removed. A deletion-heavy
session can add thousands of entries per hike.

**Action:** use a global epoch for broad deletion or implement safe compaction.
Do not simply clear entries, because that can make an old token valid again.

### 17. Rapid map commands can fall into an observation re-arm gap

**Evidence:** `OpenTrails/Map/MapCoordinator.swift:108-134` and sibling
observers.

`withObservationTracking` fires once. Re-arming happens after a dispatched
main-actor task, so two changes in one run-loop turn can lose the second
notification. Current commands are mostly idempotent, limiting impact.

**Action:** re-arm before the async hop or re-check the latest request counter
after re-arming. Add a two-mutations-in-one-turn test.

### 18. Hike detail preparation performs two full route walks

**Evidence:** `OpenTrails/Hikes/HikeDetailView.swift:31-36`.

Statistics and `RouteProfile` independently calculate per-segment distances.
This is already off-main and cancellable, so it is a latency/CPU refactor rather
than UI correctness work.

**Action:** produce both outputs in one pass and share cumulative distances.

### 19. Convenience statistics recompute the route on every property read

**Evidence:** `OpenTrails/Hikes/Hike+Statistics.swift:180-205`.

Each convenience property rebuilds `HikeRouteStatistics`. Production currently
uses the prepared off-main statistics instead, making this mostly unused and a
future footgun.

**Action:** remove the unused properties or cache a versioned statistics value.

### 20. Two foreground location managers duplicate software work

`LocationManager` and `SystemRecordingLocationSource` both receive updates
during an active recording. iOS coalesces same-process location demand, so this
does not imply twice the GPS hardware power, but it does duplicate delegates,
authorization handling, and actor hops.

**Action:** keep the separation unless profiling shows meaningful CPU overhead;
its lifecycle isolation is valuable. If consolidated later, preserve the
recording manager's independent background semantics.

### 21. The auto-save controller wakes every two seconds while foregrounded

**Evidence:** `OpenTrails/Tiles/AutoSave/AutoSaveController.swift:45-56`.

The early-return work is small, so this is not a confirmed battery bug.
Nevertheless, the task wakes for the app's foreground lifetime even when no
hike is selected.

The interval is now injectable, and `nil` disables the timer — the tests take
that option, because a suspension-rollback assertion otherwise raced a
two-second production timer under a parallel run. That removes the test
dependency on wall-clock time; it does not address the foreground wakeups.

**Action:** measure wakeups in Energy Log. If visible, replace polling with an
event-driven drain plus a scheduled retry only while pending work exists.

## Test and project hygiene

The following open gaps remain:

| Gap | Impact |
|---|---|
| `SearchCompleter`, `WeatherManager`, `DirectionalPolylineRenderer`, `TrailBasemapRenderer`, `TopEdgeReader`, and `MainThreadWatchdog` lack direct suites | Timing, rendering, and stall behavior can regress |
| Widget deep-link branches lack UI automation | Live recording, existing hike, and deleted hike routing are unguarded |
| Deleting a currently pushed hike lacks UI automation | Navigation cleanup is unguarded |
| No `.xcstrings` catalog exists | Localization will require a broad later migration |

Strict SwiftLint passes, and every first-party Xcode target treats Swift
warnings as errors. The remaining warning debt is limited to duplicate
`@executable_path` runpath warnings emitted when Xcode links Thread Sanitizer
runtimes; normal debug and release builds are warning-free.

## API and dependency assessment

- Current iOS debug, iOS release, and macOS builds produce no deprecated-API
  diagnostics.
- No mandatory migration from the current MapKit, Core Location, WeatherKit,
  WidgetKit, SwiftData, or observation APIs was found.
- `swift-collections`, `swift-algorithms`, and `swift-async-algorithms` are used
  for appropriate problems and should remain.
- GPX import now uses the local Foundation XML parser. CoreGPX and its unsafe
  C-variadic date parser are no longer dependencies.
- No new third-party package is recommended. The important lifecycle,
  cancellation, retry, and ownership fixes are implemented locally.
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
thermal state, and disk writes. Add signposts around graph prefetch, live
matching, route projection, tile planning, and storage measurement. Compare
against the same device, route, screen state, and radio conditions rather than
using a universal percentage-per-hour target.

## Validation performed

| Validation | Result |
|---|---|
| Strict SwiftLint | Passed |
| Shared package tests | 51 tests in 8 suites passed with warnings treated as errors |
| App and widget unit tests | Passed with strict suite preconditions enabled |
| iOS debug build | Passed with first-party Swift warnings treated as errors |
| iOS release build | Passed with first-party Swift warnings treated as errors |
| macOS compile | Passed with code signing disabled |
| GPX Thread Sanitizer suite | Passed, including concurrent timestamp parsing |
| UI automation and launch metrics | All 6 tests passed, including record-review-save |
| Package resolution | Passed; CoreGPX is absent from `Package.resolved` |
| CI workflow | Added; equivalent local commands passed, hosted run awaits the next push |
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
