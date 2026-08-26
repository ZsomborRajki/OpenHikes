# OpenHikes code review

The tree holds 164 first-party Swift files and 36,800 lines of shipping code,
plus 118 test files, project and package configuration, scripts, entitlements
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

### 1. A cancelled trail-graph prefetch keeps running (Medium)

`Recording/HikeRecorder+Lifecycle.swift:370-378`,
`Recording/OverpassTrailGraphProvider.swift:205-240`.

`cancelTrailGraphPrefetches()` cancels the recorder's wrapper tasks, but each
wrapper awaits `OverpassTrailGraphProvider.prefetch(around:)`, which awaits
`task.value` on an **unstructured** `Task` stored in `inFlight` (`:220-230`).
Unstructured tasks do not inherit cancellation, so the network fetch continues,
and the `write` and `trimCache` that follow it run after the user stopped
recording. The entry also stays in `inFlight`, because the cleanup lives in the
awaiting path (`:231`, `:237`) rather than in the task.

Not a drive-by fix: `inFlight` exists to deduplicate, so a second caller may
legitimately be awaiting the same key, and cancelling on one caller's behalf
would break the other. Doing it properly needs reference counting, or a
provider-level cancellation entry point that the protocol and both other
providers would have to gain.

Note for whoever takes it: `trailGraphPrefetchStopsWithRecording` passes today
only because the test stub awaits cancellably. It does not cover the real
provider.

### 2. Three location delegates each allocate a `Task` per GPS fix (Medium)

