# OpenTrails code review

Reviewed at `fd12790` on 2026-08-14 with Xcode 26.6 and an iOS 26.5
iPhone 17 Pro simulator.

Remediation status was updated on 2026-08-14. Findings 1, 2, 3, and 11 are
resolved; the remaining P2 and P3 findings are still open. The evidence below
describes the reviewed revision, while each resolved finding records the
implemented change and its regression coverage.

This review covers all 156 tracked Swift files (36,628 lines), project and
package configuration, scripts, entitlements, tests, and every Markdown file.
It focuses on correctness, concurrency, maintainability, current API use, and
especially battery, radio, CPU, and disk activity during a hike.

Priority meanings:

- **P1:** high user impact, sustained energy drain, or data-loss/error-recovery risk.
- **P2:** important correctness, concurrency, performance, or build reliability issue.
- **P3:** bounded issue, refactor, test gap, or measurement-driven optimization.

There are no P0 findings. The recording pipeline is generally disciplined:
location and sensor lifetimes are explicit, matching work is bounded and
off-main, weather polling is backoff-driven, widget sampling is sparse, and the
tile pipeline has useful concurrency limits. The two largest battery risks
identified were network retry behavior during poor coverage and unnecessarily
precise foreground location tracking.

## P1 findings (resolved)

### 1. [Resolved] Overpass failures can retry on every accepted GPS fix

**Original evidence:** `OpenTrails/Recording/HikeRecorder+Lifecycle.swift:262-280`,
`OpenTrails/Recording/OverpassTrailGraphProvider.swift:136-175`.

`requestedGraphRegions` is cleared after every non-rate-limit failure. The next
accepted fix in the same region can therefore start the same request again.
HTTP 429 receives a cooldown, but offline errors, DNS failures, timeouts, 5xx
responses, and decode failures do not.

In weak mountain coverage this can repeatedly wake the cellular radio, perform
DNS/TCP/TLS work, and run a request with a 35-second timeout. Depending on how
quickly the network fails, retries can happen after successive 5-10 second
accepted fixes or after each timeout.

**Resolution:** `HikeRecorder` now keeps a state per trail-graph region,
including consecutive failures and the next eligible retry time. Ordinary
network, server, decode, storage, and rate-limit failures use capped
exponential backoff with jitter; a successful fetch marks the region loaded
and resets the failure run. `trailGraphFailuresBackOff` injects ordinary
offline failures and advances the recorder's test clock across two backoff
windows, while `trailGraphRetryPolicyBacksOff` verifies jitter and the ceiling.

### 2. [Resolved] Foreground map location uses best accuracy with no distance filter

**Original evidence:** `OpenTrails/Map/Location/LocationManager.swift:104-109`,
`OpenTrails/App/Navigation/OpenTrailsView.swift:158-159`,
`OpenTrails/App/OpenTrailsModel.swift:319-322`.

The app starts this manager whenever the root view appears. It requests
`kCLLocationAccuracyBest` and leaves `distanceFilter` at its no-filter default.
Publishing fixes only once per second does not reduce the work Core Location
does before delivery.

This manager serves map centering, live follow, and weather bucketing. Weather
uses roughly 1.1 km buckets, and ordinary map centering does not require
best-available GNSS accuracy. Recording already has a separate, correctly
tuned manager for the path that genuinely needs precise fixes.

**Resolution:** the foreground manager now starts with
`kCLLocationAccuracyNearestTenMeters` and a 25-meter distance filter. Its
Core Location source is injectable so the configuration and authorization
lifecycle are verified without hardware. No current foreground consumer
demonstrated a need for escalation; recording continues to use its separate
precise source. Physical-device energy measurement remains outstanding.

### 3. [Resolved] Recording save failures are swallowed and recovery offers discard

**Original evidence:** `OpenTrails/Recording/RecordingView.swift:360-369,399-407`,
`OpenTrails/Recording/RecordingRouteReviewControls.swift:77-86`,
`OpenTrails/Recording/HikeRecorder.swift:392-431`.

Both stop/save entry points use `try?` and return when an error is thrown.
`HikeRecorder` moves to `.failed`, but retains an active session. The failed
UI branch consequently offers **Discard Recording** rather than a retry even
when the completed review data is still available.

