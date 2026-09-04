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

## What the findings list will not say

`## Findings` is the first thing in the generated report and the only part of it
anyone reads in a hurry, so what it is allowed to flag is a decision rather than
a leftover. Three rules keep it about the app rather than about the instrument,
and a fourth keeps it short enough to finish.

The 16 ms frame budget applies only to intervals that **held the main thread**.
`RenderSignpost` stamps every interval it records with the thread it ran on, and
work deliberately kept off the frame — a `@concurrent` photo decode, a tile
sweep under an `assertOffMainThread` — cannot miss a frame however long it
takes. Unstamped, it lands in the same undifferentiated list as
`ModelContainerInit` and `AppModelInit`, which do hold the main thread and are
the launch cost *Open findings* below leads with: the one class of finding that
should stand out, formatted identically to the class that should not appear.

A per-accepted-fix body ratio counts only what is left after the phase's **scene
transitions**. Backgrounding and re-foregrounding redraw the tree once each and
always will, so charging a phase's whole body count to the fixes inside it reads
a backgrounded phase that evaluated *zero* bodies between its fixes as 1.33
evaluations per fix — the same error the network side deprecated as "requests
per accepted fix". `testBackgroundRecordingCostsNothingPerFix` asserts against
the transition count rather than the fix count for that reason, and the report
now agrees with it.

The sampler's own entries — `Process`, `Footprint.MB` and `CPU.s` — are not
counters about the app. `Process` is emitted once a second for the length of a
scenario, so reading it as work done while idle flags every scenario longer than
two seconds whatever the app is doing; the other two are gauges whose "count" is
a number of megabytes and a number of seconds.

A finding the whole app shares is stated **once**, naming the scenarios that saw
it and the worst number among them. Ten scenarios run against one app, so a
launch cost every one of them pays is one fact, not nine findings.

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

Every scenario's report also includes the location funnels, because "the GPS is
busy" and "the GPS is busy and we are throwing the results away" cost identical
energy and need opposite fixes. One funnel per `CLLocationManager`, and the app
runs three: they do not share fixes and do not cost the same, so a stage is
only ever compared against the stream it came from.

```
map — LocationManager
  LocationFixDelivered   → CoreLocation handed the map a fix
  LocationPublished      → it passed LocationManager's filters

recording — SystemRecordingLocationSource
  RecordingFixDelivered  → CoreLocation handed the recorder a fix
  RecordingFixReceived   → it reached a live recording
  LiveFixAccepted        → it became part of the route
  RecordingFixRejected   → it did not

background — BackgroundTrailTracker
  BackgroundFixDelivered → a significant-change wake delivered a fix
  BackgroundFixMatched   → it was worth matching against the trail
```

The recording funnel is the one that decides the battery: it is the manager
that keeps running with the screen off.

`Scripts/perf-report.py` raises a rejection rate above 50% as a finding — of
the fixes that reached the recorder, not of the map's deliveries — full GPS
duty paid, half a route recorded.

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

### P4 — Backgrounding blocks the main thread for 115–272 ms, in UIKit's snapshot

Going to the background, the main thread is busy for **115–272 ms** in a single
run-loop turn, in every scenario. It is not the app's resign handler:
`SceneResignActive` runs in **1–2 ms** and the `mainContext.save()` inside it in
**0.7–1.2 ms**. Almost all of it happens *after* that handler has returned.

`ScenePhaseTurn` is what reads it. The span opens in
`OpenHikesModel.scenePhaseChanged(to:)` and closes on the next main-queue drain,
which is a different run-loop stage from the scene-settings callout the handler
is called inside — so it covers everything the main thread goes on to do before
it is free again, including the part the app has no callback for. Worst turn per
scenario, in each of two whole-suite runs:

| Scenario | Worst turn, two runs | What is on screen |
|---|---|---|
| `chart-scrub` | **272, 271 ms** | hike detail, elevation chart |
| `photo-discovery` | **231, 226 ms** | discovery sheet over hike detail |
| `settings` | 186, 184 ms | Settings pushed |
| `recording` | 143, 138 ms | recording |
| `background-recording` | 140, 138 ms | recording |
| `idle` | 133, 136 ms | bare map |
| `photo-gallery` | 129, 129 ms | photo strip |
| `map-browsing` | 117, 123 ms | bare map |
| `offline-browsing` | 115, 123 ms | bare map |

**What it is.** A `sample` of the process across a `press(.home)` puts the main
thread, in every sample taken inside the window, under
`-[UIApplication _performSnapshotsWithAction:forScene:completion:]` →
`_applyOverrideSettings:forActions:` → `CA::Transaction::commit()` →
`_UIHostingView.layoutSubviews()`. iOS renders the app-switcher card by applying
an override trait collection to the scene and laying the hosting view out —
**twice**, once per appearance, as two `FBSSceneSnapshotAction` requests. There
is no callback inside it, which is why the window used to read as blank.