`Recording/HikeRecorder+Lifecycle.swift:464`, `Map/LocationManager.swift` and
`Map/BackgroundTrailTracker.swift` all shape their `didUpdateLocations` the
same way — `nonisolated`, then `Task { @MainActor in … }`, all three capturing
`self` strongly. During a recording all three are live (see "Two foreground
location managers" below), so one fix costs up to three heap-allocated tasks
and three actor hops.

Two things follow. The smaller: every `CLLocationManager` here is created on the
main actor — `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and
`SystemRecordingLocationSource.manager` is a stored property
(`HikeRecorder+State.swift:98`) — so the callbacks already arrive on the main
thread and the hop buys nothing but the allocation. The larger: ordering
between two *separate* unstructured `Task`s on the same actor is not guaranteed
by the language, and `HikeRecorder` sorts within a batch
(`+Lifecycle.swift:466`) only to give that guarantee up across batches. A
reordered pair meets `guard interval > 0 else { return false }`
(`RecordingModels.swift:148`) and the older fix is dropped silently.

This is deliberate — `.github/copilot-instructions.md` states the hop as a
convention — so it is a design decision to revisit rather than an oversight.
`MainActor.assumeIsolated` would remove both problems and is sound given the
isolation above, but it changes a documented rule and should be a considered
change, with `[weak self]` added either way.

### 3. `CloudSyncStateStore.writeRecords()` re-encodes everything per batch (Low)

`Sync/CloudSyncStateStore.swift:657-665` encodes the whole `serverRecords`
dictionary — one archived `CKRecord` per hike *and* per photo — and rewrites
the file. `remember(_:)` calls it once per batch, inside a callback
`CKSyncEngine` is awaiting, so a first sync of a large library pays it every
250 records. Binary plist keeps the constant down but not the shape. A write
coalesced behind a short debounce, or a per-record sidecar, would both fix it;
neither is a two-line change, and the file has to stay crash-safe either way.

### 4. Two hot paths still carry no signposts (Low)

`Tiles/Offline/OfflineTileDownloader+Planning.swift` and
`Tiles/Cache/TileCache+StorageManagement.swift` have none — the whole `Tiles/`
tree has them only in `TileCache.swift`. Both are exactly the kind of work the
battery plan below wants to see in a trace: planning runs before a bulk
download, and storage measurement enumerates directories. `RenderSignpost` is
already the mechanism.

### 5. Sixty-seven bare `settle()` calls remain (Low)

`settleDelegateHop()` without a condition is documented as best-effort, and
`OpenHikesTests/General/SettleSupport.swift` names the failure mode: a yield
count buys an amount of progress that depends on machine load, which is how two
suites went red on CI while passing locally. The condition-less form is still
used 67 times — `HikeRecorderTests+Sensors.swift` (25), `+GPS.swift` (15),
`Map/BackgroundTrackingTests.swift` (12), `+Review.swift` (6),
`+Recovery.swift` (4), `+Energy.swift` (2), and one each in
`RenderIsolationTests`, `LocationManagerConfigurationTests` and
`LocationFixStreamTests`. They pass today. Converting them needs a per-call-site
judgement about which effect to name, and a wrong condition is worse than none,
so this is listed rather than done in bulk.

### 6. `updateReviewPreview()` resolves the whole route on the main actor (Low)

`Recording/HikeRecorder+Persistence.swift:353`. `RecordingPreparation` and
`RouteReviewSection` already have `…OffMain` siblings for exactly this; one call
site did not adopt the pattern. Less pressing than it was —
`RecordingTrace.showReview` now compares before it publishes, so a tap that
changes nothing costs nothing — but a tap that *does* change the selection
still resolves every point on the main actor.

### 7. `OfflineTileDownloader.run`'s hand-rolled concurrency window (Low)

`OfflineTileDownloader.swift:72` — `inFlightWindow = 5` is correct, but
`withDiscardingTaskGroup` says the same thing in less code and brings
cooperative cancellation with it.

### 8. `RecordingSessionOptions` is a placeholder with tautological tests (Low)

`Recording/RecordingModels.swift:16-22` is an **empty struct** whose
`load(from defaults: UserDefaults)` ignores its parameter and returns `Self()`.
It is written into every journal file as `TrackJournalMetadata.recordingOptions`
and read by nothing. `RecordingSettingsTests.defaults` and `TrackJournalTests`'
round-trip assertion both compare an empty struct to an empty struct.

Not removed, because it is a persisted `Codable` field and a placeholder for
intended work is a product decision rather than dead code. The decision is:
give it a field and a real `load`, or delete it and the two tests with it.
Leaving it as an empty struct with a parameter it ignores is the only option
that is wrong.

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
recording-trace rebuilds and Overpass graph prefetch carry signposts, and
`PerformanceLog` writes them to a TSV alongside CPU and footprint samples under
`--ui-test-performance-log=`; the two gaps are finding 4 above. Compare against
the same device, route, screen state and radio conditions rather than against a
universal percentage-per-hour target.

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
`PERFORMANCE.md` § "The other half — MetricKit in the field".

## Validation performed

| Validation | Result |
|---|---|
| Strict SwiftLint | Passed (`Scripts/lint.sh`, 0.65.0, `--strict`) |
| Shared package tests | 76 tests in 12 suites passed |
| App and widget unit tests | 940 tests in 105 suites, plus 23 widget tests in 3 suites, passed |
| iOS debug build | Passed, app and embedded widget, Swift warnings as errors |
| iOS release build | Passed. This is what validates the `#if DEBUG` wrap around every `--ui-test-*` flag: the parsing and its argument names do not compile into a shipping binary at all |
| UI automation | `Scripts/run-ui-tests.sh --all` passed, 39 tests in 6 classes |
| Render and resource performance suite | Not run. The `PERFORMANCE.md` baseline predates the Photos and Sync domains |
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
   power; what it duplicates is delegate dispatch, authorization handling and
   actor hops — which is finding 2 above. The separation is kept deliberately:
   the recording source owns background semantics
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
`OfflineTileDownloader`'s injectable transport, `LocationManager`'s injectable
defaults, and `TileSandbox`'s parallel `TileCache` directories all exist so
suites can run in parallel without touching the app's singletons, the network,
or wall-clock time.

### Claims that were investigated and found false

- **"A trim can delete a tile a concurrent auto-save just promoted."** Not
  reachable. `trimCache` skips claimed names outright, and a tile promoted after
  the claim snapshot keeps its fetch-time mtime, so it sorts *last* in the
  oldest-first deletion order — reaching it requires
  `size(tile) > 0.8 × 500 MB`. The safety is arithmetic and undocumented, which
  is the only residual risk: lowering the trim target fraction toward zero would
  make it reachable with nothing to catch it.
- **"A cancelled trail-graph prefetch strands its region in `.fetching`
  forever."** Latent, not live. The cancellation paths
  (`HikeRecorder+Lifecycle.swift:321-331`) do return without restoring state,
  but the only caller of `cancel()` is `cancelTrailGraphPrefetches()`, which
  also does `trailGraphPrefetchStates.removeAll()`. It becomes real only if a
  provider throws `CancellationError` of its own accord; today's
  `OverpassTrailGraphProvider.prefetch` has no `Task.sleep` and no
  `checkCancellation`.
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
`AppLaunchEnvironment` and the README table in both directions; and
`ModelConfiguration+OpenHikes.swift` pins `cloudKitDatabase: .none` on every
store, with no other `ModelConfiguration(` literal anywhere — which is what
keeps `Hike`'s non-optional columns and its `Codable` `photos` array legal.

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

Whether iOS purges the Caches-backed asset staging directory between staging and
send is likewise assumed rather than measured; `CloudSyncFailure` treats
`.assetFileNotFound` as retryable on that assumption.

A style point rather than an assumption: `@concurrent nonisolated`
(`SettingsView`, `AutoSaveController`) and bare `@concurrent`
(`OpenHikesModel`, `HikeSyncEngine+Delegate`) are both used and both correct —
static members of an actor are implicitly nonisolated — but the codebase should
pick one spelling.
