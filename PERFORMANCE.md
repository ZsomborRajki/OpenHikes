# OpenTrails performance

A record of what the app actually costs, how that was measured, and what to do
about it. Every number here was produced by `Scripts/run-performance-tests.sh`
on an iPhone 17 Pro simulator (iOS 26.5, Xcode 26.6, Debug); none of it is
estimated.

The measurement exists because the architecture makes a specific, falsifiable
claim. `RouteHighlight`, `SheetMetrics`, `RouteStyle`, `MapController`,
`TrackerState` and `LocationManager` are stable `@Observable` reference types
precisely so that high-frequency state — a GPS fix, a finger on the elevation
chart — moves the map without re-evaluating any SwiftUI body above it. That is
either true or it isn't, and until now nothing checked.

## How to run it

```sh
# Whole suite, report written to PerformanceReports/<timestamp>/report.md
Scripts/run-performance-tests.sh

# One scenario
Scripts/run-performance-tests.sh --test testLiveRecordingCostPerFix
Scripts/run-performance-tests.sh --list

# Still produce a report when a budget fails
Scripts/run-performance-tests.sh --keep-going
```

Debug is mandatory, not incidental: `RenderSignpost`, `PerformanceLog` and
`MainThreadWatchdog` all compile to nothing in Release, so a Release run would
measure an app that reports nothing at all.

## How it works

Three pieces, because no single one of them can see the whole picture.

**`PerformanceLog`** (`OpenTrails/General/Diagnostics/PerformanceLog.swift`) is
a debug-only text sink, switched on by `--ui-test-performance-log=<scenario>`.
Every `RenderSignpost` mark and interval, every `MainThreadWatchdog` stall and a
1 Hz CPU/footprint sample land in
`Documents/PerformanceLogs/<scenario>.tsv` as
`epoch_s, elapsed_s, kind, name, value, detail`. The recording path only takes a
lock and appends a struct; formatting and file I/O happen on a utility serial
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
prints with the app's event file and writes the markdown report.

### Three measurement traps this had to solve

Worth recording, because each produced a convincing wrong answer first.

*The observer perturbs the observed.* The first interaction with a
newly-presented screen forces XCUITest to hit-test against a fresh snapshot of a
hierarchy it has not described before, and SwiftUI evaluates bodies to answer.
Charged to the gesture, this made the chart scrub look like it re-rendered
`HikeDetailBody` five times when the drag accounts for two — and whether it did
depended on where the snapshot happened to fall, so the same code reported 2 and
5 on consecutive runs. `warmAccessibilityTree(around:in:)` pays that cost before
the baseline reading.

*A fixed settle time cannot be both correct and fast.* Waiting a constant three
seconds after an interaction was long enough to waste three seconds on every
phase and still short enough to occasionally include the previous phase's tail.
`settle(in:)` instead polls the app's own counters and returns once nothing has
re-rendered for 1.5 s, ignoring the sampler's own entries — which tick every
second regardless and would otherwise mean the app never looked quiet.

*A permission dialog must not decide whether you get data.* The recording
scenario reset the location authorization and relied on a UI interruption
monitor to answer the resulting alert. When that failed, Core Location delivered
nothing, the recorder accepted no fixes, and the run produced fifty-one seconds
of an idle app — which looks like a measurement but is the absence of one.
`Scripts/run-performance-tests.sh` now grants the permission out-of-band with
`simctl privacy` and the test no longer resets it; the monitor stays as a
fallback.

## Baseline — 2026-08-14

### What is already right

These are the load-bearing claims of the architecture, and they hold.

| Scenario | Measurement | Result |
|---|---|---|
| Idle, 7 s, map visible | body evaluations | **0** |
| Idle, 7 s | CPU | **0.034 s — 0.5% of one core** |
| Chart scrub, one drag | `ElevationChartBody` | 15 |
| Chart scrub, one drag | `OpenTrailsViewBody`, `MapSheetBody`, `MapRouteRebuilt` | **0, 0, 0** |
| Map browsing, 17 s of pans and zooms | `OpenTrailsViewBody` | 1–2 |
| Live recording | `TrailMatcherWork` on the main thread | **0** (off-main, 0.2–4 ms) |

A sustained scrub moves the map marker fifteen times without re-evaluating a
single body above the chart, and an idle app with a map on screen costs half a
percent of one core. The render-isolation design does what it claims.

### Finding 1 — launch blocks the main thread for ~600 ms (P1)

`XCTApplicationLaunchMetric` puts first-responsive-frame at **1.371 s**
(RSD 0.47%, n=3). The watchdog reports a **534–685 ms** unbroken main-thread
stall in *every* scenario. The bisection intervals split it as:

