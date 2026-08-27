# OpenHikes performance and energy

What the app costs — in frames and in battery — how that was measured, and what
is still wrong with it. Every number here was produced by
`Scripts/run-performance-tests.sh` on an iPhone 17 Pro simulator (iOS 26.5,
Xcode 26.6, Debug); none of it is estimated.

**This is a live list, not a log**, on the same terms as `CODE_REVIEW.md`. A
finding that has been fixed is deleted rather than annotated, and a "was → now"
column survives only where the *now* is still in question. What stays is the
current state, the decisions that remain load-bearing, and what is still open.

Two claims are under test, and they are not the same claim.

*Rendering.* `RouteHighlight`, `SheetMetrics`, `RouteStyle`, `MapController`,
`TrackerState`, `LocationManager` and `SheetPresentation` are stable
`@Observable` reference types precisely so that high-frequency state — a GPS
fix, a finger on the elevation chart, a pushed screen — moves the map without
re-evaluating any SwiftUI body above it.

*Energy*, which is the one the app exists for. This is a hiking recorder: six
hours, in a pocket, screen off, on a phone that has to still have charge when
its owner needs a map to get down. An app that renders beautifully and flattens
a battery by three in the afternoon has failed at the only job that mattered.
Energy is not a subsection of performance here; it is the other half.

## How to run it

```sh
# Whole suite, report written to PerformanceReports/<timestamp>/report.md
Scripts/run-performance-tests.sh

# One scenario
Scripts/run-performance-tests.sh --test testBackgroundRecordingCostsNothingPerFix
Scripts/run-performance-tests.sh --list

# Still produce a report when a budget fails
Scripts/run-performance-tests.sh --keep-going
```

Debug is mandatory, not incidental: `RenderSignpost`, `PerformanceLog` and
`MainThreadWatchdog` all compile to nothing in Release, so a Release run would
measure an app that reports nothing at all. The MetricKit integration below is
the exact inverse — it ships in Release and reports nothing here — which is why
the two coexist rather than compete.

`PerformanceReports/` is git-ignored. A run is evidence on the machine that
produced it and nowhere else, so this document carries the numbers rather than
the paths.

## How it works

Three pieces, because no single one of them can see the whole picture.

**`PerformanceLog`** (`OpenHikes/General/Diagnostics/PerformanceLog.swift`) is
a debug-only text sink, switched on by `--ui-test-performance-log=<scenario>`.
Every `RenderSignpost` mark and interval, every `MainThreadWatchdog` stall and a
1 Hz CPU/footprint/power sample land in `Documents/PerformanceLogs/<scenario>.tsv`
as `epoch_s, elapsed_s, kind, name, value, detail`. The recording path only takes
a lock and appends a struct; formatting and file I/O happen on a utility serial
queue, so the instrument does not become the thing being measured.

**`PerformanceCounterProbe`** is a 1×1 `UIViewRepresentable` whose
`accessibilityValue` is computed *on demand* from the live counter tally. This
is the only channel by which an out-of-process XCUITest can read in-app
counters, and it has to be pull-based: a SwiftUI `.accessibilityValue(…)` is
captured when the body runs, so a render counter published that way would need
a render to report a render.

**`PerformanceUITests`** drives real gestures, reads the probe before and after
each phase, and asserts on the *difference*. Differences, not absolutes,
because a test cannot control what the app did before the gesture it cares
about, and because a body-evaluation count is stable across machines in a way
that a millisecond budget is not.

`Scripts/perf-report.py` then joins the `PERF-PHASE`/`PERF-COUNT` lines the test
prints with the app's event file and writes the markdown report, including the
per-scenario energy, network and location-funnel sections.

## Where this stands

Ten scenarios, all passing, measured 2026-08-27.

| Check | Result |
|---|---|
| `PerformanceUITests` | **10 of 10 passed** |
| App and widget unit tests | **1087 passed** (1064 app + 23 widget) |
| `OpenHikesUITests`, functional | **44 passed** |
| `swiftlint --strict` | Clean |

### What is already right

These are the load-bearing claims of the architecture, and they hold.

