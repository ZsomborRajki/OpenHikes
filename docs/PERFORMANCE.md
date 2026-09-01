# OpenHikes performance and energy

What the app costs — in frames and in battery — and what is still wrong with it.
Every number here was produced by `Scripts/run-performance-tests.sh` on an
iPhone 17 Pro simulator (iOS 26.5, Xcode 26.6, Debug); none of it is estimated.

**This is a live list, not a log.** A finding that has been fixed is deleted
rather than annotated. What stays is what
is still open, and how to read a measurement correctly — not a table of last
week's numbers, which has to be re-measured to stay true and which nobody can
act on. A run's own report carries its figures; `Scripts/performance-baseline.json`
is what a run is diffed against. The rules this harness learned, and the energy
policies it justifies, live in `.github/copilot-instructions.md` so they cannot
drift away from the code they constrain.

Two claims are under test, and they are not the same claim. *Rendering*: the
stable `@Observable` controllers exist so that high-frequency state — a GPS fix,
a finger on the elevation chart, a pushed screen — moves the map without
re-evaluating any SwiftUI body above it. *Energy*, which is the one the app
exists for: this is a hiking recorder, six hours in a pocket with the screen
off, on a phone that has to still have charge when its owner needs a map to get
down. An app that renders beautifully and flattens a battery by three in the
afternoon has failed at the only job that mattered.

## How to run it

```sh
Scripts/run-performance-tests.sh          # whole suite → PerformanceReports/<timestamp>/report.md
Scripts/run-performance-tests.sh --list
Scripts/run-performance-tests.sh --test testBackgroundRecordingCostsNothingPerFix
Scripts/run-performance-tests.sh --keep-going   # still report when a budget fails
Scripts/run-performance-tests.sh --baseline <file>
Scripts/run-performance-tests.sh --update-baseline
Scripts/run-performance-tests.sh --device <name|udid>
```

`--device` is resolved to a single UDID before anything runs, and the
`xcodebuild` destination, the location clear, the location grant and the
container read all address that UDID. `simctl booted` is not a device — with
two simulators up it is whichever one simctl picks — so the report could
otherwise be assembled out of files belonging to a device that ran nothing. A
run that collects no scenario logs fails on that alone, however green the suite
was: a measurement that did not happen passes every budget in it.

Debug is mandatory rather than incidental: `RenderSignpost`, `PerformanceLog`
and `MainThreadWatchdog` all compile to nothing in Release, so a Release run
would measure an app that reports nothing. The MetricKit integration is the
exact inverse — it ships in Release and reports nothing here — which is why the
two coexist rather than compete.

`PerformanceReports/` is git-ignored. A run is evidence on the machine that
produced it and nowhere else, so this document carries the numbers rather than
the paths. `Scripts/performance-baseline.json` is the exception, and is tracked:
it holds the counters and XCTest metrics a whole-suite run is diffed against, so
the report says what *changed* rather than only what stayed inside a budget.
That direction matters more than it looks. Every assertion in the suite is an
upper bound, and an upper bound cannot notice work that has stopped — the 1 Hz
recording clock once froze because a refactor made its view structurally
identical on every tick, and it scored perfectly against every budget while
doing so. The diff reports a counter that *fell*, a counter that reached zero,
and a counter the run never reported at all, each as its own finding.

Record one on an otherwise idle machine, and re-record it deliberately rather
than to make a red report go away. There is no baseline in the tree today: the
numbers below were measured on one developer's hardware, and a file committed
from that run would be asserting them for everyone.

Three pieces do the measuring, because no single one sees the whole picture.
`PerformanceLog` is a debug-only text sink switched on by
`--ui-test-performance-log=<scenario>`, appending under a lock while formatting
and file I/O happen on a utility queue, so the instrument does not become the
thing being measured. `PerformanceCounterProbe` is a 1×1 `UIViewRepresentable`
whose `accessibilityValue` is computed *on demand* — the only channel by which
an out-of-process XCUITest can read in-app counters, and necessarily pull-based,
since a value captured when the body runs would need a render to report a
render. `PerformanceUITests` drives real gestures and asserts on *differences*
rather than absolutes, because a test cannot control what the app did before the
gesture it cares about. `Scripts/perf-report.py` joins the test's output with
the app's event file into the markdown report.