So the cost is a full layout pass of whatever is on screen, paid twice, at a
moment the app does not choose. That is why it tracks the screen rather than the
scenario: ~120 ms for the map alone, ~270 ms with the elevation chart up. Only
`.background` does it — `.inactive` and `.active` run the same handler in 2–4 ms
and their own turns are 100 ms or less.

**None of the three candidates this section used to list owns it.** The
`mainContext.save()` is 0.7–1.2 ms of a 272 ms turn. The `MapSheetHikesBody`
`@Query` refresh the window appeared to close on happens *after* the turn ends,
not inside it — the block is one run-loop turn and the refetch is the next one.
UIKit's snapshot was the third guess and it is the whole of it.

**What came off it.** `ElevationChartView` applied `.foregroundStyle` to each
mark rather than to the series, so a `LinearGradient` and the two
`Color.opacity` calls behind it were built once per plotted sample — up to
`RouteProfile.plottedSampleBudget`, 500 of them — on every pass of that body,
including both snapshot passes. Applied to the two `ForEach`es instead it is
built once and the picture is identical. `chart-scrub`'s background turn went
**301 → 265 ms** and its `.inactive` turn **123 → 102 ms**, in two runs either
side; `photo-discovery` reads 231 ms because the same chart is behind its sheet.

**What is left is the system's, and a device would say how much.** A layout pass
of the visible screen, twice, is what iOS costs an app for the switcher card;
the ~120 ms the bare map reads is the floor this app can reach without changing
what it draws. How much of *that* is the Simulator's synchronous round trip to
its render server is not answerable here — see *Blind spots* — and it is the
first thing to check on a device before anyone spends more on the screens above
the floor.

`assertSceneTurn(atMost:in:scenario:)` holds a ceiling of 450 ms. It replaces
nothing: `assertStalls(atMost:in:scenario:)` still holds launch + 1, and the two
answer different questions. A stall is only recorded when the watchdog's ping
lands inside the blocked window, and the loop turns every ~350 ms — so a
reliable 270 ms block is caught about half the time, which is exactly why this
finding was reported here as "216–372 ms" moving between six scenarios instead
of as one number belonging to all of them. Counting stalls samples the
problem; timing the turn measures it.

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
2. **Ask SwiftUI which property changed.** `RenderSignpost` says a body ran; it
   cannot say why. `let _ = Self._logChanges()` at the top of that body makes
   SwiftUI name the inputs that differed, and it logs rather than prints, so it
   is readable from a headless UI-test run:

   ```sh
   xcrun simctl spawn <udid> log stream --level debug \
       --predicate 'category == "Changed Body Properties"'
   ```

   That is how `@Environment(\.dismiss)` was caught re-rendering five screens on
   every scene transition — seven of eight passes named `_dismiss` and nothing
   else. Take it out again once the question is answered; it is a debugging
   line, not instrumentation.
3. **Sample the process, when nothing the app marks is running.** Some windows
   belong to no mark because nothing in them is the app's to mark. The
   Simulator's app is an ordinary macOS process, so `sample` reaches it:

   ```sh
   sample $(pgrep -x OpenHikes) 9 1 -mayDie -f /tmp/turn.txt
   ```

   Start it a few seconds before the moment in question, then read the main
   thread's tree and correlate the timestamps against the scenario's event file.
   That is how P4's blank ~300 ms was identified as UIKit's app-switcher
   snapshot — every sample inside the window was under
   `_performSnapshotsWithAction:`, which no signpost of ours could have named.
   A `Time Profiler` trace answers the same question with a nicer timeline and a
   lot more setup.
4. **Watch it in Instruments.** The same marks are `os_signpost` events, so
   *File › Recording Options › os_signpost* plus the **Energy Log** and
   **Location Energy Impact** instruments give the render stream and the battery
   cost on one timeline. This is the only way to see a radio wake-up you did not
   cause.
5. **Reproduce it as a scenario.** Add a `test…` to `PerformanceUITests`, launch
   with `--ui-test-performance-log=<name>`, wrap the interaction in
   `measurePhase(named:in:seconds:)`, and read the counter deltas. If the number
   is stable, assert it; if it is not, the instability is the finding.
6. **Drive a real route.** `Scripts/simulate-hike.sh` plays a GPX through the
   simulator for long-running behaviour a three-fix scenario cannot show —
   drift, growth per fix, the accumulator deciding you have stopped.
7. **Read the energy section.** Radio wake-ups, refused fetches by reason, the
   location funnel, and every GPS reconfiguration with a timestamp. A scenario
   that renders perfectly and opens forty connections is a bug this document
   cares about just as much.