A transient SwiftData save failure can therefore turn a completed hike into a
discard-only state. The existing error alert does not provide a non-destructive
recovery path.

**Resolution:** both UI entry points now handle thrown errors explicitly.
`HikeRecorder` retains either the prepared direct-save payload or the review
payload and choices, exposes `retrySave()`, and keeps **Discard Recording** as
the secondary destructive action beneath **Retry Save**. An injected
model-context save seam verifies recovery after failures in both direct and
reviewed saves. Custom names are also held by the recorder and included in the
successful retry.

## P2 findings (finding 11 resolved; others open)

### 4. Live follow scans every route segment twice per fix

**Evidence:** `OpenTrails/Hikes/RouteProfile.swift:277-330`,
`OpenTrails/Hikes/HikeSupportingTypes.swift:148-165`,
`OpenTrails/Hikes/HikeDetailView.swift:548-562`.

`RouteProfile.nearestPoint` first scans all segments to find the best candidate,
then maps all segments through the same trig-heavy projection again for
`breakTie`. The call is main-actor isolated and runs for each live-follow fix.
Routes in the workload tests reach 18,000 points, while imports can be much
larger.

**Fix:** compute each candidate once. Reuse that result for the best candidate
and tie handling. Then bound the search around `referenceDistance` or use a
spatial/segment index so live follow does not scale with the entire route.

### 5. Auto-save activation remaps and sorts the full route on the main actor

**Evidence:** `OpenTrails/Tiles/AutoSave/AutoSaveController.swift:143-158`,
`OpenTrails/Hikes/HikeDetailView.swift:238,368`,
`OpenTrails/Hikes/Hike+Presentation.swift:69-71`,
`OpenTrails/Tiles/SlippyTileMath.swift`.

Opening an auto-save-enabled hike or toggling auto-save synchronously converts
the complete persisted route to coordinates and builds a corridor whose
bounding-box work sorts longitudes. This duplicates work already avoided in the
map path by `DisplayedRouteCoordinateCache`.

**Fix:** reuse the coordinate cache or construct the coordinates and corridor
in cancellable off-main work before applying the active selection.

### 6. Offline-download planning blocks the tap's main-actor turn

**Evidence:** `OpenTrails/Hikes/HikeDetailView.swift:320-321`,
`OpenTrails/Tiles/Offline/OfflineTileDownloader.swift:94-105`.

The button synchronously remaps the complete route and calculates tiles across
all configured zoom levels before the downloader creates its asynchronous task.
Planning can cover up to the 4,000-tile budget.

**Fix:** move coordinate conversion and `tiles(covering:)` into cancellable
utility-priority work. Publish only the resulting plan and progress on the main
actor.

### 7. Trail-graph prefetch tasks outlive the recording

**Evidence:** `OpenTrails/Recording/HikeRecorder+Lifecycle.swift:267-278`,
`OpenTrails/Recording/HikeRecorder+Persistence.swift:353-390`.

Each region prefetch is an untracked `Task`. Stop, fail, discard, and reset
clear bookkeeping but cannot cancel an in-flight request. A request may
therefore continue for up to its timeout after the recording no longer needs
the result.

**Fix:** store one task per region and cancel all of them during every terminal
or reset transition.

### 8. Cancelled storage measurements continue scanning disk

**Evidence:** `OpenTrails/Hikes/HikeDetailView+OfflineStorage.swift:31-47`,
`OpenTrails/Tiles/Cache/TileCache+StorageManagement.swift:62-70`.

The view cancels an outer task, but that task awaits an independent
`Task.detached`. Cancellation does not propagate into the detached task, and
the synchronous file-size loop has no cancellation checks. Rapid refreshes or
leaving the screen can leave stale scans of thousands of files running to
completion before their results are discarded.

**Fix:** retain and cancel the actual worker task, and check cancellation during
key enumeration and byte measurement.

### 9. The default URL cache can duplicate the custom tile cache

**Evidence:** `OpenTrails/Tiles/Cache/TileCache.swift:224-228`.

