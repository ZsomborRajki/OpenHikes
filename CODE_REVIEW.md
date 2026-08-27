# OpenHikes code review

The tree holds 166 first-party Swift files and 37,400 lines of shipping code,
plus 122 test files, project and package configuration, scripts, entitlements
and documentation. Review focuses on correctness, concurrency, maintainability,
current API use, and especially battery, radio, CPU and disk activity during a
hike.

**This document is a live list, not a log.** A finding is only useful while it
is true, so a fixed one is deleted rather than annotated, and a claim that
stopped matching the code is deleted whether or not anything was done about it.
What stays is what someone picking the app up next has to know: what is still
wrong, what was deliberately left alone and why, and what has already been
checked so it is not re-raised.

## Open findings

### 1. Two absence assertions still wait on a fixed sleep (Low)

`OpenHikesTests/Recording/HikeRecorderTests+Sensors.swift:208`,
`OpenHikesTests/Recording/HikeRecorderTests+Sensors.swift:286`

Every other wait in the app-hosted bundles is now either synchronous or a
`settleDelegateHop(until:)` naming the effect it expects. These two are not,
because they assert an *absence* — that a widget fix arriving during review is
not merged, and that a neighbour sweep does not happen — and there is no state
transition to wait for. A sleep is the wrong tool anyway: it makes the suite
slower on every green run and still cannot prove the thing never happens, only
that it had not happened yet.

The fix is a read counter on `StubRecordingSharedStateStore` and
`StubTrailGraphProvider` (`OpenHikesTests/Recording/HikeRecorderTests.swift`,
`OpenHikesTests/Recording/TrailGraphProviderStubs.swift`): wait for the
*positive* barrier that must happen after the thing being denied, then assert
the counter never moved. That converts both from "wait and hope" to a real
ordering guarantee.

`ObservationCounter.settle()` in `RenderIsolationTests.swift` is deliberately
left bare and is not part of this — see "Checked and deliberately left alone".

## Test and project hygiene

| Gap | Impact |
|---|---|
| `SearchCompleter`, `WeatherManager`, `TrailBasemapRenderer`, `TopEdgeReader` and `MainThreadWatchdog` lack direct suites | Timing, rendering and stall behaviour can regress. `SearchCompleter` and `MainThreadWatchdog` need an injectable seam before they can be tested at all |
| Widget deep-link branches lack UI automation | The *routing rules* are covered — `TrailWidgetDeepLinkTests` for URL round-tripping and `.recording` vs `.hike`, `SheetRouteTests` for the recording branch's effect, `HikeDeletionTests.deepLinkToDeletedHikeResolvesToNothing` for the deleted one. What is unguarded is only the call site, `openWidgetLink`/`openHike`, which are private `View` methods |
| No `.xcstrings` catalog exists | Localization will require a broad later migration |
| `Scripts/perf-report.py` has no `--baseline` | Every performance report is read in isolation; a regression against `PERFORMANCE.md`'s numbers has to be spotted by eye |

Strict SwiftLint passes, and every first-party Xcode target treats Swift
warnings as errors. The remaining warning debt is limited to duplicate
`@executable_path` runpath warnings emitted when Xcode links Thread Sanitizer
runtimes; normal debug and release builds are warning-free.

## Battery validation plan

Static review can identify unnecessary work but cannot certify battery life.
Run these scenarios on a physical device with a fixed route:

1. Foreground map browsing and live follow without recording.
2. Screen-locked background recording with normal connectivity.
3. Screen-locked recording with no service or a failing Overpass endpoint.
4. A 20-minute stationary pause.
5. Auto-save and a maximum-budget offline download.

Capture Energy Log/Power Profiler, Location activity, Network, CPU wakeups,
thermal state and disk writes. Live matching, GPX parsing, location publication,
recording-trace rebuilds, Overpass graph prefetch, offline download planning and
every tile storage scan carry signposts, and `PerformanceLog` writes them to a
TSV alongside CPU and footprint samples under `--ui-test-performance-log=`.
Compare against the same device, route, screen state and radio conditions rather
than against a universal percentage-per-hour target.

