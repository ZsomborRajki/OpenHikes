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

Both claims are either true or they aren't, and both are now measured.

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
measure an app that reports nothing at all.

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

### Five measurement traps this had to solve

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

## Baseline — 2026-08-14

Seven scenarios, all passing. `PerformanceReports/20260814-200407/`.

### What is already right

These are the load-bearing claims of the architecture, and they hold.

| Scenario | Measurement | Result |
|---|---|---|
| Idle, 7 s, map visible | body evaluations | **0** |
| Idle, 7 s | CPU | **0.042 s — 0.6% of one core** |
| Chart scrub, one drag | `ElevationChartBody` | 15 |
| Chart scrub, one drag | `OpenHikesViewBody`, `MapSheetBody`, `MapRouteRebuilt` | **0, 0, 0** |
| Map browsing, 17 s of pans and zooms | `OpenHikesViewBody` | 1–2 |
| Live recording | `TrailMatcherWork` on the main thread | **0** (off-main, 0.5–8.5 ms) |
| Offline browsing, 17 s | connections opened | **0**, with 45 fetches refused |
| Backgrounded recording | SwiftUI bodies per fix | **0** |

A sustained scrub moves the map marker fifteen times without re-evaluating a
single body above the chart; an idle app with a map on screen costs half a
percent of one core; and a recording in a pocket does no rendering work at all.

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
| Idle with the map up | 216 CPU-s |
| Offline browsing | 320 CPU-s |
| Map browsing (online) | 331 CPU-s |
| Live recording, screen on | 474 CPU-s |
| Recording, backgrounded | 500 CPU-s |

Read those with care: they are whole-run figures that include launch and the
automation's own polling, and the backgrounded run polls *less*, so its
apparently higher number is an artefact of a shorter run amortising the same
fixed launch cost. The comparable figure is per accepted fix, where the phases
are like for like:

| | CPU per accepted fix |
|---|---|
| Recording, screen on | 0.467 s |
| Recording, backgrounded | **0.254 s** |

Putting the phone in a pocket roughly halves the per-fix cost, which is the
right shape — and, since that is how the app is used for all but a few minutes
of a walk, the backgrounded number is the one that decides whether the battery
lasts.

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
the same `loadTile` serves a visible tile and a prefetch:

| Condition | Interactive (drawing now) | Speculative (prefetch) |
|---|---|---|
| Offline | denied | denied |
| Low Data Mode (`isConstrained`) | denied | denied |
| Cellular, setting off | denied | denied |
| Cellular, setting on | **allowed** | denied (`cellular-speculative`) |
| Low Power Mode | allowed | denied |
| Thermal `.serious`+ | allowed | denied |

The asymmetry is the point. A walker looking at the map gets their tile; what
stops is the app spending a metered, expensive radio on tiles nobody has asked
to see. Low Data Mode has no override and no setting, because it is an explicit
per-network instruction from the user and a hiking app is not the exception.
Cellular has one — **Settings › Data Use › Download Maps on Cellular**, default
on, so a first-time user on the approach road does not get a blank map and
conclude the app is broken.

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
| `RecordingBody` | 4 | **0** beyond the transitions |
| `MapRecordingTraceApplied` | 1 | **0.33** |
| `RecordingTailRebuilt` | 6 | 2.0 (in-memory only) |

Four bodies for four scene transitions, and nothing per fix. The test asserts
exactly that shape — body count ≤ transition count — rather than a constant,
because a per-fix budget would pass *more* easily the longer the walk, which is
backwards.

## Rendering findings

### Finding 1 — launch blocks the main thread for ~600 ms (P1)

`XCTApplicationLaunchMetric` puts first-responsive-frame at **1.476 s**
(RSD 1.682%, n=3). The watchdog reports a **568–713 ms** unbroken main-thread
stall in *every* scenario. The bisection intervals split it as:

| Span | Cost |
|---|---|
| `ModelContainerInit` (SwiftData) | 24–26 ms |
| `AppModelInit` (whole `OpenHikesModel`, includes the above) | 46–53 ms |
| SwiftUI/UIKit bootstrap before the first body runs | **~240 ms** |
| First render → main thread free again | **~370 ms** |