| Scenario | Measurement | Result |
|---|---|---|
| Idle, 7 s, map visible | body evaluations | **0** |
| Idle, 7 s | CPU | **0.045 s — 0.6% of one core** |
| Chart scrub, one drag | `ElevationChartBody` | 17 |
| Chart scrub, one drag | `OpenHikesViewBody`, `MapSheetBody`, `MapRouteRebuilt` | **0, 0, 0** |
| Map browsing, 17 s of pans and zooms | root, hike list | **0, 0** |
| Live recording | `TrailMatcherWork` | 1.0 per fix, off-main, no stall |
| Offline browsing, 17 s | connections opened | **0**, with 45 fetches refused |
| Backgrounded recording | SwiftUI bodies per fix | **0** |
| Backgrounded recording | radio wake-ups over 14 s in a pocket | **0** of the run's 209 |
| Photo strip, scrolled | decodes, bodies, stalls | **0, 0, 0** |
| Photo paging | sorts per viewer body | **1.0** |
| Settings, toggling a switch | `SettingsBody` | **0** |
| Photo discovery, four selections | `PhotoDiscoveryBody` | **0** |
| Photo push: root / hike list / sheet | body evaluations | **0 / 0 / 1** |

A sustained scrub moves the map marker seventeen times without re-evaluating a
single body above the chart; an idle app with a map on screen costs under one
percent of one core; a recording in a pocket does no rendering and opens no
connection at all; scrolling a gallery of eight 12 MP photos re-decodes nothing;
and ticking four checkboxes in a twelve-cell grid rebuilds four checkboxes.

The one `MapSheetBody` left on a photo push is a floor rather than a miss.
`NavigationStack(path:)` reads its binding during the enclosing body, so one
evaluation per push is structural — asserted by `NavigationStackBodyCostTests`,
which builds a real stack and measures exactly +1, rather than argued in a
comment.

### The costs

| Measurement | Value |
|---|---|
| Launch, first responsive frame | 1.471 s, RSD 0.18% (n=3) |
| Launch main-thread stall | 544–595 ms, asserted below 1200 ms |
| `AppModelInit` | 64.7–71.3 ms |
| `ModelContainerInit` | 36.4–39.0 ms |
| `RecordingTailRebuilt` per fix | 2.0, 0.02–0.03 ms median |
| `MapRecordingTraceApplied` per fix | 2.0 foreground, **0.33** backgrounded |
| CPU per accepted fix | 0.488 s screen on, **0.225 s** backgrounded |
| Photo thumbnail decode | 18.9 ms median, 20.8 ms max |
| Photo full-size decode | 64.5 ms median, 65.3 ms max |
| Recording footprint | 107.5 MB start → 95.7 MB end, 189.1 MB transient peak |

Two of those rows need reading with care.

`RecordingTailRebuilt` and `MapRecordingTraceApplied` are **2.0 per fix by
design**, not by tolerance. `accept(_:)` appends the raw coordinate so the line
keeps up with the walker, then the asynchronous trail match returns and replaces
the provisional tail with snapped geometry. The two land 11–72 ms apart, so the
raw tail really is on screen for a frame or three before it snaps — which is the
feature rather than waste, since the alternative is a line that lags the walker
by the matcher's latency. Each rebuild costs 0.02–0.03 ms. The budget is 2.5
rather than 1.5 because a test that fails permanently is a test everyone learns
to ignore; what is worth defending is that it stays two and does not grow.

The **footprint peak is automation, not the app** — nothing was leaked, since
the scenario ends 12 MB below where it started. See "Absolute footprint under
XCUITest is not the app's footprint" below.

### What a hike costs a battery

Battery has no single counter an app can read — `UIDevice.batteryLevel` is
quantised to 5% and useless over a thirty-second test — so the report puts four
proxies side by side per scenario: CPU seconds, radio wake-ups, GPS duty
(the location funnel), and screen work.

| Scenario | CPU per hour (extrapolated) |
|---|---|
| Idle with the map up | 239 CPU-s |
| Offline browsing | 305 CPU-s |
| Map browsing (online) | 335 CPU-s |
| Recording, backgrounded | 459 CPU-s |
| Live recording, screen on | 438 CPU-s |
| Settings | 504 CPU-s |
| Photo discovery | 532 CPU-s |
| Photo gallery | 534 CPU-s |
| Chart scrubbing | 648 CPU-s |

Read those as shapes, not values. They are whole-run figures that include launch
and the automation's own polling, and they say more about how much a scenario
queries the accessibility tree than about the feature they name — the chart
phase burns 2.21 CPU-s while evaluating *zero* chart bodies, which is XCUITest
hit-testing. The backgrounded recording reading *above* the screen-on one is the
clearest proof of that: it is the scenario that polls the counters hardest.