Scenarios 2, 3 and 5 also report without a tethered device. A whole recording
carries a `RecordingSession` MetricKit signpost interval and a bulk download
carries `OfflineDownload`, so cumulative CPU, average footprint and logical
writes for each arrive in the next daily payload and can be read in
Settings ▸ Device Reports. That is aggregated and a day late, so it does not
replace the tethered run — it establishes whether the tethered run is worth
scheduling, and it is the only form in which these scenarios get measured on
anyone else's phone.

For battery telemetry, prefer native Instruments, signposts and MetricKit over
an analytics SDK that adds its own network and background cost.
`General/Diagnostics/FieldMetrics/` subscribes to `MXMetricManager` and emits
four `mxSignpost` intervals; nothing is uploaded, reports are bounded on disk,
and they leave the device only through an explicit share sheet. No dependency
was added — MetricKit is a system framework, and the 26.5 deployment target
means every API used, including `MXDiskSpaceUsageMetric` and
`MXAnimationMetric.hitchTimeRatio`, needs no availability guard. See
`PERFORMANCE.md` § "MetricKit in the field".

## Validation performed

| Validation | Result |
|---|---|
| Strict SwiftLint | Passed (`Scripts/lint.sh`, 0.65.0, `--strict`) |
| Shared package tests | 76 tests in 12 suites passed |
| App and widget unit tests | 955 tests in 106 suites, plus 23 widget tests in 3 suites, passed |
| Full-bundle repeat runs | Passed 3× consecutively. Run in a batch on purpose: a cancellation test that only passes alone is not passing |
| iOS debug build | Passed, app and embedded widget, Swift warnings as errors |
| iOS release build | Passed. This is what validates the `#if DEBUG` wrap around every `--ui-test-*` flag: the parsing and its argument names do not compile into a shipping binary at all |
| Mutation checks | Two fixes were verified by reverting them and confirming the new test fails: the offline download window, and the stranded trail-graph region. A test that passes against the unfixed code is not evidence |
| UI automation | Not re-run. No `--ui-test-*` flag, launch path or accessibility surface changed |
| Render and resource performance suite | Passed, 10 of 10 scenarios, covering the Photos and Sync domains. Numbers in `PERFORMANCE.md` |
| GPX Thread Sanitizer suite | Not re-run; previously passed, including concurrent timestamp parsing |
| macOS compile | Not run; the `canImport` aliases and `#if os(iOS)` guards are unbuilt, not supported |
| visionOS build | Not run; the platform is not installed |
| Package resolution | Passed; CoreGPX is absent from `Package.resolved` |
| CI workflow | Every `xcodebuild` call in `ci.yml` carries `-skipPackagePluginValidation`; the performance suite stays out of CI and runs locally through its script |
| Physical-device energy trace | Not run |

## Open product design decisions

These are product choices rather than correctness findings.

1. **Pause semantics.** Pausing stops accumulation but the persisted route stays
   a single segment.
2. **Shipped trail graphs.** Cached Overpass regions do not provide offline
   matching in places the user has never visited.
3. **Widget takeover.** A live recording replaces the selected hike rather than
   appearing as a badge or secondary state.
4. **Two foreground location managers.** `LocationManager` and
   `SystemRecordingLocationSource` each own a `CLLocationManager`, and both
   receive updates during an active recording. Verified rather than assumed: the
   foreground manager never stops once started, and the recording source asks
   for `kCLLocationAccuracyBest` with a 10 m filter against the foreground
   manager's ten-meter/25 m baseline. iOS coalesces same-process location demand
   to the most demanding request, so this does not imply twice the GPS hardware
   power; what it duplicates is delegate dispatch and authorization handling.
   Both delegates now deliver through `onMainActor`, so the duplication no
   longer costs a `Task` allocation per fix. The separation is kept
   deliberately: the recording source owns background semantics
   (`allowsBackgroundLocationUpdates`, a `CLBackgroundActivitySession`, and no
   automatic pausing) that must not leak into ordinary map browsing. Revisit
   only if a device energy trace shows meaningful CPU overhead, and preserve
   those background semantics if the two are ever consolidated.