Inside that last 370 ms, `MapViewCreated` → `MapRecordingTraceApplied` alone is
**~62 ms** of `MKMapView` construction, and the sheet renders three to four
times before the app settles.

The 240 ms of framework bootstrap is not ours. The ~370 ms of first render
largely is. This is also the largest single *energy* item in a short session,
which is worth saying out loud: a walker who opens the app to check where they
are, and closes it, pays this and almost nothing else.

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
213.2 MB and **ends at 83.6 MB**, having started at 85.7 MB; the backgrounded
scenario peaks at 225.4 MB and ends at 83.1 MB from 83.3 MB. Nothing was leaked
and nothing settled high — the peak is transient automation cost handed straight
back.

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
timeline and is *by design*: `receive(_:)` calls
`trace.append(coordinate, provisional: true)` so the raw fix draws immediately,
then the live match returns and `applyLiveMatch(…)` replaces the provisional
tail with the snapped geometry. Two genuine state changes, two revisions, two
overlay rebuilds — 0.7–4.7 ms apart, inside the same frame. The intermediate
state is never presented to anyone.

**Fixed.** `RecordingTrace` now caches how much of `tail` came from the stable
half and validates that cache with a `stableRevision` counter, so a fix that
only moves the provisional tail — the common case — costs the provisional
remainder instead of the whole tail. It also compares the rebuilt remainder
against the previous one and publishes a revision only when the geometry
actually moved, which matters because a stationary recorder produces the same
matched geometry repeatedly. `MapCoordinator` takes separate
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

### Finding 4 — discrete taps on the chart cost more than dragging across it (P3)

Thirteen taps along the elevation profile produced **1** `OpenHikesViewBody`,
**2** `MapSheetBody`, **3** `MapSheetHikesBody` and **3** `HikeDetailBody` — and
**zero** `ElevationChartBody`. A continuous drag over the same pixels produced
15 chart bodies and nothing above them.

So a tap does not scrub at all, while still costing renders somewhere above the
chart. Low priority — nobody taps a chart repeatedly — but it says a scrub's
start/stop edges are not as isolated as its middle, and that is where a future
regression would appear first.

### Finding 5 — panning re-renders the hike list (P2)

Map browsing produces up to **4** `MapSheetHikesBody`, **3** `MapSheetBody` and
**2** `OpenHikesViewBody` for a gesture that changes no hike and selects
nothing. Until now only the first two were asserted; the hike list was not
budgeted at all, which is how it grew.

It is small in absolute terms and it is not on the per-fix path, but panning is
the single most common thing anyone does in this app, and a `@Query`-backed
list re-evaluating on it is exactly the shape that becomes expensive when
somebody has two hundred hikes. Now budgeted at 4 in
`testMapBrowsingDoesNotReRenderTheSheet`, which stops it growing while the cause
is found.

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
| `--ui-test-expanded-sheet` | Starts with the sheet expanded |

### Signpost reference

Rendering: `OpenHikesViewBody`, `MapSheetBody`, `MapSheetHikesBody`,
`HikeDetailBody`, `RecordingBody`, `ElevationChartBody`.

Map: `MapViewCreated`, `MapUpdateCalled`, `MapRouteRebuilt`, `MapRouteRestyled`,
`MapTileSourceRebuilt`, `MapCentered`, `MapRecordingTraceApplied`.

Recording: `LocationFixDelivered`, `LocationPublished`, `RecordingFixReceived`,
`RecordingFixRejected`, `LiveFixAccepted`, `LiveTrailMatchApplied`,
`LiveFollowUpdate`, `RecordingTailRebuilt`, `TrailMatcherWork` (interval),
`RecordingEnergyProfileApplied`.

Energy and network: `PowerStateChanged`, `ScenePhaseChanged`,
`TileNetworkFetch` (interval), `TileFetchSuppressed`, `WeatherFetch`
(interval), `TrailGraphFetch` (interval).

Startup: `AppModelInit`, `ModelContainerInit`, `GPXParsed`,
`HikeDetailPrepared` (all intervals).