| Span | Cost |
|---|---|
| `ModelContainerInit` (SwiftData) | 24–29 ms |
| `AppModelInit` (whole `OpenTrailsModel`, includes the above) | 48–55 ms |
| SwiftUI/UIKit bootstrap before the first body runs | **~240 ms** |
| First render → main thread free again | **~370 ms** |

Inside that last 370 ms, `MapViewCreated` → `MapRecordingTraceApplied` alone is
**~62 ms** of `MKMapView` construction, and the sheet renders three to four
times before the app settles.

The 240 ms of framework bootstrap is not ours. The ~370 ms of first render
largely is.

### Finding 2 — the 210 MB "recording footprint" is the harness, not the app (P1, resolved)

The first read of the data said the recording scenario settled at 210 MB
against 87–95 MB everywhere else, and that looked like the most serious thing
in this document — 210 MB resident is where a backgrounded recording starts
being a jetsam candidate, and a recording that gets killed loses the hike.

It is not real. Launching the same build outside XCUITest, driven only by
`simctl`, and giving it every ingredient the recording scenario has:

| Configuration | Settled footprint |
|---|---|
| `--ui-testing` alone | 74.0 MB |
| `+ --ui-test-enable-location` | 74.3 MB |
| `+ --ui-test-trail-graph=ThumseeRidgePath` | 73.8 MB |
| both | 74.1 MB |
| both, **with a simulated location the map follows** | 77.7 MB |

Neither Core Location, nor the bundled trail graph, nor a map actively
following a position and loading tiles for it moves the number. The same app
under UI automation reports 95–223 MB.

The difference is the automation. Every counter read, every `waitForExistence`,
every element query makes the app build an accessibility snapshot of its
hierarchy, and the recording scenario polls far more than the others — it waits
on `recording-point-count` in a loop for the whole walk.

**The rule this establishes: absolute footprint under XCUITest is not the app's
footprint.** Only footprint *deltas inside a single phase* mean anything, and
even those are contaminated by however much querying the phase does. Measuring
the real number requires a run that nothing is watching, which is what the
`simctl` table above is.

A later run makes the same point from inside the harness: the recording scenario
peaks at 205.7 MB and **ends at 83.8 MB**, having started at 84.2 MB. Nothing
was leaked and nothing settled high — the peak is transient automation cost that
is handed straight back. The original "settled at 210 MB" reading was the last
sample of a run that was still being queried when it stopped.

Recorded here rather than deleted because the wrong version of this finding was
convincing, and the next person to read a memory column off a UI-test run
deserves to know that first.

### Finding 3 — every accepted fix does the trace work twice (P2)

| Counter | Per accepted fix |
|---|---|
| `RecordingTailRebuilt` | **2.0** |
| `MapRecordingTraceApplied` | **2.0** |
| `LiveTrailMatchApplied` | 1.0 |
| `TrailMatcherWork` | 1.0 |

Reproduced identically across five runs. The cause is visible in the event
timeline and is *by design*: `receive(_:)` calls
`trace.append(coordinate, provisional: true)` so the raw fix draws immediately,
then the live match returns and `applyLiveMatch(…)` replaces the provisional
tail with the snapped geometry. Two genuine state changes, two revisions, two
overlay rebuilds.

What makes it worth fixing is *when* the second one lands:

```
15.0948  LocationPublished
15.0949  RecordingTailRebuilt      0.010 ms
15.0968  MapRecordingTraceApplied            <- draws the raw fix
15.1013  TrailMatcherWork          4.060 ms
15.1014  RecordingTailRebuilt      0.006 ms
15.1015  MapRecordingTraceApplied            <- draws the snapped fix, 4.7 ms later
```

0.7–4.7 ms apart, inside the same frame, on all three fixes. The intermediate
state is never presented to anyone. The app removes and re-adds an `MKPolyline`
to show a point it then discards.

The absolute cost today is small — `rebuildTail` is 0.006–0.06 ms. The problem
is its *shape*: `rebuildTail()` copied the entire stable tail (up to 255
coordinates) on every call, so the per-fix cost grew with the recording and was
paid twice.

**Fixed.** `RecordingTrace` now caches how much of `tail` came from the stable
half and validates that cache with a `stableRevision` counter, so a fix that
only moves the provisional tail — the common case — costs the provisional
remainder instead of the whole tail. It also compares the rebuilt remainder
against the previous one and publishes a revision only when the geometry
actually moved, which matters because a stationary recorder produces the same
matched geometry repeatedly and each published revision costs an `MKPolyline`
allocation and a MapKit overlay swap to redraw an identical line.
`MapCoordinator` now takes separate `tailRevision`/`reviewRevision` tokens, so a
revision that moved one overlay no longer rebuilds the other.

Measured over the same three-fix walk, with a four-point tail:

| | Before | After |
|---|---|---|
| `RecordingTailRebuilt` mean | 0.0256 ms | **0.0194 ms** |
| `RecordingTailRebuilt` max | 0.0638 ms | **0.0365 ms** |

A 24% mean and 43% peak improvement on a tail four coordinates long, which is
the least favourable case the change has — the saving is proportional to the
stable tail, and this one is nearly empty. Proving the rest of it needs the
long-recording scenario in the P3 list.

The count stays at 2.0 per fix, and the budget now says 2.5 rather than 1.5:
two publications per fix is correct, and a test that fails permanently is a
test everyone learns to ignore. What is worth defending is that it stays two.

`RecordingTraceTests` pins all of it — an identical match publishing nothing, a
real move still publishing, a commit underneath the cached prefix producing the
tail a full rebuild would, and `reset()` invalidating the cache.

### Finding 4 — discrete taps on the chart cost more than dragging across it (P3)

Thirteen taps along the elevation profile produced **1** `OpenTrailsViewBody`,
**2** `MapSheetBody`, **3** `MapSheetHikesBody` and **3** `HikeDetailBody` — and
**zero** `ElevationChartBody`. A continuous drag over the same pixels produced
15 chart bodies and nothing above them.

So a tap does not scrub at all, while still costing renders somewhere above the
chart. Low priority — nobody taps a chart repeatedly — but it says a scrub's
start/stop edges are not as isolated as its middle, and that is where a future
regression would appear first. Note that one run produced *no* renders at all
during the tap phase, so part of this is whatever the automation is doing rather
than the taps themselves; that is the first thing to establish.

## TODO

### P1

- [x] ~~Attribute the 210 MB recording footprint.~~ Done — it is the automation,
      not the app (Finding 2). The app settles at 78 MB with location, trail
      graph and a following map.
- [ ] **Cut the first render.** ~370 ms between the first body and a free main
      thread, of which ~62 ms is `MKMapView` construction and the rest is a
      sheet that renders three to four times before settling. Find out how much
      of the sheet hierarchy is required for the first frame.
- [ ] **Assert the launch stall.** The watchdog records it; nothing fails on it.
      A ceiling somewhat above today's 685 ms turns a regression into a test
      failure instead of a thing someone notices on an old device.

### P2

- [x] ~~Make `rebuildTail()` cost the provisional tail, not the whole tail.~~
      Done — mean per-fix cost down 24%, peak down 43% (Finding 3).
- [x] ~~Stop rebuilding unchanged overlays in `applyRecordingTrace`.~~ Done —
      the tail and review polylines now carry independent change tokens.
- [x] ~~Keep the per-fix budget honest.~~ Done — 2.5, with the reasoning in the
      test.
- [x] ~~Publish no revision when a fix changes nothing.~~ Done — a fix dropped by
      `appendDistinct` as too close to the last no longer bumps `stableRevision`,
      so it neither publishes a revision nor invalidates the tail's prefix
      cache. A stationary recorder now costs nothing per fix beyond the match.

### P3

- [ ] Work out why a tap on the elevation chart renders the sheet but not the
      chart (Finding 4).
- [ ] Add a `--ui-test-*` scenario for a long recording (hundreds of fixes) so
      the O(n)-per-fix shapes show up as a slope rather than as an argument.
      This is also what would size the `rebuildTail()` win properly.
- [ ] Run the suite on a device once. `XCTHitchMetric` needs a signpost stream
      the Simulator does not emit — it raises inside `harvestData` rather than
      degrading — so frame-level hitch data is the one thing this harness cannot
      currently produce.
- [ ] Give the report generator a `--baseline` flag so a run can be diffed
      against a stored one instead of by hand.

## Where this stands

Verified on 2026-08-14, iPhone 17 Pro simulator, iOS 26.5, Xcode 26.6:

| Check | Result |
|---|---|
| `PerformanceUITests` | 5 of 5 passed |
| App and widget unit tests | 633 passed |
| `swiftlint --strict` | Clean |
| Launch, first responsive frame | 1.364 s, RSD 0.87% (n=3) |
| `RecordingTailRebuilt` per fix | 2.0, mean 0.019 ms (was 0.026 ms) |
| Recording footprint | 84.2 MB start → 83.8 MB end, 205.7 MB transient peak |

The P2 work is done and pinned by `RecordingTraceTests`. What remains is the two
P1 launch items, which are about the ~370 ms first render rather than about
anything measured here being wrong, and the P3 list.

Two caveats for anyone reading a future run. Memory columns from a UI-test run
describe the harness as much as the app (Finding 2). And the suite has never run
on a physical device, which is the only place `XCTHitchMetric` works and the
only place the launch number means what a user would experience.