5. **Stop-name pre-fill.** `RecordingView.swift:469` pre-fills `stopNameDraft`
   with the hike's default title, while the alert says *"leave it blank to keep
   the default"* and the `TextField` prompt already shows that default. Tapping
   Stop → Save without typing therefore writes `customName`, permanently marking
   the hike user-named. Either the pre-fill is wrong or the copy is.
6. **`backgroundLocationShare` above 100%.** `FieldMetricsDigest.swift:384`
   divides background location time by fg+bg lifetime, which MetricKit accounts
   separately, so values above 1.0 are representable and would render as "112%".
   Clamping is a behaviour change to a shipped metric.
7. **`OpenWidgetExtension` has no `SUPPORTED_PLATFORMS`.** It stays iPhone-only
   through `SDKROOT` and `TARGETED_DEVICE_FAMILY = 1`. Adding it is a pbxproj
   edit with more blast radius than the defect.

## Checked and deliberately left alone

Recorded so none of it is re-raised as a finding.

### Types that should not become actors

- **`TileCache`.** Its `Mutex<MutationVersions>` makes bump-then-delete atomic
  against check-then-write; an actor's suspension points reintroduce the
  interleavings it exists to forbid.
- **`HikePhotoStore`.** Its only mutable state is one `NSCache`, already
  thread-safe. An actor would serialise thumbnail decodes that today run in
  parallel across gallery tiles. The `assertOffMainThread` contract at each
  entry point is what enforces correctness, and it holds.
- **`SerialAsyncQueue`.** An actor gives mutual exclusion but explicitly not
  FIFO ordering across suspensions, and offers no barrier — both of which
  `mergePendingWidgetFixes`' "every fix accepted before now is on disk once the
  queue drains" invariant depends on.
- **`SharedStore`.** Its hazard is cross-process (app ↔ widget), which
  in-process isolation cannot address; `options: .atomic` is the right answer
  and is used on every write.
- **`RecordingStats` / `RecordingTrace`.** Read synchronously by
  `MapView.Coordinator` inside `withObservationTracking`. Isolation here would
  put an `await` in the MapKit render path — the precise thing render isolation
  exists to prevent.
- **`PendingRecordingFixStore.withExclusiveLock`.** The `flock()` is
  cross-process; an actor cannot express it. It does still want an `EINTR` retry
  loop — `SharedRecordingFix.swift:307` turns a signal during lock acquisition
  into a thrown `.io`.

### Deliberate test seams, not production indirection

`OverpassTrailGraphProvider`'s injectable transport and clock,
`BackgroundTrailTracker`'s injectable location source and defaults,
`OfflineTileDownloader`'s injectable transport and `TileLoadGate`,
`CloudSyncCoordinator`'s injectable `CKContainer` and settings mirror,
`LocationManager`'s injectable defaults, and `TileSandbox`'s per-suite
`TileCache` directories all exist so suites never touch the app's singletons,
the network, or wall-clock time. That isolation is not a consequence of
parallelism and did not go away with it: the whole bundle runs in one process,
so a suite that reached for `TileCache.shared` would still leak into the next
one.

`ObservationCounter.settle()` in `RenderIsolationTests.swift` stays a bare
settle on purpose, with the argument written next to it. It asserts that an
observation did *not* fire, and unlike the two sleeps in finding 1 there is no
later barrier to hang it on: the whole point is that nothing downstream
happens. Its budget is spent once per counter, not per assertion.