## TODO

### P1

- [ ] **Cut the first render.** ~370 ms between the first body and a free main
      thread, of which ~62 ms is `MKMapView` construction and the rest is a
      sheet that renders three to four times before settling. Find out how much
      of the sheet hierarchy is required for the first frame. This is the
      dominant cost of a short "where am I" session.
- [ ] **Assert the launch stall.** The watchdog records it; nothing fails on it.
      A ceiling somewhat above today's 651 ms turns a regression into a test
      failure instead of a thing someone notices on an old device.

### P2 — energy

- [x] ~~Make the GPS configuration a function of conditions.~~ Done —
      `RecordingEnergyPolicy`, Finding E1.
- [x] ~~Act on `isExpensive` / `isConstrained` / Low Power Mode for tiles.~~
      Done — `TileNetworkPolicy`, Finding E2.
- [x] ~~Stop rebuilding map overlays while backgrounded.~~ Done — 2.0 → 0.33
      applications per fix, Finding E3.
- [ ] **Measure a real hike-length recording's energy.** Every number above
      extrapolates from a three-fix scenario. `Scripts/simulate-hike.sh` plus
      the Energy Log instrument over a full GPX is the only way to know whether
      the per-fix cost is flat, and it is the one measurement this harness
      structurally cannot make.
- [ ] **Suppress the 1 Hz `TimelineView` in `RecordingView` while
      backgrounded.** It is almost certainly already suspended by the system,
      but "almost certainly" is not a measurement, and it is the last known
      per-second wake-up in the recording path.
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
      budgeted, not yet explained.

### P3

- [ ] Work out why a tap on the elevation chart renders the sheet but not the
      chart (Finding 4).
- [ ] Add a `--ui-test-*` scenario for a long recording (hundreds of fixes) so
      the O(n)-per-fix shapes show up as a slope rather than as an argument.
      This is also what would size the `rebuildTail()` win properly, and what
      would make the per-hike-hour extrapolations above into measurements.
- [ ] Run the suite on a device once. `XCTHitchMetric` needs a signpost stream
      the Simulator does not emit — it raises inside `harvestData` rather than
      degrading — so frame-level hitch data is the one thing this harness cannot
      currently produce. A device is also the only place thermal state ever
      leaves `.nominal`, so the conserving profile has never been exercised
      anywhere but in unit tests.
- [ ] Give the report generator a `--baseline` flag so a run can be diffed
      against a stored one instead of by hand.

## Where this stands

Verified on 2026-08-14, iPhone 17 Pro simulator, iOS 26.5, Xcode 26.6:

| Check | Result |
|---|---|
| `PerformanceUITests` | **7 of 7 passed** |
| App and widget unit tests | **658 passed** (639 + 19) |
| `swiftlint --strict` | Clean |
| Launch, first responsive frame | 1.476 s, RSD 1.68% (n=3) |
| Idle CPU, 7 s | 0.042 s — 0.6% of one core |
| Offline browsing | 0 connections, 45 fetches refused |
| Backgrounded recording | 0 bodies per fix, 0.254 CPU-s per fix |
| `MapRecordingTraceApplied` backgrounded | 2.0 → **0.33** per fix |
| `RecordingTailRebuilt` per fix | 2.0, mean 0.019 ms |
| Recording footprint | 85.7 MB start → 83.6 MB end, 213.2 MB transient peak |

The energy work is done and pinned by `RecordingEnergyPolicyTests`,
`HikeRecorderTests+Energy`, `TileNetworkPolicyTests` and four cases in
`TileTransportTests`. What remains is the two P1 launch items, the long-hike
measurement that no simulator scenario can substitute for, and the P3 list.

Three caveats for anyone reading a future run. Memory columns from a UI-test run
describe the harness as much as the app (Finding 2). The per-hike-hour energy
figures are extrapolations from thirty-second scenarios and should be treated as
shapes, not values. And the suite has never run on a physical device — which is
the only place `XCTHitchMetric` works, the only place the launch number means
what a user would experience, and the only place thermal throttling has ever
actually happened.