The comparable pair is per accepted fix, where the phases are like for like:
**0.488 s screen on against 0.225 s backgrounded**. Putting the phone in a
pocket halves the per-fix cost, which is the right shape — and since that is how
the app is used for all but a few minutes of a walk, the backgrounded number is
the one that decides whether the battery lasts.

### The location funnel

Every scenario's report includes this, because "the GPS is busy" and "the GPS is
busy and we are throwing the results away" cost identical energy and need
opposite fixes:

```
LocationFixDelivered   → CoreLocation handed us a fix
LocationPublished      → it passed LocationManager's filters
RecordingFixReceived   → it reached the recorder
LiveFixAccepted        → it became part of the route
RecordingFixRejected   → it did not
```

`Scripts/perf-report.py` raises a rejection rate above 50% as a finding: full
GPS duty paid, half a route recorded.

## Energy policies in force

Three policies decide what the app spends. Each was a measured finding once;
each is now shipping behaviour whose full argument lives in the source header
rather than here, so that the rationale cannot drift away from the code it
justifies.

**GPS accuracy is a function of conditions**, not a constant
(`OpenHikes/Recording/RecordingEnergyPolicy.swift`).

| | Precise (default) | Conserving |
|---|---|---|
| `desiredAccuracy` | `kCLLocationAccuracyBest` | `kCLLocationAccuracyNearestTenMeters` |
| `distanceFilter`, moving | 10 m | 20 m |
| `distanceFilter`, stationary | 25 m | 25 m |

`desiredAccuracy` moves only for Low Power Mode or thermal `.serious` and above.
`distanceFilter` moves for those and for standing still, taking the larger of
the two candidates. `.fair` thermal is deliberately excluded — a phone in a
jacket pocket in direct sun sits there all summer, and a mitigation that is
always on is indistinguishable from having lowered the default.
`PowerStateMonitor` watches both notifications, so the transition with no fix to
prompt it — a walker stopping for lunch as the battery crosses 20% — still
reconfigures. Each application emits `RecordingEnergyProfileApplied`, and only
when the profile actually changed. Pinned by `RecordingEnergyPolicyTests` (the
decision, 8 cases) and `HikeRecorderTests+Energy` (that it reaches CoreLocation
at the right moments, 5 cases).

**Tile fetching is split by purpose**, not by caller
(`OpenHikes/Tiles/TileNetworkPolicy.swift`). What matters is whether anyone is
waiting for the tile: `loadTile` takes the purpose and defaults to
`.interactive`, while `saveTileDurably` fixes it at `.speculative`.

| Condition | Interactive (drawing now) | Speculative (prefetch) |
|---|---|---|
| Offline | denied | denied |
| Low Data Mode (`isConstrained`) | denied | denied |
| Cellular (`isExpensive`) | **allowed** | denied |
| Low Power Mode | allowed | denied |
| Thermal `.serious`+ | allowed | denied |

The asymmetry is the point: a walker looking at the map gets their tile, and
what stops is the app spending a metered radio on tiles nobody asked to see.
None of it is configurable — a switch is a question the walker has to answer
correctly *before* the walk to get the right behaviour during it. Every refusal
emits `TileFetchSuppressed` with `purpose=` and `reason=`, which matters more
than it sounds: a tile that silently never loads is the hardest thing in this
pipeline to debug, and this policy creates exactly that situation on purpose.
Pinned by `TileNetworkPolicyTests` and four cases in `TileTransportTests+Energy`.

**A backgrounded recording draws nothing and ticks nothing.**
`MapView.Coordinator` gates the overlay apply on foreground, observed through
`UIApplication` lifecycle notifications rather than `scenePhase` so it stays
entirely off SwiftUI's render path; the `withObservationTracking` registration
continues regardless, since the revision must keep being tracked, and the work
is deferred rather than dropped and caught up in a single pass on return.
`RecordingHeader` builds its 1 Hz `TimelineView` only while `scenePhase` is
`.active` — that one *is* on the render path, deliberately, because the question
is whether the `TimelineView` is in the hierarchy at all and only SwiftUI can
answer it. Gating on `.active` rather than `!= .background` covers the states a
walker is actually in most often: shade pulled down, app switcher open, screen
locked but not yet backgrounded. Nothing is lost by not counting, because the
readout derives from a timestamp rather than accumulating.

The assumption that iOS would have suspended that timer was wrong for a specific
reason worth keeping: iOS suspends a backgrounded app, and a suspended app runs
no timers — but *this* app is not suspended. It holds the location background
mode for the entire hike, which is exactly what keeps it running. The one app
that most needs the timer to stop is the one where it does not stop by itself.

