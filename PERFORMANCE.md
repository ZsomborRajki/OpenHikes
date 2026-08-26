# OpenHikes performance and energy

A record of what the app actually costs — in frames and in battery — how that
was measured, and what to do about it. Every number here was produced by
`Scripts/run-performance-tests.sh` on an iPhone 17 Pro simulator (iOS 26.5,
Xcode 26.6, Debug); none of it is estimated.

There are two claims to check, and they are not the same claim.

The first is about *rendering*. `RouteHighlight`, `SheetMetrics`, `RouteStyle`,
`MapController`, `TrackerState` and `LocationManager` are stable `@Observable`
reference types precisely so that high-frequency state — a GPS fix, a finger on
the elevation chart — moves the map without re-evaluating any SwiftUI body
above it.

The second is about *energy*, and it is the one the app exists for. This is a
hiking recorder: it runs for six hours, in a pocket, with the screen off, on a
phone that has to still have charge when its owner needs a map to get down. An
app that renders beautifully and flattens a battery by three in the afternoon
has failed at the only job that mattered. Energy is therefore not a subsection
of performance here. It is the other half of the document.

Both claims are either true or they aren't, and both are now measured across
eight scenarios.

One lesson is worth putting before the numbers, because it is the only one that
generalises. Every energy finding in this document — E1 through E5 — was a
piece of work the app was doing that nobody had decided it should do, and in
every case the prevailing assumption before the measurement was that it was
already fine. The GPS was assumed to be adaptive; it was pinned. The
backgrounded map was assumed not to draw; it drew twice per fix. The 1 Hz clock
was assumed to be suspended by the system; it ran all the way through a pocket.
None of these were visible in the code by reading it, and none were expensive
enough to feel. On a device that has to last six hours, the costs that matter
are the ones nobody chose.

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
measure an app that reports nothing at all. The MetricKit integration
described under [The other half](#the-other-half--metrickit-in-the-field) is
the exact inverse — it ships in Release and reports nothing here — which is why
the two coexist rather than compete.

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
per-scenario **Energy** section described below.

### Six measurement traps this had to solve

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

*A cache is a lie detector that has already been bribed.* The offline scenario
asserts that browsing the map opens no connection. On its first run it passed
instantly and proved nothing: every tile in the fixture region was already on
disk from the *previous* scenario, so there was no miss, no fetch to refuse and
no policy under test. `--ui-test-offline` now also hands the launch an empty
tile root (`AppLaunchEnvironment.isolatedTileRoot()`), which turns 0 refusals
into 45 and the assertion into a real one.

*A harness failure will happily impersonate a product failure.* Running the
suite four times back to back produced a different set of failures each time —
`kAXErrorServerNotFound`, `Error getting main window`, `Application … is not
running` — and never the same test twice. None of them were assertions; all of
them were the accessibility server being asked about an app that had not
finished coming forward, after `launch()` or after `activate()`. Both return
before the state they name is true. `bringToForeground(_:)` and the wait added
to `launch()` block on `XCUIApplication.wait(for: .runningForeground)` first, so
a genuine regression is now the only thing that can fail these tests. The
lesson generalises: when a performance suite starts failing *differently* on
each run, suspect the harness before the app.

*Instrumenting a thing can break it.* The 1 Hz clock in Finding E5 became
countable by moving the readout into its own small view — which stored the
recorder, made the view structurally identical on every tick, and so stopped the
clock the instrument was there to measure. It then reported one tick per
recording and looked like excellent news. Two rules came out of it. A view
extracted purely to be counted must store the *value* being displayed, not the
object it came from, or SwiftUI's diff will skip it. And a suite made entirely
of upper bounds cannot notice work that has stopped happening: `RecordingClockTick`
now has a lower-bound assertion in the foreground scenario as well as an upper
bound in the backgrounded one, and any counter measuring work that is *supposed*
to happen needs the same pair.

Two smaller ones, both from the photo scenario, both cheap to re-learn the hard
way. `warmAccessibilityTree(around:in:)` performs a real centre tap, so warming
on the photo strip — where every pixel is a button — navigates into the viewer
before the phase starts; warm on a harmless element on the same screen instead,
since the cost being paid off belongs to the screen, not the element. And a
counter that ticks on a timer must be added to the `sampled` exclusion set in
`PerformanceCounters.isEquivalent(to:)`, or `settle(in:)` never sees the app go
quiet and every recording scenario spins to its timeout.

## Baseline — 2026-08-17

Eight scenarios, all passing. `PerformanceReports/20260817-084046/`.

This run is the first to include the photo pipeline, which landed in `d06ff4b`
after the previous baseline and was, until now, the largest feature in the app
with no performance number attached to it at all. It is also the run that found
the app's last per-second wake-up still running with the screen off — see
Finding E5, which is the most consequential thing in this document.

> **Two changes have landed since this baseline that it does not reflect.**
> Neither invalidates a number below, because neither is on a path these
> scenarios measure, but both change what a re-run should be expected to show.
> The photo thumbnail cache is now bounded at 32 MB of decoded bytes rather
> than at a count of 200, so a long strip evicts where it previously did not
> (see the P3 gallery item under TODO). And the tile renderer now re-arms its
> retry timer at the end of every draw pass rather than only on a failure,
> which adds one `ContinuousClock` deadline comparison per pass and removes a
> class of permanently-missing tile. Both are described in `CODE_REVIEW.md`'s
> 2026-08-25 pass.

### What is already right

These are the load-bearing claims of the architecture, and they hold.

| Scenario | Measurement | Result |
|---|---|---|
| Idle, 7 s, map visible | body evaluations | **0** |
| Idle, 7 s | CPU | **0.047 s — 0.7% of one core** |
| Chart scrub, one drag | `ElevationChartBody` | 19 |
| Chart scrub, one drag | `OpenHikesViewBody`, `MapSheetBody`, `MapRouteRebuilt` | **0, 0, 0** |
| Map browsing, 17 s of pans and zooms | `OpenHikesViewBody` | 2 |
| Live recording | `TrailMatcherWork` on the main thread | **0** (off-main) |
| Offline browsing, 17 s | connections opened | **0**, with 45 fetches refused |
| Backgrounded recording | SwiftUI bodies per fix | **0** |
| Photo strip, scrolled | decodes, bodies, stalls | **0, 0, 0** |
| Whole suite | connections opened | **0** in every scenario |

A sustained scrub moves the map marker nineteen times without re-evaluating a
single body above the chart; an idle app with a map on screen costs under one
percent of one core; a recording in a pocket does no rendering work at all; and
scrolling a gallery of eight 12 MP photos re-decodes nothing.

## Energy

### What a hike actually costs

Battery has no single counter an app can read, and the one iOS does expose —
`UIDevice.batteryLevel` — is quantised to 5% and useless over a test that lasts
thirty seconds. What the app can see are four proxies, and the report now puts
them side by side per scenario:

1. **CPU seconds.** The most direct thing under our control.
2. **Radio wake-ups** — `TileNetworkFetch`, `WeatherFetch`, `TrailGraphFetch`,
   counted and timed. A cellular radio that has to be woken costs far more than
   the bytes it moves, especially at one bar.
3. **GPS duty** — the location funnel, below, plus which accuracy profile was
   in force and when it changed.
4. **Screen work** — the body-evaluation counts the rest of this document is
   about, which matter to energy only while the screen is actually on.

Extrapolated to a hiking hour from the current run:

| Scenario | CPU per hour (extrapolated) |
|---|---|
| Idle with the map up | 250 CPU-s |
| Offline browsing | 284 CPU-s |
| Map browsing (online) | 333 CPU-s |
| Recording, backgrounded | 403 CPU-s |
| Live recording, screen on | 406 CPU-s |
| Photo gallery | 510 CPU-s |
| Chart scrubbing | 627 CPU-s |

Read those with care: they are whole-run figures that include launch and the
automation's own polling, and they say more about how much a scenario queries
the accessibility tree than about the feature it names. The chart-scrub and
photo figures are the clearest example — a thirteen-tap phase burns 1.99 CPU-s
while evaluating *zero* bodies, which is XCUITest hit-testing, not the app. The
comparable figure is per accepted fix, where the phases are like for like:

| | CPU per accepted fix |
|---|---|
| Recording, screen on | 0.340 s |
| Recording, backgrounded | **0.217 s** |

Putting the phone in a pocket cuts the per-fix cost by a third, which is the
right shape — and, since that is how the app is used for all but a few minutes
of a walk, the backgrounded number is the one that decides whether the battery
lasts. Immediately before Finding E5 was fixed the same phase measured 0.244 s;
the improvement is real but it is a few percent on a noisy figure, and the
argument for that change rests on the 21,600 redraws it removes over a real
walk rather than on this number.

### The location funnel

Every scenario's report now includes this, because "the GPS is busy" and "the
GPS is busy and we are throwing the results away" cost identical energy and
need opposite fixes:

```
LocationFixDelivered   → CoreLocation handed us a fix
LocationPublished      → it passed LocationManager's filters
RecordingFixReceived   → it reached the recorder
LiveFixAccepted        → it became part of the route
RecordingFixRejected   → it did not
```

A high rejection rate is not a recording problem, it is an energy problem: full
GPS duty paid, half a route recorded. `Scripts/perf-report.py` raises it as a
finding above 50%.

### Finding E1 — the GPS never stepped down (fixed)

Until this change the recorder pinned `kCLLocationAccuracyBest` with a 10 m
distance filter for the entire walk and never reconsidered. Low Power Mode was
read exactly once, to show a warning; `thermalState` was not read anywhere in
the app. So the app told the walker their phone was struggling and then carried
on asking for the most expensive positioning mode iOS offers, for six hours.

`RecordingEnergyPolicy` replaces the constant with a function of conditions,
along two axes that answer to different authorities:

| | Precise (default) | Conserving |
|---|---|---|
| `desiredAccuracy` | `kCLLocationAccuracyBest` | `kCLLocationAccuracyNearestTenMeters` |
| `distanceFilter`, moving | 10 m | 20 m |
| `distanceFilter`, stationary | 25 m | 25 m |

`desiredAccuracy` moves only for Low Power Mode or thermal `.serious` and
above — both explicit signals that the *user or the system* wants less work
done, and neither something an app should overrule for a slightly smoother
line. `distanceFilter` moves for those and for standing still, taking the
larger of the two candidates: both conditions are reasons to be woken less, and
standing still in Low Power Mode is not a reason to be woken more than either
alone.

Three thresholds worth defending:

*Why the filter is the better lever.* It is applied inside `locationd`. Raising
it stops the fix before it costs this process a delegate callback, a main-actor
hop and a `RecordingFixPolicy` evaluation that was only ever going to reject it.

*Why accuracy is not lowered merely for standing still.* A stationary walker is
one step from a moving one, and the first fix after they set off anchors the
next leg of the track. Buying a little energy by making that fix coarse is a bad
trade for a route somebody keeps. A raised filter costs nothing there, because a
step past the filter distance still arrives at full accuracy.

*Why `.fair` thermal is excluded.* A phone in a jacket pocket in direct sun
reaches `.fair` and stays there for an entire summer walk. Treating it as a
signal would make the conserving profile the normal one — and a mitigation
that is always on is indistinguishable from having lowered the default.

`PowerStateMonitor` watches both notifications and re-evaluates, so the
transition that has no fix to prompt it — a walker stopping for lunch while the
battery crosses 20% — still reconfigures. Each application emits
`RecordingEnergyProfileApplied` with the profile name and filter, and the
recording screen now explains itself in the walker's terms: *"Low Power Mode —
recording at ten-metre accuracy to save battery."*

Pinned by `RecordingEnergyPolicyTests` (the decision) and
`HikeRecorderTests+Energy` (that the decision reaches CoreLocation, at the
right moments, and is not re-applied when it has not changed).

### Finding E2 — nothing acted on network conditions (fixed)

`NWPathMonitor` was already running and its `isExpensive` and `isConstrained`
flags were already being delivered. The cache read neither. A tile miss on one
bar of cellular in a valley — the most expensive networking a phone can do,
because a weak signal makes the radio transmit harder and for longer — was
treated exactly like a miss on home Wi-Fi.

`TileNetworkPolicy` now decides, split by purpose rather than by caller, because
what matters is whether anyone is waiting for the tile: `loadTile` takes that as
a parameter and defaults to `.interactive`, while `saveTileDurably` — the
bulk-download path — fixes it at `.speculative`:

| Condition | Interactive (drawing now) | Speculative (prefetch) |
|---|---|---|
| Offline | denied | denied |
| Low Data Mode (`isConstrained`) | denied | denied |
| Cellular (`isExpensive`) | **allowed** | denied (`cellular-speculative`) |
| Low Power Mode | allowed | denied |
| Thermal `.serious`+ | allowed | denied |

The asymmetry is the point. A walker looking at the map gets their tile; what
stops is the app spending a metered, expensive radio on tiles nobody has asked
to see.

None of it is configurable, on purpose. There was briefly a **Settings › Data
Use › Download Maps on Cellular** switch; it is gone. A switch is a question the
walker has to answer correctly *before* the walk to get the right behaviour
during it, and the app is meant to be pocketed and walked with rather than
configured. The policy instead assumes a connection is available wherever the
walker is and spends as little of it as it can: everything nobody is waiting for
is given up the moment the connection turns metered, throttled or constrained,
and everything the walker is actually looking at still loads. That is exactly
what the removed switch did in its default position, so no walker who never
opened Settings sees any change — and none of them can now reach the position
where a blank map looked like a bug. Low Data Mode remains the one condition
that reaches interactive traffic, because it is an explicit per-network
instruction from the user and a hiking app is not the exception.

Every refusal emits `TileFetchSuppressed` with `purpose=` and `reason=`, which
matters more than it sounds: a tile that silently never loads is the hardest
thing in this pipeline to debug, and this policy creates exactly that situation
on purpose. The reasons are also grouped into a table in the report.

Pinned by `TileNetworkPolicyTests` (the decision) and four cases in
`TileTransportTests` that drive it through the real cache.

### Finding E3 — a backgrounded recording drew a map nobody could see (fixed)

Measured on the first run of the new background scenario: with the app
backgrounded and fixes still arriving, `MapRecordingTraceApplied` fired **2.0
times per fix**. Each one allocates an `MKPolyline` and makes MapKit drop and
re-render the old overlay — for a map that is not on screen. Over a six-hour
walk at ~2000 fixes that is four thousand overlay swaps whose entire output is
discarded.

`MapView.Coordinator` now gates the apply on foreground, observed through
`UIApplication` lifecycle notifications rather than `scenePhase` so it stays
entirely off SwiftUI's render path. The `withObservationTracking` registration
continues regardless — the revision must keep being tracked or the map would
never learn about the fixes that arrived while it was away. The work is
deferred, not dropped, and caught up in a single pass on return, which draws an
hour of pocket walking for the price of one fix.

| | Before | After |
|---|---|---|
| `MapRecordingTraceApplied`, 3 backgrounded fixes | 6 | **1** |
| …per fix | 2.0 | **0.33** |

`RecordingTailRebuilt` stays at 2.0 per fix and should: that is the in-memory
trace, which has to keep up so the catch-up pass has something correct to draw.
It costs 0.02 ms.

### Finding E4 — what a backgrounded fix costs now

The measured answer, from `testBackgroundRecordingCostsNothingPerFix`:

| Counter | Total, 3 fixes | Per fix |
|---|---|---|
| `ScenePhaseChanged` | 4 | — |
| `OpenHikesViewBody` | 4 | **0** beyond the transitions |
| `MapSheetHikesBody` | 4 | **0** beyond the transitions |
| `MapSheetBody` | 4 | **0** beyond the transitions |
| `RecordingBody` | 4 | **0** beyond the transitions |
| `RecordingClockTick` | 2 | **0** beyond the transitions (see E5) |
| `MapRecordingTraceApplied` | 1 | **0.33** |
| `RecordingTailRebuilt` | 6 | 2.0 (in-memory only) |

Four bodies for four scene transitions, and nothing per fix. The test asserts
exactly that shape — body count ≤ transition count — rather than a constant,
because a per-fix budget would pass *more* easily the longer the walk, which is
backwards.

### Finding E5 — the elapsed clock ticked all the way through a pocket (fixed)

The previous version of this document listed, under P2, "suppress the 1 Hz
`TimelineView` in `RecordingView` while backgrounded", with the note that *it
is almost certainly already suspended by the system, but "almost certainly" is
not a measurement*. It was not suspended. The measurement, once there was one,
said so immediately:

```
10.96 s  ScenePhaseChanged     ← app backgrounded
11.76 s  RecordingClockTick
12.76 s  RecordingClockTick
…        one per second, unbroken
23.76 s  RecordingClockTick
23.93 s  ScenePhaseChanged     ← app foregrounded
```

Thirteen ticks in the thirteen backgrounded seconds, at a steady 1 Hz, with the
screen off — no gap while backgrounded and no catch-up burst on return, which
rules out the comfortable explanation that the system had coalesced them. (The
phase counter reads 17, which includes the foreground moments either side.) Each
tick re-evaluates a view and re-lays out a `Text` that nobody can see. Over a
six-hour walk that is **~21,600 redraws** of a hidden label.

The assumption was reasonable and wrong for a specific reason: iOS suspends a
backgrounded app, and a suspended app runs no timers — but *this* app is not
suspended. It holds the location background mode for the entire hike, which is
exactly what keeps it running, and a running app's `TimelineView` schedule keeps
firing. The one app that most needs the timer to stop is the one app where it
does not stop by itself.

`RecordingHeader` now builds the `TimelineView` only while `scenePhase` is
`.active`. This is on SwiftUI's render path, unlike `MapView.Coordinator`'s
notification observers in E3, and deliberately so: the question is not whether
to do some work when a fix arrives, it is whether the `TimelineView` is *in the
hierarchy at all*, and only SwiftUI can answer that. The cost is bounded by
scene transitions rather than by fixes. Nothing is lost by not counting — the
readout derives from a timestamp rather than accumulating, so it is correct
again on the first tick after return.

| | Before | After |
|---|---|---|
| `RecordingClockTick`, measured phase | 17 | **2** |
| …of which backgrounded | 13 | **0** |
| …extrapolated over a six-hour walk | ~21,600 | **~0** |
| CPU per backgrounded fix | 0.244 s | **0.217 s** |

The CPU row is the weakest of the three and is included for completeness rather
than as the argument: it is a few percent on a figure that varies by more than
that between runs. The case for this change is the redraw count, which is not
noisy — it is one per second, for as long as the walk lasts.

Gating on `.active` rather than on `!= .background` turns out to matter more
than it looks. In the measured run the ticks stop at `inactive` — 1.3 s before
`background` — and resume 0.01 s after `active` returns. That covers the states
a walker is actually in most often: the notification shade pulled down, the app
switcher open, the screen locked but the app not yet backgrounded. None of those
show the readout either.

The residue is the foreground moments either side of the transition, which is
why the budget is "at most one per scene transition" rather than zero.

Two assertions pin it, and it needs both. `testBackgroundRecordingCostsNothingPerFix`
bounds the backgrounded count by the transition count; `testLiveRecordingCostPerFix`
asserts the *lower* bound that the clock still ticks roughly once a second in
the foreground. The lower bound exists because this finding was created by its
own instrumentation: extracting the readout into a `RecordingClock` view that
stored only the recorder made the view structurally identical on every tick, so
SwiftUI skipped its body and the timer silently froze. Every budget in this
suite is an upper bound, and a frozen clock scores perfectly against all of
them. The view now stores the formatted string, so what SwiftUI diffs is the
thing on screen.

## Rendering findings

### Finding 1 — launch blocks the main thread for ~600 ms (P1)

`XCTApplicationLaunchMetric` puts first-responsive-frame at **1.398 s**
(RSD 0.142%, n=3). The watchdog reports a **526–673 ms** unbroken main-thread
stall in *every* scenario. The bisection intervals split it as:

| Span | Cost |
|---|---|
| `ModelContainerInit` (SwiftData) | 27.8–31.2 ms |
| `AppModelInit` (whole `OpenHikesModel`, includes the above) | 50.5–59.4 ms |
| SwiftUI/UIKit bootstrap before the first body runs | **~240 ms** |
| First render → main thread free again | **~370 ms** |

Inside that last 370 ms, `MapViewCreated` → `MapRecordingTraceApplied` alone is
**~62 ms** of `MKMapView` construction, and the sheet renders three to four
times before the app settles.

Both bisection intervals grew about 15% since the previous baseline
(`ModelContainerInit` 24–26 → 27.8–31.2 ms, `AppModelInit` 46–53 → 50.5–59.4 ms).
The container's share is attributable: `Hike.photos` is a relationship, so
`HikePhoto` joined the schema transitively and SwiftData has one more entity to
describe before it can open the store. It is small against the ~600 ms total and
it is not the thing to fix first, but it is the direction this number moves
every time an entity lands, and it is the only part of launch that grows with
the app rather than with the framework.

The 240 ms of framework bootstrap is not ours. The ~370 ms of first render
largely is. This is also the largest single *energy* item in a short session,
which is worth saying out loud: a walker who opens the app to check where they
are, and closes it, pays this and almost nothing else.

The stall is now asserted rather than merely recorded. `testIdleCostsNothing`
fails above a **1200 ms** ceiling — a tripwire set well above the observed
range, not a target, because the target is to remove the work rather than to
hold a line around it. It needed a budget shape of its own: launch is over
before any measured phase begins, so the four existing budgets, which all
compare counters across a phase, could not see it. `assertLaunchStall(atMost:in:)`
reads the watchdog's *maximum* out of the counter tally instead of a delta,
which is why `PerformanceCounters` parses the `Name=count/max` form at all.

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
under UI automation reports 95–225 MB.

The difference is the automation. Every counter read, every `waitForExistence`,
every element query makes the app build an accessibility snapshot of its
hierarchy, and the recording scenarios poll far more than the others.

**The rule this establishes: absolute footprint under XCUITest is not the app's
footprint.** Only footprint *deltas inside a single phase* mean anything, and
even those are contaminated by however much querying the phase does.

The current run makes the same point from inside the harness: recording peaks at
160.6 MB and **ends at 91.9 MB**, having started at 97.0 MB; the backgrounded
scenario peaks at 160.1 MB and ends at 91.5 MB from 93.9 MB. Nothing was leaked
and nothing settled high — the peak is transient automation cost handed straight
back.

Every settled figure is up about 8 MB on the previous baseline (83–84 MB →
91–92 MB), and that part is a genuine change rather than harness noise, since it
appears at the *end* of every scenario including the ones that never open a
photo. It is not attributed here: the photo pipeline is the largest thing that
landed between the two baselines but not the only one, and nothing in this
harness isolates a fixed cost by feature. The peaks moved the other way, from
213–225 MB down to ~160 MB, which is not an improvement anyone made — it is the
same automation variance this finding exists to warn about.

Recorded here rather than deleted because the wrong version of this finding was
convincing, and the next person to read a memory column off a UI-test run
deserves to know that first.

### Finding 3 — every accepted fix does the trace work twice (P2, resolved)

| Counter | Per accepted fix |
|---|---|
| `RecordingTailRebuilt` | **2.0** |
| `MapRecordingTraceApplied` | **2.0** (foreground; 0.33 backgrounded — see E3) |
| `LiveTrailMatchApplied` | 1.0 |
| `TrailMatcherWork` | 1.0 |

Reproduced identically across every run. The cause is visible in the event
timeline and is *by design*: `accept(_:)` calls
`trace.append(accepted.coordinate, provisional: liveMatchingEnabled)` so the raw
fix draws immediately, then the live match returns and `applyLiveMatch(…)`
replaces the provisional tail with the snapped geometry. Two genuine state
changes, two revisions, two
overlay rebuilds — 0.7–4.7 ms apart, inside the same frame. The intermediate
state is never presented to anyone.

**Fixed.** `RecordingTrace` now caches how much of `tail` came from the stable
half and validates that cache with a `stableRevision` counter, so a fix that
only moves the provisional tail — the common case — costs the provisional
remainder instead of the whole tail. It also compares the rebuilt remainder
against the previous one and publishes a revision only when the geometry
actually moved, which matters because a stationary recorder produces the same
matched geometry repeatedly. `MapView.Coordinator` takes separate
`tailRevision`/`reviewRevision` tokens, so a revision that moved one overlay no
longer rebuilds the other.

| | Before | After |
|---|---|---|
| `RecordingTailRebuilt` mean | 0.0256 ms | **0.0194 ms** |
| `RecordingTailRebuilt` max | 0.0638 ms | **0.0365 ms** |

A 24% mean and 43% peak improvement on a tail four coordinates long, which is
the least favourable case the change has. Proving the rest of it needs the
long-recording scenario in the P3 list.

The count stays at 2.0 per fix, and the budget says 2.5 rather than 1.5: two
publications per fix is correct, and a test that fails permanently is a test
everyone learns to ignore. What is worth defending is that it stays two.

### Finding 4 — a tap on the elevation chart does nothing at all (P3)

Thirteen taps along the elevation profile produce **zero** body evaluations of
anything — no `ElevationChartBody`, and none of the `OpenHikesViewBody`,
`MapSheetBody`, `MapSheetHikesBody` or `HikeDetailBody` this used to cost (1, 2,
3 and 3 respectively at the previous baseline). A continuous drag over the same
pixels produces 19 chart bodies and nothing above them.

So the render cost of this is gone, and what is left is the behavioural half:
a tap does not scrub.

**The cause stated here was wrong and is now unknown.** This said "the gesture
is drag-only". There is no hand-written gesture involved: scrubbing is
`.chartXSelection(value:)` (`ElevationChartView.swift:94`), and Swift Charts
documents that as handling taps as well as drags. Grepping the tree for
`DragGesture` returns nothing, in this file or anywhere else in the app — the
explanation appears to have been written from an assumption about how chart
scrubbing is usually built rather than from this implementation. Corrected on
2026-08-25; see `CODE_REVIEW.md`'s pass of that date, §B.

The symptom is real and reproduced by the measurement above; only the diagnosis
is retracted. Settling it needs a run against the actual view, not another
reading — the candidates are the chart's hit area, an overlay above it, or the
selection resolving and being immediately discarded. Still low priority —
nobody taps a chart repeatedly — but it remains the place where a scrub's
start/stop edges would show a regression first, and it is worth knowing that
the phase still burns 1.99 CPU-s while evaluating nothing, all of it XCUITest
hit-testing thirteen times.

### Finding 5 — panning re-renders the hike list (P2, variable)

Map browsing produces up to **4** `MapSheetHikesBody`, **3** `MapSheetBody` and
**2** `OpenHikesViewBody` for a gesture that changes no hike and selects
nothing. Until this was budgeted the hike list was not measured at all, which is
how it grew.

It is small in absolute terms and it is not on the per-fix path, but panning is
the single most common thing anyone does in this app, and a `@Query`-backed
list re-evaluating on it is exactly the shape that becomes expensive when
somebody has two hundred hikes. Budgeted at 4 in
`testMapBrowsingDoesNotReRenderTheSheet`, which stops it growing while the cause
is found.

Worth recording that this is not a stable number: an intermediate run during
this session reported **1** of each for the same gesture against the same build,
and the final run reported 4/3/2 again. Whatever drives it depends on how the
pan lands rather than on the code, so the budget stays at 4 and the cause is
still unexplained. A single good run here is not evidence that it was fixed —
which is exactly the mistake this note exists to prevent.

### Finding 6 — the photo gallery pays for exactly what it shows

The photo pipeline was the largest feature in the app with no performance
number at all, which made it the obvious next scenario. It needed the app's
help to exist: the Simulator has no camera and the library picker is a system
process automation may not touch, so `--ui-test-seed-photos=<count>` attaches
synthetic 12 MP JPEGs through the real `HikePhotoImport`. Only the pixels are
invented — the files, the store, and the ImageIO decode path underneath are the
shipping ones.

Three phases, eight seeded photos:

| Phase | What it does | Cost |
|---|---|---|
| `photo-strip` | scrolls the gallery strip end to end | **0** decodes, **0** bodies, **0** stalls, +0.02 MB |
| `photo-viewer` | opens one photo full screen | **2** `PhotoImageDecoded`, +3.19 MB |
| `photo-paging` | swipes to the next photo | **1** `PhotoImageDecoded`, **0** bodies above the viewer, +0.22 MB |

The strip is the important row. Scrolling a gallery re-decodes nothing and
re-renders nothing above it: thumbnails are decoded once, at **20.4 ms median
(20.6 ms max)** each, and all eight complete within the same millisecond of each
other, so the set costs about 21 ms of wall time rather than 8 × 20 ms. That is
the `@concurrent` loader and the `.task`-per-cell shape working as intended.

The viewer's **2** decodes on open looks like duplicated work and is not. The
paging phase is what settles it: a page turn costs exactly **1** decode, so the
horizontally-paged `ScrollView`'s `LazyHStack` is realising the current page
plus one lookahead. Opening photo *n* decodes *n* and *n+1*; turning to *n+1*
decodes *n+2*. Paging through all eight therefore costs nine decodes, not
sixteen and not twenty-four. Without the paging phase the honest reading of "2"
is a bug, which is why the scenario has three phases rather than two.

A full-size decode is **73.9 ms median, 76.0 ms max** — three and a half times a
thumbnail, and far more than a frame, which is why it matters that it cannot
reach the main thread: `HikePhotoLoader` is `@concurrent`, and
`HikePhotoStore`'s decode entry points call `assertOffMainThread`, so a future
change that moved this work onto the main actor would trap in Debug rather than
quietly drop frames.

The scenario also found a real bug on its first run, and it is the one this
repository's own conventions warn about. `HikePhotoSection`'s `VStack` carried
`.accessibilityIdentifier("photos-section")` and the inner `ScrollView` carried
`hike-photo-strip`. SwiftUI pushes a container's identifier down onto every
descendant, so the container won: three unrelated elements all answered to
`photos-section` and `hike-photo-strip` was unreachable from automation
entirely. That is a shipped accessibility defect, not a test problem — VoiceOver
sees the same flattened tree. The container identifier is gone.

## Finding a UI performance problem while using the app
The suite above catches regressions in scenarios someone thought to write. This
is how to chase one you can feel but cannot name.

**1. Turn on the signpost console.** Set `RENDER_SIGNPOST_LOG=1` in the scheme's
run action, run on a device or simulator, and use the app. Every body
evaluation, map update and matcher run prints as it happens. If something
re-renders when you touch an unrelated control, you will see it in the stream
before you can measure it.

**2. Watch it in Instruments.** The same marks are `os_signpost` events, so
*File › Recording Options › os_signpost* plus the **Energy Log** and **Location
Energy Impact** instruments give the render stream and the battery cost on one
timeline. This is the only way to see a radio wake-up you did not cause and a
GPS duty cycle you did not ask for.

**3. Reproduce it as a scenario.** Add a `test…` to `PerformanceUITests`, launch
with `--ui-test-performance-log=<name>`, wrap the interaction in
`measurePhase(named:in:seconds:)`, and read the counter deltas. If the number
is stable, assert it; if it is not, the instability is the finding.

**4. Drive a real route.** `Scripts/simulate-hike.sh` plays a GPX through the
simulator for long-running behaviour that a three-fix scenario cannot show —
drift, growth per fix, the accumulator deciding you have stopped.

**5. Check the energy section of the report.** Radio wake-ups, refused fetches
by reason, the location funnel, and every GPS reconfiguration with a timestamp.
A scenario that renders perfectly and opens forty connections is a bug this
document cares about just as much.

Useful launch arguments, all gated behind `--ui-testing`:

| Argument | Effect |
|---|---|
| `--ui-test-performance-log=<scenario>` | Opens the event log and the counter probe |
| `--ui-test-offline` | Holds `TileCache` offline **and** gives it an empty tile root |
| `--ui-test-enable-location` | Uses real simulator Core Location |
| `--ui-test-import-gpx=<name>` | Imports a bundled GPX fixture |
| `--ui-test-trail-graph=<name>` | Matches against a bundled graph instead of Overpass |
| `--ui-test-seed-photos=<count>` | Attaches synthetic 12 MP photos to the imported hike (max 24) |
| `--ui-test-expanded-sheet` | Starts with the sheet expanded |

### Signpost reference

Rendering: `OpenHikesViewBody`, `MapSheetBody`, `MapSheetHikesBody`,
`HikeDetailBody`, `RecordingBody`, `ElevationChartBody`,
`HikePhotoSectionBody`.

Map: `MapViewCreated`, `MapUpdateCalled`, `MapRouteRebuilt`, `MapRouteRestyled`,
`MapTileSourceRebuilt`, `MapCentered`, `MapRecordingTraceApplied`.

Recording: `LocationFixDelivered`, `LocationPublished`, `RecordingFixReceived`,
`RecordingFixRejected`, `LiveFixAccepted`, `LiveTrailMatchApplied`,
`LiveFollowUpdate`, `RecordingTailRebuilt`, `TrailMatcherWork` (interval),
`RecordingEnergyProfileApplied`, `RecordingClockTick`.

Photos: `PhotoThumbnailDecoded`, `PhotoImageDecoded` (both intervals).

Energy and network: `PowerStateChanged`, `ScenePhaseChanged`,
`TileNetworkFetch` (interval), `TileFetchSuppressed`, `WeatherFetch`
(interval), `TrailGraphFetch` (interval).

Startup and I/O: `AppModelInit`, `ModelContainerInit`, `GPXParsed`,
`GPXExported`, `HikeDetailPrepared`, `HikeTrailAnalysis` (all intervals).

## The other half — MetricKit in the field

Everything above is a Debug build, on a Simulator, driving synthetic input, on
one machine. That is the right shape for a regression harness — it is
deterministic, it fails a pull request, and it can be re-run — but it is the
wrong shape for four of the questions this document keeps asking, and no amount
of work on the harness will change that. A Simulator has no battery, no
thermal state, no cellular radio, no jetsam, and no user.

MetricKit answers exactly those. It is worth being precise about what it did
and did not do to the harness:

**It replaced nothing.** Not one line of `RenderSignpost`, `PerformanceLog`,
`MainThreadWatchdog`, `PerformanceCounterProbe` or `PerformanceUITests` became
redundant. MetricKit reports once every 24 hours, aggregated across a whole
day, from a Release build, on a device, with no way to attribute a number to a
gesture. It cannot fail a build, cannot bisect a regression, and cannot tell
you that `MapSheetHikesBody` rendered four times during a pan. Anyone who reads
"MetricKit collects launch times" and concludes it supersedes
`XCTApplicationLaunchMetric` has confused a population statistic with a
measurement.

**It extended the harness into the gaps the harness is structurally shut out
of.** Which is a real answer to five open items rather than a new source of
graphs:

| Open question above | What answers it |
|---|---|
| P2 "measure a real hike-length recording's energy" — *"the one measurement this harness structurally cannot make"* | `MXAppRunTimeMetric.cumulativeBackgroundAudioTime`/`cumulativeBackgroundLocationTime` and `MXCPUMetric.cumulativeCPUTime`, plus a `RecordingSession` signpost interval that attributes CPU, memory and writes to one whole walk |
| Finding E1's leftover — *"the conserving profile has never been exercised anywhere but in unit tests"* | `MXLocationActivityMetric`'s six accuracy buckets, reduced to `LocationAccuracyBreakdown.conservingShare` |
| P3 *"`XCTHitchMetric` needs a signpost stream the Simulator does not emit"* | `MXAnimationMetric.hitchTimeRatio` (new in iOS 26) and `MXAppResponsivenessMetric.histogrammedApplicationHangTime` |
| P1 *"~370 ms between the first body and a free main thread"* | `extendLaunchMeasurement(forTaskID: .firstMapFrame)` around exactly that span, reported as `histogrammedExtendedLaunch`, plus `MXAppLaunchDiagnostic` stacks when it goes badly wrong |
| Finding 2's real worry — a backgrounded recording being jetsammed | `MXAppExitMetric.backgroundExitData`, including `cumulativeSuspendedWithLockedFileExitCount`, which is the SwiftData-sqlite-specific one |

### What was built

`OpenHikes/General/Diagnostics/FieldMetrics/` — and note it is *not* `#if
DEBUG`, unlike every other file in `Diagnostics/`. A Debug-only MetricKit
integration would report nothing, since the framework only delivers against
Release builds in the field. Six files, split along one line: what can be
tested and what cannot.

- **`FieldMetricsDigest.swift`** holds every judgement the app makes about a
  payload — the quantile walk, the shares, which exits count as unexpected —
  and imports no MetricKit at all. `MXMetricPayload` has no initializer and
  cannot be synthesised, so anything that touched it would be untestable by
  construction. This is why `FieldMetricsDigestTests` can exist.
- **`FieldMetricsDigest+MetricKit.swift`** is the adapter, kept deliberately
  thin: it reads fields and hands them across, and does nothing else.
- **`FieldMetricsStore.swift`** is an actor over a directory in Application
  Support, bounded on every write at 16 reports and 4 MB, oldest-first, with
  the newest never pruned — a crash payload larger than the whole budget is
  exactly the one worth keeping.
- **`FieldSignpost.swift`** is the `mxSignpost` wrapper and the launch
  extension.
- **`FieldMetrics.swift`** is the `MXMetricManagerSubscriber`, and the only
  thing in the app that talks to `MXMetricManager`. Not `#if DEBUG` — it is
  the bridge from the above to the framework that actually delivers payloads.
- **`SeededFieldMetricsFixture.swift`** is `#if DEBUG` and wires up
  `--ui-test-seed-metrics=N`: it writes synthetic reports through the real
  `FieldMetricsStore` so Settings ▸ Device Reports and its downstream screens
  are reachable by automation on a Simulator that never receives a live payload.

Nothing is uploaded. Reports are written locally, shown in **Settings ▸ Device
Reports**, and leave the device only through an explicit share sheet — the
position `CODE_REVIEW.md` already took, implemented rather than asserted.

### Why only four signposts

Apple's own guidance: *"To limit on-device overhead, the system will
automatically limit the number of signposts (emitted using the MetricKit log
handle) processed. Avoid losing telemetry by limiting usage of signposts to
critical sections of code."* The failure mode is silent — a fifth span does not
error, it costs the other four their data.

So the MetricKit set is four coarse, user-initiated spans, and is not the
`RenderSignpost` list:

| Span | Why |
|---|---|
| `RecordingSession` | The headline. One interval per whole walk gives cumulative CPU, average footprint and logical writes attributed to a hike-length recording. This *is* the P2 item |
| `OfflineDownload` | A bulk tile download is the largest deliberate burst of network and disk the app ever does |
| `HikeImport` | GPX parse plus trail analysis, on real files rather than fixtures |
| `TrailGraphPrefetch` | The one unavoidable Overpass round trip, on a real radio |

`TrailMatcherWork` fires roughly two thousand times per hike and
`TileNetworkFetch` hundreds; both stay `RenderSignpost`-only. `FieldSignpost.Span`
is `CaseIterable` and `FieldMetricsDigestTests` asserts the count, so a fifth
has to be added on purpose.

`RecordingSession` ends where `stopLocationSensors()` runs, not where the hike
is saved — a walker who spends ten minutes naming a hike should not be charged
for it against the recording.

### Three caveats, all of which matter

**The Simulator emits no MetricKit telemetry.** `MXSignpost_Private.h` branches
on `TARGET_OS_SIMULATOR`: on a device `mxSignpost` attaches
`_MXSignpostMetricsSnapshot()`, and on the Simulator it attaches the literal
string `NO_METRICS`. The call compiles and emits an ordinary `os_signpost`
either way, so Instruments still works — but every number in this section can
only ever be gathered on a device. Xcode's **Debug ▸ Simulate MetricKit
Payloads** is how the parsing and the UI were exercised; it is not how the
numbers were.

**Delivery is daily, and a span that outlives the period is lost.** MetricKit
delivers at most once every 24 hours, on its own schedule. An interval still
open when the aggregation period closes is not reported at all — which for a
`RecordingSession` means a recording left running overnight produces nothing.

**`extendLaunchMeasurement` must be balanced.** An extended-launch task that is
never finished stays open for the process lifetime and reports nothing, so
`LaunchMeasurement.finish()` is idempotent and is called both from `MapView`'s
creation — the actual thing being measured — and as a backstop from
`sceneWillResignActive()`, for the launch that never reaches a map at all.

## TODO

### P1

- [ ] **Cut the first render.** ~370 ms between the first body and a free main
      thread, of which ~62 ms is `MKMapView` construction and the rest is a
      sheet that renders three to four times before settling. Find out how much
      of the sheet hierarchy is required for the first frame. This is the
      dominant cost of a short "where am I" session.
- [x] ~~Assert the launch stall.~~ Done — `assertLaunchStall(atMost:in:)` fails
      `testIdleCostsNothing` above 1200 ms, against an observed 526–673 ms.
      It reads the watchdog's maximum rather than a phase delta, because launch
      is over before any phase begins.

### P2 — energy

- [x] ~~Make the GPS configuration a function of conditions.~~ Done —
      `RecordingEnergyPolicy`, Finding E1.
- [x] ~~Act on `isExpensive` / `isConstrained` / Low Power Mode for tiles.~~
      Done — `TileNetworkPolicy`, Finding E2.
- [x] ~~Stop rebuilding map overlays while backgrounded.~~ Done — 2.0 → 0.33
      applications per fix, Finding E3.
- [x] ~~Suppress the 1 Hz `TimelineView` in `RecordingView` while
      backgrounded.~~ Done, and it was **not** already suspended by the system —
      it ticked 17 times through a 13-second pocket. Finding E5.
- [ ] **Measure a real hike-length recording's energy.** Every number above
      extrapolates from a three-fix scenario. `Scripts/simulate-hike.sh` plus
      the Energy Log instrument over a full GPX is the only way to know whether
      the per-fix cost is flat, and it is the one measurement this harness
      structurally cannot make. **Instrumented on 2026-08-25, not yet
      answered**: the `RecordingSession` `mxSignpost` interval now attributes
      cumulative CPU, average footprint and logical writes to one whole walk,
      and `MXAppRunTimeMetric.cumulativeBackgroundLocationTime` gives the
      denominator. That turns this from a measurement nobody can take into one
      that needs a Release build on a device and a day's wait. The instrument
      is in; the walk has not been taken.
- [x] ~~Audit the app for any remaining periodic work.~~ Performed by
      inspection on 2026-08-25. `RecordingClockTick` is in fact the only
      periodic path in the shipping app: `RecordingView.swift:232`'s
      `TimelineView` is the one E5 gated, and the only other repeating timer in
      the tree is `PerformanceLog`'s own 1 Hz sampler, which is `#if DEBUG` and
      exists to take these measurements. Three things that look periodic and
      are not, checked individually so the next sweep does not re-flag them:
      `AutoSaveController`'s drain is signal-driven and its own comment records
      that it used to poll every 2 s and no longer does;
      `CachingTileOverlayRenderer`'s retry wake is a one-shot armed from a
      backoff deadline; and `HikeRecorder+Helpers`' scheduling is event-driven.
      This was a reading, not a measurement — an Energy Log over a full hike
      would still be the thing that proves it, and that is the item above.
- [ ] **Consider `isIdleTimerDisabled` deliberately.** The app never sets it,
      which is the right default — but a walker navigating a junction with the
      screen dimming every 30 s will reach for the power button repeatedly, and
      each wake costs more than the timeout saved. Worth a setting rather than
      a constant.

### P2 — rendering

- [x] ~~Make `rebuildTail()` cost the provisional tail, not the whole tail.~~
      Done — mean per-fix cost down 24%, peak down 43% (Finding 3).
- [x] ~~Stop rebuilding unchanged overlays in `applyRecordingTrace`.~~ Done —
      the tail and review polylines carry independent change tokens.
- [x] ~~Publish no revision when a fix changes nothing.~~ Done — a fix dropped by
      `appendDistinct` as too close to the last no longer bumps `stableRevision`.
- [ ] **Find out why panning re-renders `MapSheetHikesBody`** (Finding 5). Now
      budgeted, not yet explained, and now known to be run-dependent rather
      than constant.

### P3

- [ ] Work out why a tap on the elevation chart scrubs nothing (Finding 4). It
      no longer costs renders, so this is a behaviour question rather than a
      performance one.
- [ ] Add a `--ui-test-*` scenario for a long recording (hundreds of fixes) so
      the O(n)-per-fix shapes show up as a slope rather than as an argument.
      This is also what would size the `rebuildTail()` win properly, and what
      would make the per-hike-hour extrapolations above into measurements.
- [ ] Measure a gallery larger than the strip. Eight photos is enough to prove
      the strip re-decodes nothing, but not enough to show whether a hike with
      two hundred photos evicts thumbnails and re-decodes them on the way back.
      `--ui-test-seed-photos` caps at 24 today for run-time reasons.
      **The expected answer changed on 2026-08-25**, so this is worth doing
      sooner: the thumbnail tier used to be bounded only by a count of 200 —
      an effective ceiling near 150 MB of decoded bitmaps, which is why the
      question above was phrased around two hundred photos. It is now bounded
      at 32 MB of decoded bytes, roughly 42 thumbnails, so eviction is a
      routine event on any long strip rather than a pathological one, and the
      20.4 ms re-decode measured above is the cost being paid for it. Whether
      that trade is sized right is now a measurement rather than a guess. See
      `CODE_REVIEW.md`'s 2026-08-25 pass, §A.4.
- [ ] Run the suite on a device once. `XCTHitchMetric` needs a signpost stream
      the Simulator does not emit — it raises inside `harvestData` rather than
      degrading — so frame-level hitch data is the one thing this harness cannot
      currently produce. A device is also the only place thermal state ever
      leaves `.nominal`, so the conserving profile has never been exercised
      anywhere but in unit tests. It is also the only place the E5 finding can
      be confirmed in the form that matters, since the Simulator does not
      suspend apps the way a real device does.
      **This item now has a second, cheaper half.** The MetricKit integration
      answers the same three questions without a tethered run —
      `MXAnimationMetric.hitchTimeRatio` for hitches, the
      `LocationAccuracyBreakdown.conservingShare` for the conserving profile,
      and `MXAppExitMetric.backgroundExitData` for suspension — but from a
      Release build, a day late, aggregated. Neither substitutes for the other:
      a tethered run says *why*, MetricKit says *whether it happens to anyone*.
      Do the tethered run to explain a number the field data shows.
- [ ] **Read the first MetricKit payloads.** The integration is in and tested,
      but no payload has been read on a device, because the Simulator emits
      `NO_METRICS` (see above) and delivery is daily. Until a Release build has
      run on a phone for a day, every claim in "The other half" is about what
      the API reports, not about what this app does. Check first that
      `RecordingSession` appears at all — an interval that outlives the
      24-hour period is dropped silently, and a long walk is exactly the case
      that risks it.
- [ ] Give the report generator a `--baseline` flag so a run can be diffed
      against a stored one instead of by hand.

## Where this stands

Measured on 2026-08-17, iPhone 17 Pro simulator, iOS 26.5, Xcode 26.6, Debug:

| Check | Result |
|---|---|
| `PerformanceUITests` | **8 of 8 passed** |
| App and widget unit tests | **811 passed** |
| `swiftlint --strict` | Clean |
| Launch, first responsive frame | 1.398 s, RSD 0.14% (n=3) |
| Launch main-thread stall | 526–673 ms, now asserted below 1200 ms |
| Idle CPU, 7 s | 0.047 s — 0.7% of one core |
| Offline browsing | 0 connections, 45 fetches refused |
| Whole suite | 0 connections opened, in every scenario |
| Backgrounded recording | 0 bodies per fix, **0.217** CPU-s per fix |
| `RecordingClockTick` backgrounded | 17 → **2** per ~13 s |
| `MapRecordingTraceApplied` backgrounded | 2.0 → **0.33** per fix |
| `RecordingTailRebuilt` per fix | 2.0, mean 0.019 ms |
| Photo strip, scrolled | 0 decodes, 0 bodies |
| Photo thumbnail decode | 20.4 ms median, 8 concurrent |
| Recording footprint | 97.0 MB start → 91.9 MB end, 160.6 MB transient peak |

The energy work is pinned by `RecordingEnergyPolicyTests`,
`HikeRecorderTests+Energy`, `TileNetworkPolicyTests`, four cases in
`TileTransportTests`, and now by the paired `RecordingClockTick` assertions in
the two recording scenarios. What remains is the P1 first-render item, the
long-hike measurement that no simulator scenario can substitute for, the
periodic-work audit E5 argues for, and the P3 list.

The MetricKit work added on 2026-08-25 is pinned by `FieldMetricsDigestTests`
and `FieldMetricsStoreTests` (29 cases). Those test the arithmetic and the
bounded store; they cannot test the payloads, because `MXMetricPayload` cannot
be constructed. Nothing in that section has been observed on a device yet.

Four caveats for anyone reading a future run. Memory columns from a UI-test run
describe the harness as much as the app (Finding 2). The per-hike-hour energy
figures are extrapolations from thirty-second scenarios and should be treated as
shapes, not values. Some counters are not stable run to run — Finding 5 reported
4 and then 1 and then 4 again for the same build — so a single good run is not
evidence that something was fixed. And the suite has never run on a physical
device, which is the only place `XCTHitchMetric` works, the only place the launch
number means what a user would experience, the only place thermal throttling has
ever actually happened, the only place background suspension behaves as it
will for a real walker, and — since 2026-08-25 — the only place MetricKit
reports anything at all.