## Reading a measurement

Two shapes in this harness are routinely misread.

`RecordingTailRebuilt` and `MapRecordingTraceApplied` are **2.0 per fix by
design**, not by tolerance. `accept(_:)` appends the raw coordinate so the line
keeps up with the walker, then the asynchronous trail match returns and replaces
the provisional tail with snapped geometry. The two land 11–72 ms apart, so the
raw tail really is on screen for a frame or three before it snaps — which is the
feature rather than waste, since the alternative is a line that lags the walker
by the matcher's latency. Each rebuild costs 0.02–0.03 ms. The budget is 2.5
rather than 1.5 because a test that fails permanently is a test everyone learns
to ignore; what is worth defending is that it stays two and does not grow.

The **footprint peak under XCUITest is automation, not the app.** Absolute
footprint measured this way is not the app's footprint: driven by `simctl`
alone the same build sits substantially lower, because every counter read and
element query makes the app build an accessibility snapshot. Only deltas within
a single phase mean anything, and even those are contaminated by however much
querying the phase does — a scenario that ends below where it started has
leaked nothing, whatever its peak said.

## What a hike costs a battery

Battery has no single counter an app can read — `UIDevice.batteryLevel` is
quantised to 5% and useless over a thirty-second test — so the report puts four
proxies side by side per scenario: CPU seconds, radio wake-ups, GPS duty, and
screen work.

Per-scenario CPU-per-hour figures are in the generated report, and they are
**shapes rather than values**: they are whole-run figures that include launch
and the automation's own polling, and they say more about how hard a scenario
queries the accessibility tree than about the feature they name. The chart phase
burns 2.21 CPU-s while evaluating *zero* chart bodies, which is XCUITest
hit-testing; backgrounded recording reads *above* screen-on recording for the
same reason, since it polls the counters hardest.

The comparable pair is per accepted fix, where the phases are like for like:
**0.488 s screen on against 0.225 s backgrounded**. Putting the phone in a
pocket halves the per-fix cost, which is the right shape — and since that is how
the app is used for all but a few minutes of a walk, the backgrounded number is
the one that decides whether the battery lasts.

Every scenario's report also includes the location funnel, because "the GPS is
busy" and "the GPS is busy and we are throwing the results away" cost identical
energy and need opposite fixes:

```
LocationFixDelivered   → CoreLocation handed us a fix
LocationPublished      → it passed LocationManager's filters
RecordingFixReceived   → it reached the recorder
LiveFixAccepted        → it became part of the route
RecordingFixRejected   → it did not
```

`Scripts/perf-report.py` raises a rejection rate above 50% as a finding: full
GPS duty paid, half a route recorded.

## Open findings

### P1 — Launch blocks the main thread for ~600 ms

`XCTApplicationLaunchMetric` puts first-responsive-frame at **1.471 s**, and the
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

Two things are known about the bisection intervals and neither is fixed.
`ModelContainerInit` carries three `#Index<Hike>` indexes built at store-open,
traded for a faster hike list on a large store, with nothing measuring the
benefit. `AppModelInit` had one attributable cause — two `CKContainer` default
arguments constructed synchronously and used only from `async` readers, now
`@autoclosure @escaping` factories behind a `lazy var` — which bought about 2 ms
of mean and 6 ms of worst case and did not move the first frame at all. Roughly
14 ms of `AppModelInit` and the whole of the first-frame cost remain
unattributed.

*Next step:* put a signpost interval around each dependency
`OpenHikesModel.init` constructs rather than guessing again, and find out how
much of the sheet hierarchy is genuinely required for the first frame.

The stall is asserted rather than merely recorded: `assertLaunchStall(atMost:in:)`
fails `testIdleCostsNothing` above a **1200 ms** ceiling — a tripwire set well
above the observed range, not a target, because the target is to remove the work
rather than to hold a line around it. It needed a budget shape of its own, since
launch is over before any measured phase begins, so it reads the watchdog's
*maximum* out of the counter tally instead of a delta.

### P2 — Panning still reaches the sheet, sometimes

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

### P3 — A tap on the elevation chart scrubs nothing

Nine taps along the elevation profile produce **zero** `ElevationChartBody`
evaluations, where a continuous drag over the same pixels produces 17. So the
render cost of a tap is nil, and what is left is behavioural: a tap does not
scrub.

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
start/stop edges would show a regression first.