## Open findings

### Launch blocks the main thread for ~600 ms (P1)

`XCTApplicationLaunchMetric` puts first-responsive-frame at **1.471 s**. The
watchdog reports a **544–595 ms** unbroken main-thread stall in *every*
scenario. That stall begins before `PerformanceLog` itself exists and ends at
t≈0.55 s on its clock, by which point the map and sheet have already drawn. The
timeline inside it bisects as:

| Span | Cost |
|---|---|
| `ModelContainerInit` (SwiftData), at t=0.003 | 36.4–39.0 ms |
| `AppModelInit` (whole `OpenHikesModel`, includes the above) | 64.7–71.3 ms |
| Model built → first SwiftUI body, at t=0.226 | **~130 ms** of framework bootstrap |
| `MapViewCreated` → `MapRecordingTraceApplied` | **~52 ms** of `MKMapView` construction |
| First body → main thread free again | **~330 ms** |

The sheet body runs five times and the hike list eight before the app settles at
t≈0.68 s. The framework bootstrap is not ours; the rest of the first render
largely is. **This is also the largest single energy item in a short session**:
a walker who opens the app to check where they are, and closes it, pays this and
almost nothing else.

Two things are known about the two bisection intervals and neither is fixed.
`ModelContainerInit` carries `#Index<Hike>([\.id], [\.date], [\.isRecording])`
(`Hike.swift:35`) — three indexes built at store-open, traded for a faster hike
list on a large store, with nothing measuring the benefit. `AppModelInit` had
one attributable cause, two `CKContainer(identifier:)` default arguments
constructed synchronously during model construction and used only from `async`
readers; they are now `@autoclosure @escaping` factories behind a `lazy var`,
which bought about 2 ms of mean and 6 ms of worst case and did not move the
first frame at all. Roughly 14 ms of `AppModelInit` and the whole of the
first-frame cost remain unattributed.

*Next step:* put a signpost interval around each dependency
`OpenHikesModel.init` constructs rather than guessing again, and find out how
much of the sheet hierarchy is genuinely required for the first frame.

The stall is asserted rather than merely recorded: `assertLaunchStall(atMost:in:)`
fails `testIdleCostsNothing` above a **1200 ms** ceiling — a tripwire set well
above the observed range, not a target, because the target is to remove the work
rather than to hold a line around it. It needed a budget shape of its own, since
launch is over before any measured phase begins, so it reads the watchdog's
*maximum* out of the counter tally instead of a delta.

### Panning still reaches the sheet, sometimes (P2)

Four consecutive runs of the browsing phase against the current build:

| `browsing` phase | Four runs |
|---|---|
| `MapSheetHikesBody` | **0, 1, 0, 0** |
| `OpenHikesViewBody` | **0, 1, 0, 0** |
| `MapSheetBody` | 2, 4, 2, 2 |

Three of four are clean and the worst case is 1, down from 4 before
`SheetPresentation` removed the root's `@State` invalidation and `MapSheetHikes`
became `Equatable`. But it is not zero, it is still run-dependent, and
`MapSheetBody` did not improve at all — that column is the unexplained part.

This was never a stable number: earlier runs against one unchanged build
reported 4/3/2, then 1/1/1, then 4/3/2 again, which is why the measurement above
is four runs rather than one. The budget stays at 4 until four consecutive clean
runs justify lowering it. Panning is the single most common thing anyone does in
this app, and a `@Query`-backed list re-evaluating on it is exactly the shape
that becomes expensive when somebody has two hundred hikes.

### A tap on the elevation chart scrubs nothing (P3)

Nine taps along the elevation profile produce **zero** `ElevationChartBody`
evaluations. A continuous drag over the same pixels produces 17. So the render
cost of a tap is nil and what is left is behavioural: a tap does not scrub.

**The cause is unknown.** An earlier version of this document said "the gesture
is drag-only"; there is no hand-written gesture involved. Scrubbing is
`.chartXSelection(value:)` (`ElevationChartView.swift:94`), which Swift Charts
documents as handling taps as well as drags, and the tree contains no
`DragGesture`, `onTapGesture`, `chartGesture` or `chartOverlay` anywhere. The
candidates are the chart's hit area, the `.accessibilityElement()` applied after
it — which flattens the subtree and is the most likely of the three — or the
selection resolving and being immediately discarded. Settling it needs a run
against the actual view, not another reading.