The tile session starts from `URLSessionConfiguration.default` and does not
disable `URLCache`. Cacheable provider responses may therefore be written both
to Foundation's unaccounted cache and to OpenTrails' own memory, ephemeral, and
durable tiers. Settings cannot measure or reclaim Foundation's copy.

**Fix:** use an ephemeral configuration or set `urlCache = nil` and an explicit
request cache policy. The custom tile cache already owns this responsibility.

### 10. CoreGPX's current date parser is unsafe and blocks sanitizer-clean tests

**Evidence:** CoreGPX 0.9.4, `Classes/DateTimeParsers.swift`; revision
`58d9a7f`. `OpenTrailsTests/Hikes/GPXImportTests.swift:18-19`.

CoreGPX allocates raw integer pointers, passes them through
`withVaList`/`vsscanf`, does not initialize them, and does not validate the
number of matched fields before reading them. Each `%d` conversion writes a
32-bit C `int` into storage allocated as a 64-bit Swift `Int`, leaving the upper
bytes undefined before the full-width value is read. It also reduces an
ISO-8601 value to six integers and reconstructs it as UTC, so timestamps with
explicit non-UTC offsets cannot be represented correctly.

Observed behavior:

- The normal GPX suite passes.
- Under Thread Sanitizer, the parallel suite deterministically loses timestamps
  in `loadsTrackPoints`, `startTimeFromMetadata`, and
  `startTimeFromFirstPoint`.
- Each failing test passes alone.
- Making CoreGPX's calendar per-instance does not help.
- Replacing only the raw `vsscanf` date path with
  `ISO8601DateFormatter().date(from:)` makes the complete suite pass under TSan.

CoreGPX 0.9.4 is the latest release, so a package update does not resolve this.
The shipping app currently imports one file at a time, which limits production
exposure, but parallel tests and any future batch import are unsafe.

**Fix:** serialize GPX-import tests as an immediate containment measure. Submit
an upstream patch replacing the C-variadic parser with Foundation's ISO-8601
parse strategy and add offset/fractional-second tests. If upstream cannot take
the fix, use a small maintained fork or override CoreGPX's parsed date strings
inside the app; adding another GPX package is not yet justified.

### 11. [Resolved with finding 3] Reviewed custom names rely on eventual SwiftData autosave

**Original evidence:** `OpenTrails/Recording/HikeRecorder+Persistence.swift:129-181`,
`OpenTrails/Recording/RecordingView.swift:412-415`.

The model context is explicitly saved before the view applies `customName`.
There is no explicit save after that mutation, leaving a termination window in
which the hike exists but the user-entered name may not be durable.

**Resolution:** the stop API now accepts and normalizes the custom name, carries
it through direct or reviewed pending-save state, and applies it before the
explicit final context save. Both injected-failure regression tests reload the
saved hike through a fresh `ModelContext` and verify the name is durable.

### 12. Target actor-isolation settings disagree

**Evidence:** `OpenTrails.xcodeproj/project.pbxproj`,
`OpenWidget/TrailWidget.swift:548`,
`OpenWidgetTests/TrailWidgetTests.swift:440-454`.

All targets use Swift 6 and complete strict concurrency, but only `OpenTrails`
and `OpenTrailsTests` set
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. It is unset for
`OpenWidgetExtension`, `OpenWidgetTests`, and `OpenTrailsUITests`.

The drift is already observable: Xcode 26.6 warns when nonisolated widget tests
read `TrailWidget.supportedFamilies`, which is main-actor isolated through the
`Widget` protocol.

**Fix:** set the same default isolation on the three remaining UI targets, then
mark intentionally off-main declarations explicitly rather than relying on
target-specific interpretation.

### 13. The recording review UI test clears text from an assumed caret position

**Evidence:** `OpenTrailsUITests/OpenTrailsUITests.swift:148,307-325`.

The helper taps a pre-filled field and sends `draft.count` backspaces. A center
tap places the caret in the middle, so only the prefix is deleted. The test then
types `Reviewed Route` before the untouched date suffix and saves
`Reviewed Route14. Aug 2026`.

The app correctly navigates to that exact saved name; the test waits for the
nonexistent exact title `Reviewed Route`. This failure reproduced through the
full scheme, a targeted `xcodebuild` invocation, and
`Scripts/run-ui-tests.sh`.