## Blind spots

Things this harness structurally cannot see, listed so nobody mistakes silence
for a passing grade.

- **A real hike-length recording.** Every energy number above extrapolates from
  a three-fix scenario. `Scripts/simulate-hike.sh` plus the Energy Log
  instrument over a full GPX is the only way to know whether the per-fix cost is
  flat. Instrumented but not answered: the `RecordingSession` `mxSignpost`
  interval attributes cumulative CPU, average footprint and logical writes to
  one whole walk. The instrument is in; the walk has not been taken.
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
  reload is invisible here. Both rendering findings this suite did catch were in
  code that *had* marks.
- **A long recording, and a gallery larger than the strip.** No scenario drives
  hundreds of fixes, so O(n)-per-fix shapes show up as an argument rather than a
  slope. `--ui-test-seed-photos` caps at 24, and the thumbnail tier is bounded at
  32 MB of decoded bytes — roughly 42 thumbnails — so eviction is routine on a
  long strip and the ~19 ms re-decode is the price. Whether that trade is sized
  right is a measurement nobody has taken.

Two smaller gaps worth deciding rather than drifting on. `isIdleTimerDisabled`
is never set, which is the right default — but a walker navigating a junction
with the screen dimming every 30 s reaches for the power button repeatedly, and
each wake costs more than the timeout saved; that wants a setting rather than a
constant. And nothing has re-checked periodic work since 2026-08-26, when a
reading of the tree found `RecordingClockTick` to be the only periodic path in
the shipping app. That was a reading, not a measurement.

## Validating on a device

Static review and a Simulator can identify unnecessary work but cannot certify
battery life. On a physical device with a fixed route, capture Energy Log,
Location activity, Network, CPU wakeups, thermal state and disk writes for:

1. Foreground map browsing and live follow without recording.
2. Screen-locked background recording with normal connectivity.
3. Screen-locked recording with no service or a failing Overpass endpoint.
4. A 20-minute stationary pause.
5. Auto-save and a maximum-budget offline download.

Compare against the same device, route, screen state and radio conditions rather
than against a universal percentage-per-hour target.

Scenarios 2, 3 and 5 also report without a tethered device, since a whole
recording carries a `RecordingSession` MetricKit interval and a bulk download
carries `OfflineDownload`. Cumulative CPU, average footprint and logical writes
for each arrive in the next daily payload and can be read in
**Settings ▸ Device Reports**. That is aggregated and a day late, so it does not
replace the tethered run — it establishes whether the tethered run is worth
scheduling, and it is the only form in which these scenarios get measured on
anyone else's phone.

Nothing is uploaded. Reports are written locally, bounded on disk at 16 reports
and 4 MB, and leave the device only through an explicit share sheet. Nothing in
this section has been observed on a device.

## Chasing a problem you can feel

The suite catches regressions in scenarios someone thought to write. This is how
to chase one you cannot name.

1. **Turn on the signpost console.** Set `RENDER_SIGNPOST_LOG=1` in the scheme's
   run action and use the app. Every body evaluation, map update and matcher run
   prints as it happens; if something re-renders when you touch an unrelated
   control, you will see it before you can measure it.
2. **Watch it in Instruments.** The same marks are `os_signpost` events, so
   *File › Recording Options › os_signpost* plus the **Energy Log** and
   **Location Energy Impact** instruments give the render stream and the battery
   cost on one timeline. This is the only way to see a radio wake-up you did not
   cause.
3. **Reproduce it as a scenario.** Add a `test…` to `PerformanceUITests`, launch
   with `--ui-test-performance-log=<name>`, wrap the interaction in
   `measurePhase(named:in:seconds:)`, and read the counter deltas. If the number
   is stable, assert it; if it is not, the instability is the finding.
4. **Drive a real route.** `Scripts/simulate-hike.sh` plays a GPX through the
   simulator for long-running behaviour a three-fix scenario cannot show —
   drift, growth per fix, the accumulator deciding you have stopped.
5. **Read the energy section.** Radio wake-ups, refused fetches by reason, the
   location funnel, and every GPS reconfiguration with a timestamp. A scenario
   that renders perfectly and opens forty connections is a bug this document
   cares about just as much.