Low priority, since nobody taps a chart repeatedly, but it is where a scrub's
start/stop edges would show a regression first. Note that the tap phase still
burns 2.21 CPU-s while evaluating nothing, all of it XCUITest hit-testing.

## Blind spots

Things this harness structurally cannot see, listed so nobody mistakes silence
for a passing grade.

- **A real hike-length recording.** Every energy number above extrapolates from
  a three-fix scenario. `Scripts/simulate-hike.sh` plus the Energy Log
  instrument over a full GPX is the only way to know whether the per-fix cost is
  flat. Instrumented but not answered: the `RecordingSession` `mxSignpost`
  interval attributes cumulative CPU, average footprint and logical writes to
  one whole walk, and `MXAppRunTimeMetric.cumulativeBackgroundLocationTime`
  gives the denominator. The instrument is in; the walk has not been taken.
- **A physical device.** `XCTHitchMetric` needs a signpost stream the Simulator
  does not emit — it raises inside `harvestData` rather than degrading — so
  frame-level hitch data cannot be produced here at all. A device is also the
  only place thermal state ever leaves `.nominal`, so the conserving GPS profile
  has never been exercised outside unit tests, and the only place background
  suspension behaves as it will for a walker.
- **Any MetricKit payload.** The integration is in and tested, but nothing has
  been read on a device: the Simulator emits `NO_METRICS` and delivery is daily.
  Check first that `RecordingSession` appears at all — an interval that outlives
  the 24-hour aggregation period is dropped silently, and a long walk is exactly
  the case that risks it.
- **`Purchases/` and the widget's timeline provider.** Neither carries a single
  `RenderSignpost` mark, so a rendering problem in the paywall or in a timeline
  reload is invisible here. Both rendering findings that this suite did catch
  were in code that *had* marks.
- **A long recording, and a gallery larger than the strip.** No scenario drives
  hundreds of fixes, so O(n)-per-fix shapes show up as an argument rather than a
  slope. `--ui-test-seed-photos` caps at 24, and the thumbnail tier is bounded at
  32 MB of decoded bytes — roughly 42 thumbnails — so eviction is a routine event
  on a long strip and the ~19 ms re-decode is the price. Whether that trade is
  sized right is a measurement nobody has taken.
- **A stored baseline.** `Scripts/perf-report.py` has no `--baseline` flag, so
  every report is read in isolation and a regression against the numbers above
  has to be spotted by eye.

Two smaller gaps worth deciding rather than drifting on. `isIdleTimerDisabled`
is never set, which is the right default — but a walker navigating a junction
with the screen dimming every 30 s reaches for the power button repeatedly, and
each wake costs more than the timeout saved; that wants a setting rather than a
constant. And nothing has re-checked periodic work since 2026-08-26, when a
reading of the tree found `RecordingClockTick` to be the only periodic path in
the shipping app: `AutoSaveController`'s drain is signal-driven,
`CachingTileOverlayRenderer`'s retry wake is a bounded one-shot,
`HikeRecorder+Helpers` is event-driven, and CloudKit mirroring schedules its
own work. That was a reading, not a measurement.

## Rules this suite learned the hard way

Each of these produced a convincing wrong answer first.

### About the app

**Only a `View` type is a boundary.** A helper `func`, a computed `var`, and a
`.toolbar`/`.safeAreaInset`/`.overlay` closure are all inlined into the body
that declares them, so an observable read inside one registers as an input of
*that body*. This is how a tick mark came to rebuild a whole photo grid: the
selection lived correctly in an `@Observable` controller, and the cells were
built by a `private func cell(_:at:)` in the sheet's scope. If a body is
re-running and you cannot see the observable read in it, look for those four
before looking anywhere else.

**State can be correctly owned and incorrectly placed.** `@State` invalidates
its declaring view unconditionally, whether or not `body` reads it — so a
navigation path held as `@State` on the root re-rendered the entire map screen
underneath a full-screen cover that completely obscured it. A second pass came
from an `.onChange` writing a `@State` that *no body ever read*: pure
bookkeeping, charged two body evaluations. The fix shape is `SheetPresentation`
— a stable `@Observable` holding the raw state as `@ObservationIgnored` storage
and publishing only *coarser* derived flags, so pushing a photo onto a hike, the
same screen at the same height, flips nothing at all.