**Fix:** select all before deleting/typing, and assert the field's value before
tapping save.

### 14. No continuous integration gate exists

`.github/workflows/` is absent. Current build, strict-concurrency, lint, package,
cross-platform, App Group, sanitizer, and UI-test behavior can regress without
blocking a pull request.

At minimum, CI should run:

| Job | Required behavior |
|---|---|
| iOS debug and release builds | App and embedded widget, signing configured appropriately |
| App/widget tests | App Group available and strict suite preconditions enabled |
| Shared package tests | `swift test --package-path OpenTrailsShared` |
| SwiftLint | `swiftlint lint --strict` |
| macOS compile | Catch cross-platform guard regressions |
| Targeted TSan | Serialize GPX tests until CoreGPX is patched |
| UI smoke tests | Include the record-review-save flow after fixing its helper |

## P3 findings and refactors

### 15. `MapSheet` likely observes more SwiftData changes than it renders

**Evidence:** `OpenTrails/Map/MapSheet.swift:41-42`.

Its broad `@Query` returns full `Hike` models. Route-style writes and tile-key
updates can therefore invalidate the sheet even though rows do not render those
fields. This is plausible from SwiftData's observation model but should be
measured before redesigning.

**Action:** add the sheet-isolation test already proposed by the repository,
then narrow the observed projection only if the test confirms invalidation.

### 16. Per-key tile mutation versions grow for the process lifetime

**Evidence:** `OpenTrails/Tiles/Cache/TileCache+StorageManagement.swift:203-215`,
`OpenTrails/Tiles/Cache/TileCache.swift:163-174`.

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

**Evidence:** `OpenTrails/Hikes/HikeDetailView.swift:23-30`.

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

**Evidence:** `OpenTrails/Tiles/AutoSave/AutoSaveController.swift:36-42`.

The early-return work is small, so this is not a confirmed battery bug.
Nevertheless, the task wakes for the app's foreground lifetime even when no
hike is selected.

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

Current warning debt:

- `swiftlint lint --strict` fails at
  `OpenTrails/Map/Rendering/RouteLinePattern.swift:46`; use `[Self]`.
- Widget tests emit main-actor isolation warnings described in finding 12.
- Test code at `OfflineTileDownloaderTests.swift:503` retains obsolete
  `?? []` on a non-optional array.
- Several test-target runpath settings duplicate inherited entries, producing
  duplicate `@executable_path` warnings under sanitizer builds.

## API and dependency assessment

- Xcode 26.6 produced no deprecated-API diagnostics in iOS debug, iOS release,
  macOS, or static-analyzer builds.
- No mandatory migration from the current MapKit, Core Location, WeatherKit,
  WidgetKit, SwiftData, or observation APIs was found.
- `swift-collections`, `swift-algorithms`, and `swift-async-algorithms` are used
  for appropriate problems and should remain.
- CoreGPX is current, not merely outdated, but finding 10 warrants an upstream
  patch or narrow fork.
- No new third-party package is recommended. The important fixes are lifecycle,
  cancellation, retry, and ownership changes that another dependency would not
  solve.
- For battery telemetry, prefer native Instruments, signposts, and current
  MetricKit reporting rather than an analytics SDK that adds its own network
  and background cost.

## Battery validation plan

Static review can identify unnecessary work but cannot certify battery life.
Run these scenarios on a physical device with a fixed route and compare before
and after the P1/P2 energy fixes:

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

### P1 remediation validation

| Validation | Result |
|---|---|
| Recorder and foreground-location regression suites | 54 tests in 3 suites passed |
| macOS cross-platform compile | Passed with code signing disabled |
| New warning debt | None; the existing `RouteLinePattern.swift` warning remains |
| Physical-device energy trace | Not run |

### Original review validation

| Validation | Result |
|---|---|
| Shared package tests | 51 tests in 8 suites passed |
| App and widget unit tests | 563 tests passed |
| iOS debug build | Passed |
| iOS release build | Passed |
| macOS build | Passed |
| Xcode static analyzer | Passed |
| Recording review UI test | Failed consistently because of finding 13 |
| SwiftLint strict | Failed with one violation |
| TSan GPX suite | Exposed finding 10 |
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