### Claims that were investigated and found false

- **"A trim can delete a tile a concurrent auto-save just promoted."** Not
  reachable. `trimCache` skips claimed names outright, and a tile promoted after
  the claim snapshot keeps its fetch-time mtime, so it sorts *last* in the
  oldest-first deletion order — reaching it requires
  `size(tile) > 0.8 × 500 MB`. The safety is arithmetic and undocumented, which
  is the only residual risk: lowering the trim target fraction toward zero would
  make it reachable with nothing to catch it.
- **"A cancelled trail-graph prefetch strands its region in `.fetching`
  forever."** Was true, and is fixed. It used to be latent — the only caller of
  `cancel()` was `cancelTrailGraphPrefetches()`, which clears every state
  immediately afterwards, and `OverpassTrailGraphProvider.prefetch` never threw
  `CancellationError` of its own accord. Making a cancelled prefetch actually
  stop turned the second half of that into a live path, so
  `HikeRecorder+Lifecycle.swift`'s `catch is CancellationError` now clears the
  region's `.fetching` entry, guarded on the task id and session so it cannot
  clear a newer one. `selfCancellingPrefetchDoesNotStrandRegion` covers it, and
  fails without the fix — a stranded region reads as already-handled, so no
  later fix retries it.
- **"`RouteMotion` is claimed unread but two call sites read it."** Those call
  sites read `RecordingMotionState` and `RecordingPointFlags.nonPedestrian`,
  which are different types. `RouteMotion` really is written by
  `RecordingPoint.routeCoordinate` and read by nothing but tests.
- **"Syncing `tileProviderID` leaves a keyless device with a blank map."** It
  does not. `TileProvider.renderable(id:)` falls back to the keyless default
  when no key resolves, and `SettingsView.providerRow` compares against that
  *effective* provider, so such a device both draws and ticks OpenStreetMap.
  `Secrets.plist` is bundled at build time, so two devices running the same
  build have the same keys in any case.

### Cross-cutting checks that currently pass

Every DocC symbol link resolves; every `.swift` path referenced from a comment
exists; the App Group identifier agrees across both entitlements files and
`SharedStore.appGroupID`; every `xcodebuild` call in `ci.yml` and
`run-ui-tests.sh` carries `-skipPackagePluginValidation`; `ci_post_clone.sh`
sets both `IDESkip…` keys; every `--ui-test-*` flag matches
`AppLaunchEnvironment` and the README table in both directions;
`@concurrent` is spelled one way throughout; and
`ModelConfiguration+OpenHikes.swift` is the only place `cloudKitDatabase` is
named at all, with no other `ModelConfiguration(` literal anywhere — which is
what keeps the mirrored `Hike` store and the unmirrored `HikeLocalState` store
from being built any other way.

### Unverified assumptions worth knowing about

MapKit is assumed to re-enter `draw` after every `setNeedsDisplay(_ mapRect:)`,
and to be the only thing that invalidates a tile. `CachingTileOverlayRenderer`
asserts the first from experience, and the whole overzoom path rests on both:
the redraw loop that
`CachingTileOverlayRenderer.fetchPath(drawing:maximumZ:isCached:)` closes was
reasoned about rather than observed under Instruments, and so was the blank
sibling that closing it exposed — sixteen z21 tiles share one z19 ancestor, only
the first asks for it, and `inFlight` now carries the rects of the fifteen
folded into that request so they are invalidated too. `fetchPath` is unit
tested; neither the loop nor the blank tile was measured.

Whether `@Attribute(.externalStorage)` on `Hike.route` and `Hike.rawRoute` is
what makes CloudKit mirroring carry them as a `CKAsset` rather than as a record
field is likewise assumed rather than observed. It is the documented behaviour
and it compiles, but nothing here has watched a twenty-thousand-point route
cross a real container, and the 1 MB `CKRecord` limit it is meant to stay under
would be hit only by the longest hikes.