**A computed property that sorts looks like a field access.**
`Hike.orderedPhotos` was read six times in one body pass of the photo viewer for
exactly that reason. Its comparator also allocated: comparing
`(capturedAt, id.uuidString)` tuples makes Swift build *both* sides before
comparing, so every comparison allocated two 36-character strings rather than
only the ties the tie-break exists for.

**A container's accessibility identifier smothers the leaves underneath it.**
SwiftUI pushes it down onto every descendant, so a `photos-section` on a `VStack`
made three unrelated elements answer to one name and left the inner strip
unreachable from automation. That is a shipped VoiceOver defect, not a test
problem.

**Not every well-argued prediction survives a measurement.** `SettingsView`
declared `@Query private var hikes: [Hike]` and rendered no hike — an unbounded
invalidation source by construction — so the prediction was that all seven
`Form` sections were charged for every write to any `Hike`. Measured: 2.0
`SettingsBody` with the query and 2.0 with an on-demand fetch, because SwiftData
coalesces the writes into one invalidation the explicit state changes were
already paying for. The change was kept for correctness, since a fetch taken
when an action runs cannot be a pass behind the store, but it is not a win.

### About the harness

**Absolute footprint under XCUITest is not the app's footprint.** A recording
scenario once settled at 210 MB against 87–95 MB everywhere else, which looked
like the most serious thing in this document — that is where a backgrounded
recording starts being a jetsam candidate. It was the harness. Driven by
`simctl` alone the same build sits at 74 MB, and neither Core Location, nor the
bundled trail graph, nor a map actively following a position and loading tiles
moves it; every counter read and element query makes the app build an
accessibility snapshot, and the recording scenarios poll the most. Only
footprint *deltas inside a single phase* mean anything, and even those are
contaminated by however much querying the phase does.

**The observer perturbs the observed.** The first interaction with a
newly-presented screen forces XCUITest to hit-test against a hierarchy it has
not described before, and SwiftUI evaluates bodies to answer. Charged to the
gesture, this made one chart scrub report 2 and 5 on consecutive runs of
identical code. `warmAccessibilityTree(around:in:)` pays that cost before the
baseline reading — but it performs a real centre tap, so it has to be *aimed*:
warming on the photo strip navigates into the viewer, and warming on the
Settings form's centre lands on the tile-provider list and either switches the
map source or opens the paywall. Warm on a harmless control on the same screen,
after scrolling it into view.

**A fixed settle time cannot be both correct and fast.** A constant three
seconds wasted three seconds per phase and was still short enough to
occasionally include the previous phase's tail. `settle(in:)` polls the app's
own counters and returns once nothing has re-rendered for 1.5 s, ignoring the
sampler's entries — which tick every second regardless and would otherwise mean
the app never looked quiet. A counter that ticks on a timer must be added to the
`sampled` exclusion set in `PerformanceCounters.isEquivalent(to:)`, or every
recording scenario spins to its timeout. The same rule bans a fixed sleep as a
barrier: wait on the positive effect that must follow.

**A suite made entirely of upper bounds cannot notice work that has stopped.**
Instrumenting the 1 Hz clock nearly broke it: extracting the readout into a view
that stored the *recorder* made the view structurally identical on every tick,
so SwiftUI skipped its body and the clock silently froze — scoring perfectly
against every budget in the suite. The view now stores the formatted string, so
what SwiftUI diffs is the thing on screen, and `RecordingClockTick` carries a
*lower* bound in the foreground scenario as well as an upper bound in the
backgrounded one. Any counter measuring work that is *supposed* to happen needs
the same pair.

**A cache is a lie detector that has already been bribed.** The offline scenario
asserts that browsing opens no connection. On its first run it passed instantly
and proved nothing: every tile in the region was already on disk from the
*previous* scenario, so there was no miss and no fetch to refuse.
`--ui-test-offline` now also hands the launch an empty tile root, which turns 0
refusals into 45.

**A permission dialog must not decide whether you get data.** The recording
scenario once reset location authorization and relied on a UI interruption
monitor to answer the alert. When that failed, Core Location delivered nothing
and the run produced fifty-one seconds of an idle app — which looks like a
measurement but is the absence of one. `Scripts/run-performance-tests.sh` grants
the permission out-of-band with `simctl privacy`; the monitor stays as a
fallback.

**A harness failure will happily impersonate a product failure.** Four runs back
to back once produced a different failure each time — `kAXErrorServerNotFound`,
`Error getting main window`, `Application … is not running` — and never the same
test twice. None were assertions; all were the accessibility server being asked
about an app that had not finished coming forward, because both `launch()` and
`activate()` return before the state they name is true. `bringToForeground(_:)`
blocks on `XCUIApplication.wait(for: .runningForeground)` first. When a
performance suite starts failing *differently* on each run, suspect the harness.

**A test the runner cannot find is a test that passes.**
`run-performance-tests.sh` once built its list by scanning
`PerformanceUITests.swift` alone, after the suite had already grown into
`+Photos.swift` and `+Screens.swift` — so `--list` under-reported and `--test`
rejected names that existed. It scans `PerformanceUITests*.swift` now. Anything
that decides *which* tests run is part of the harness and needs the same
suspicion as the assertions.

**A ratio can invent a finding.** The report generator flagged the backgrounded
recording for "52.2 network requests per accepted fix", which was arithmetic
rather than a fact: it charged the tiles the foreground map loaded at launch
against the three fixes a short scenario accepts. That scenario in fact woke the
radio **zero** times once the phone was in a pocket. The generator now counts
requests inside the backgrounded windows instead, which is the number that costs
a battery.

## Chasing a problem you can feel

The suite catches regressions in scenarios someone thought to write. This is how
to chase one you cannot name.

**1. Turn on the signpost console.** Set `RENDER_SIGNPOST_LOG=1` in the scheme's
run action and use the app. Every body evaluation, map update and matcher run
prints as it happens; if something re-renders when you touch an unrelated
control, you will see it before you can measure it.

**2. Watch it in Instruments.** The same marks are `os_signpost` events, so
*File › Recording Options › os_signpost* plus the **Energy Log** and **Location
Energy Impact** instruments give the render stream and the battery cost on one
timeline. This is the only way to see a radio wake-up you did not cause.

**3. Reproduce it as a scenario.** Add a `test…` to `PerformanceUITests`, launch
with `--ui-test-performance-log=<name>`, wrap the interaction in
`measurePhase(named:in:seconds:)`, and read the counter deltas. If the number is
stable, assert it; if it is not, the instability is the finding.

**4. Drive a real route.** `Scripts/simulate-hike.sh` plays a GPX through the
simulator for long-running behaviour a three-fix scenario cannot show — drift,
growth per fix, the accumulator deciding you have stopped.

**5. Read the energy section.** Radio wake-ups, refused fetches by reason, the
location funnel, and every GPS reconfiguration with a timestamp. A scenario that
renders perfectly and opens forty connections is a bug this document cares about
just as much.

The launch arguments are all gated behind `--ui-testing` and documented in one
place — the table in `README.md`. The ones this suite uses are
`--ui-test-performance-log=<scenario>`, `--ui-test-offline` (which also hands
the launch an empty tile root), `--ui-test-enable-location`,
`--ui-test-import-gpx=<name>`, `--ui-test-trail-graph=<name>`,
`--ui-test-seed-photos=<count>`, `--ui-test-photo-library=<count>`,
`--ui-test-seed-metrics=<count>` and `--ui-test-expanded-sheet`.

### Signposts

There is no canonical list of signpost names. `RenderSignpost`
(`OpenHikes/General/Diagnostics/RenderInstrumentation.swift`) takes a
`StaticString`, so a name exists only at its call site and any list written here
would drift silently. The tree currently emits 68 distinct names; read them off
the code:

```sh
rg -o --multiline --no-filename 'RenderSignpost\.\w+\(\s*"[A-Za-z]+"' --glob '*.swift' \
  | sed -E 's/.*"([A-Za-z]+)".*/\1/' | sort -u
```

They fall into families whose prefixes are worth knowing: `…Body` for a SwiftUI
body evaluation, `Map…` for anything that reaches `MKMapView`, `Recording…` and
`Live…` for the fix pipeline, `Photo…` for decode and ordering, `Tile…` and
`Offline…` for the storage and download pipeline (much the largest family), and
`AppModelInit`/`ModelContainerInit`/`GPXParsed`/`HikeTrailAnalysis` for startup
and I/O intervals.

## MetricKit in the field

Everything above is a Debug build, on a Simulator, driving synthetic input, on
one machine. That is the right shape for a regression harness — deterministic,
re-runnable, able to fail a pull request — and the wrong shape for the questions
in **Blind spots**, because a Simulator has no battery, no thermal state, no
cellular radio, no jetsam and no user.

**MetricKit replaced nothing.** Not one line of `RenderSignpost`,
`PerformanceLog`, `MainThreadWatchdog`, `PerformanceCounterProbe` or
`PerformanceUITests` became redundant. It reports once every 24 hours,
aggregated across a whole day, from a Release build, with no way to attribute a
number to a gesture; it cannot fail a build, cannot bisect a regression, and
cannot tell you that `MapSheetHikesBody` rendered four times during a pan.
Anyone who reads "MetricKit collects launch times" and concludes it supersedes
`XCTApplicationLaunchMetric` has confused a population statistic with a
measurement. What it does is reach into the gaps the harness is shut out of:
`MXAnimationMetric.hitchTimeRatio` for hitches,
`LocationAccuracyBreakdown.conservingShare` for the conserving GPS profile,
`MXAppExitMetric.backgroundExitData` for the jetsam risk a recording carries,
and `MXCPUMetric` plus `cumulativeBackgroundLocationTime` for a whole walk.

`OpenHikes/General/Diagnostics/FieldMetrics/` is six files, split along one
line — what can be tested and what cannot — and note it is *not* `#if DEBUG`,
unlike everything else in `Diagnostics/`. A Debug-only MetricKit integration
would report nothing, since the framework only delivers against Release builds
in the field.

- **`FieldMetricsDigest.swift`** holds every judgement the app makes about a
  payload and imports no MetricKit at all. `MXMetricPayload` has no initializer
  and cannot be synthesised, so anything touching it would be untestable by
  construction. This is why `FieldMetricsDigestTests` can exist.
- **`FieldMetricsDigest+MetricKit.swift`** is the adapter, deliberately thin.
- **`FieldMetricsStore.swift`** is an actor over a directory in Application
  Support, bounded on every write at 16 reports and 4 MB, oldest-first, with the
  newest never pruned — a crash payload larger than the whole budget is exactly
  the one worth keeping.
- **`FieldSignpost.swift`** is the `mxSignpost` wrapper and the launch extension.
- **`FieldMetrics.swift`** is the `MXMetricManagerSubscriber`, and the only
  thing in the app that talks to `MXMetricManager`.
- **`SeededFieldMetricsFixture.swift`** is `#if DEBUG` and wires up
  `--ui-test-seed-metrics=N`, so Settings ▸ Device Reports is reachable by
  automation on a Simulator that never receives a live payload.

Nothing is uploaded. Reports are written locally, shown in **Settings ▸ Device
Reports**, and leave the device only through an explicit share sheet.

**Why only four signposts.** Apple's guidance: *"To limit on-device overhead,
the system will automatically limit the number of signposts (emitted using the
MetricKit log handle) processed."* The failure mode is silent — a fifth span
does not error, it costs the other four their data. So the MetricKit set is four
coarse, user-initiated spans and is deliberately *not* the `RenderSignpost` list:
`RecordingSession` (one interval per whole walk — this is the long-hike
measurement), `OfflineDownload` (the largest deliberate burst of network and disk
the app ever does), `HikeImport` (GPX parse plus trail analysis on real files)
and `TrailGraphPrefetch` (the one unavoidable Overpass round trip on a real
radio). `TrailMatcherWork` fires roughly two thousand times per hike and
`TileNetworkFetch` hundreds; both stay `RenderSignpost`-only. `FieldSignpost.Span`
is `CaseIterable` and `FieldMetricsDigestTests` asserts the count, so a fifth has
to be added on purpose. `RecordingSession` ends where `stopLocationSensors()`
runs rather than where the hike is saved — a walker who spends ten minutes naming
a hike should not be charged for it against the recording.

**Three caveats, all of which matter.** The Simulator emits no MetricKit
telemetry: `MXSignpost_Private.h` branches on `TARGET_OS_SIMULATOR` and attaches
the literal string `NO_METRICS`, so the call still emits an ordinary
`os_signpost` and Instruments still works, but every number in this section can
only be gathered on a device. Delivery is daily and a span that outlives the
aggregation period is lost entirely, which for a `RecordingSession` means a
recording left running overnight reports nothing. And `extendLaunchMeasurement`
must be balanced — a task never finished stays open for the process lifetime and
reports nothing — so `LaunchMeasurement.finish()` is idempotent and is called
both from `MapView`'s creation and, as a backstop, from
`sceneWillResignActive()` for the launch that never reaches a map.

Pinned by `FieldMetricsDigestTests` and `FieldMetricsStoreTests`, 29 cases
between them. Those test the arithmetic and the bounded store; they cannot test
the payloads, because `MXMetricPayload` cannot be constructed. Nothing in this
section has been observed on a device.
