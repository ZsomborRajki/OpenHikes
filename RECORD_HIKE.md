# Record a Hike

Design doc for live hike recording: a second button beside Import, a dedicated recording view inside the sheet, a continuous location feed that survives the phone going into a pocket, and a matcher that turns those fixes into a route that follows the trails the walker actually took.

Phase 1 is implemented: the Record entry point, `SheetRoute`, isolated recording UI and chunked map trace, app-scoped background recorder, filtering/stationary drift control, barometric elevation fusion, append-only journal with open and completed-session recovery, and one-time SwiftData save. Phase 2 is underway with bounded Overpass prefetch, a durable low-zoom graph cache, OSM graph construction, on-device HMM matching, pedometer-constrained sparse gaps, confidence-based abstention, raw-GPS fallback, and opt-in post-recording Stadia matching. Live sliding-window matching and the post-recording ambiguity review remain open. Phase 3 is implemented: widget sampling writes a capped, separately locked pending-fix file; the recorder folds and deduplicates those anchors into the journal; `SharedRecordingSnapshot` takes over the widget with a recording deep link; and recording accuracy, snapping, online improvement, and raw-track retention are persisted in Settings.

---

## 1. Scope

**In**

- A Record button in `MapSheet.hikeActions`, beside Import.
- A recording view pushed into the sheet's `NavigationStack`, showing the live track on the map plus distance and recorded-point count.
- An app-scoped recorder that keeps running when the view is dismissed, the app is backgrounded, or the screen is locked.
- A crash-safe append-only track journal, so a jetsam kill costs at most a few seconds of track.
- Trail alignment: snapping the recorded fixes onto real trail geometry, and reconstructing the likely path across gaps where fixes are sparse.
- A new `Hike` written once, at Stop.

**Out (deliberately)**

- Elevation graph and progress bar in the recording view. Both belong to `HikeDetailView`, which the saved hike opens into anyway.
- Turn-by-turn navigation, planned routes, live sharing.
- Any backend. Trail geometry comes from a public tile-style API and is cached locally; the trace itself never leaves the device unless the user explicitly opts into online matching (§9.3).

---

## 2. Entry point

### 2.1 The button

`MapSheet.hikeActions` currently carries a comment explaining that a record button was removed because it was wired to an empty function. That comment gets replaced by the real thing:

```
Hikes                                    [●] [⤓]
```

- Idle: `record.circle`, in `.red`, label "Record a hike".
- Recording: `stop.circle.fill`, and the row grows a live pill — `0:42 · 1.2 km` — so the state is legible from the hikes list without opening the view.
- Tapping while recording reopens the recording view rather than stopping. Stop is a deliberate action inside the view, never a one-tap accident from a list screen.

The empty state's copy ("Tap ⤓ to import a GPX file") gains a second line for recording.

### 2.2 Navigation — the one real integration cost

`OpenTrailsView.navigationPath` is `[Hike]`, and `MapSheet` declares `.navigationDestination(for: Hike.self)`. A recording is not a `Hike` yet, so the path has to widen:

```swift
enum SheetRoute: Hashable {
    case hike(Hike)
    case recording
}
```

Three call sites move with it, and all three matter:

| Site | Today | After |
|---|---|---|
| `OpenTrailsView.openHike(id:)` | `navigationPath.last?.id != id` | pattern-match `.hike(let h)`; a widget tap while recording must not silently replace the recording screen — push the hike on top instead |
| `MapSheet.delete(_:)` | `path.removeAll { $0.id == hike.id }` | pattern-match; `.recording` is never removed by a hike deletion |
| `MapSheet.navigationDestination` | `for: Hike.self` | `for: SheetRoute.self`, switching to `HikeDetailView` or `RecordingView` |

The rejected alternative is presenting recording as a layered `.sheet` the way Settings is. It's less code, and it's wrong: a second sheet covers the map, and the whole point of this view is watching the line grow underneath it.

Pushing at the compact detent lands off-screen — the same trap `openHike(from:)` documents — so starting a recording does `withAnimation { detent = .medium }`.

---

## 3. The recording view

```
┌──────────────────────────────────┐
│  ● Recording          00:42:17   │   phase + elapsed
│                                  │
│  ┌────────────┐  ┌────────────┐  │
│  │  Distance  │  │   Points   │  │   StatTile, same as HikeDetailView
│  │   4.2 km   │  │    1,284   │  │
│  └────────────┘  └────────────┘  │
│  ┌────────────┐  ┌────────────┐  │
│  │ Avg Speed  │  │  Accuracy  │  │
│  │  4.1 km/h  │  │    ±8 m    │  │
│  └────────────┘  └────────────┘  │
│                                  │
│  Following: Thumsee Rundweg      │   matched trail name, when confident
│                                  │
│  [   Pause   ]  [     Stop     ] │
└──────────────────────────────────┘
```

- Distance formats through `Measurement(usage: .road)` exactly as `Hike.subtitle` does, so it reads km or mi by locale rather than hardcoding km.
- Accuracy doubles as the GPS-health indicator: `±8 m` in secondary, `Searching…` while no fix has passed the filter, `Weak signal` above 50 m.
- "Following: <trail>" appears only when the matcher is confident (§9.5). Silence is better than a confidently wrong trail name.
- No elevation graph, no progress bar — there is no denominator to be a fraction of.

### 3.1 Render isolation

This is the part of the feature most likely to be built wrong, because a recording view is a screen whose numbers change every second.

The repo's rule (`.github/copilot-instructions.md`, "Preserve render isolation") applies directly. Mirroring `TrackerState`:

```swift
@MainActor @Observable
final class RecordingStats {          // read ONLY by leaf stat views
    var distanceMeters: Double = 0
    var pointCount: Int = 0
    var horizontalAccuracy: Double?
    var matchedTrailName: String?
}
```

`RecordingView.body` never reads these properties. It passes the object down to a `RecordingStatsGrid` and a `RecordingHeader`, each of which reads only what it draws. Elapsed time is its own `TimelineView(.periodic(from:by:1))` — no state, no invalidation upward.

Add `RenderSignpost.mark("RecordingBody")` at the top of the body, alongside the existing `OpenTrailsViewBody` / `HikeDetailBody` marks. If it fires at fix frequency, someone reintroduced a read.

### 3.2 Live line on the map

`DisplayedRoute` is the wrong channel: it's `Equatable` by `id` alone, precisely so a stable selection never re-diffs its coordinates, and `MapView.updateRoute` fits the map to the route whenever the id changes. A growing track has neither property.

So the trace gets its own channel, observed imperatively by `MapView.Coordinator` the way `RouteHighlight` is:

```swift
@MainActor @Observable
final class RecordingTrace {
    nonisolated deinit {}
    private(set) var committedChunks: [[CLLocationCoordinate2D]] = []  // immutable once appended
    private(set) var tail: [CLLocationCoordinate2D] = []              // ≤ 256 points
    private(set) var revision: Int = 0                                // the only thing observed
}
```

**Chunked polylines.** Rebuilding one `MKPolyline` per fix is O(n) allocation at 1 Hz — by hour four of a hike that's 18,000 coordinates copied every second, on the main thread, for a line whose last 30 m are the only part that changed. Instead:

- Points accumulate in `tail`. Only the tail's `MKPolyline` is rebuilt, at most once a second.
- At 256 points the tail is frozen into a committed chunk, added to the map once, and never touched again. The new tail starts with the last committed point, so there is no visual seam.
- Per-update cost becomes O(256) regardless of hike length.

Draw the trace with a plain `MKPolylineRenderer`, **not** `DirectionalPolylineRenderer` — chevron layout is O(points) per draw call and the direction of a live track is not in question. Give it a distinct look from saved routes (a dashed line, or the accent tint) so a recording overlaid on a selected hike is unambiguous.

If profiling later shows even the tail rebuild is too much, the escalation is a custom `MKOverlay` reading a shared point buffer, with `setNeedsDisplay(_:zoomScale:)` on the tail's map rect only. Don't start there.

**Camera.** The recording never auto-fits. Set `mapView.userTrackingMode = .follow` when the view appears and drop it the moment the user pans, the standard behavior — an auto-fit that re-frames the whole track every few seconds makes the map unusable while walking.

---

## 4. Ownership and lifetime

```
OpenTrailsApp.init()
 ├── ModelContainer
 ├── BackgroundTrailTracker      (exists)
 ├── AutoSaveController          (exists)
 └── HikeRecorder                (new) ── owns ── RecordingLocationSource
                                          ├──── TrackJournal (off-main)
                                          ├──── RecordingStats  (@Observable)
                                          └──── RecordingTrace  (@Observable)
```

`HikeRecorder` is constructed in `OpenTrailsApp.init()` for the same reason `BackgroundTrailTracker` is, and the existing comment there already states it: a background relaunch runs `init()` unconditionally but may never reach a view's `.task`. If the recorder were created by `RecordingView`, a location-triggered relaunch would deliver its pending fix to nothing.

The corollary is the rule that makes recording behave correctly at all: **the recorder's lifetime is the app's, not the view's.** `HikeDetailView.followLocation` runs inside a `.task(id:)` and dies with the view — right for auto-follow, fatal for recording. Dismissing the recording view, browsing another hike, or locking the screen must not stop the session.

Coarse phase is low-frequency and safe to read from a body:

```swift
enum Phase: Equatable { case idle, waitingForFix, recording, paused, saving, failed(RecordingFailure) }
```

---

## 5. The location feed

### 5.1 A third CLLocationManager

The app already runs two, for documented and different reasons: `LocationManager` (continuous, when-in-use, foreground-tuned) and `BackgroundTrailTracker`'s (significant-change only, deliberately without background modes, to stay battery-friendly and avoid the persistent indicator).

Recording needs a third, and it is the one case that legitimately wants the continuous background mode the tracker avoids:

```swift
manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation   // High profile
manager.activityType = .fitness
manager.distanceFilter = kCLDistanceFilterNone     // filtering is ours (§6), not CL's
manager.pausesLocationUpdatesAutomatically = false // auto-pause silently ends hikes
manager.allowsBackgroundLocationUpdates = true     // only while a session is live
manager.showsBackgroundLocationIndicator = true
```

**Use the classic delegate API, not `CLLocationUpdate.liveUpdates()`.** `LocationManager`'s file header already records why: the async stream stalls after the first fix when the Simulator's location is driven by `simctl location … start` GPX playback. That's the only practical way to test this feature repeatedly, and `OpenTrails/SimulatedLocations/ThumseeLoopFast.gpx` exists for it. `CLBackgroundActivitySession` is the modern pairing for the stream API and can be revisited if that bug is ever fixed; it buys nothing the delegate path plus `allowsBackgroundLocationUpdates` doesn't already provide.

`allowsBackgroundLocationUpdates` is set to `true` at Start and back to `false` at Stop. Left on permanently it keeps the blue pill up and drains battery for a session that ended.

### 5.2 Authorization

Recording needs **When In Use**, not Always. When In Use plus the `location` background mode plus `allowsBackgroundLocationUpdates` keeps updates flowing while backgrounded, with the blue indicator — which is honest, and is what the user expects while a recording is running. Do not escalate to Always for recording; that prompt belongs to Background Trail Tracking and its existing purpose string.

Reduced accuracy (`accuracyAuthorization == .reducedAccuracy`) makes recording meaningless — it quantizes position to a few kilometres. Request temporary full accuracy at Start with a dedicated purpose key:

```
NSLocationTemporaryUsageDescriptionDictionary
  RecordHike = "OpenTrails needs your precise location to record the trail you walk."
```

If the user refuses, refuse to start and say why, rather than recording a straight line between two city blocks.

### 5.3 Info.plist / build settings

`GENERATE_INFOPLIST_FILE = YES`, so these are `INFOPLIST_KEY_*` build settings on both the Debug and Release app configurations:

| Key | Value |
|---|---|
| `INFOPLIST_KEY_UIBackgroundModes` | `location` |
| `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` | extend the existing string to mention recording |
| `INFOPLIST_KEY_NSMotionUsageDescription` | pedometer + barometer (§6.3, §9.4) |
| `NSLocationTemporaryUsageDescriptionDictionary` | dictionary — needs a real `Info.plist` file if the generated one can't express it |

No new entitlement. Background location is a mode, not a capability.

### 5.4 Feed tiers, and what "put the phone away" actually means

| Tier | When | Cadence | Notes |
|---|---|---|---|
| A — foreground | View visible | Every fix, gated to ~1 Hz | Best data. Map redraws. |
| B — background continuous | Screen locked / app backgrounded, session live | Same as A | **This is the normal "phone in pocket" case.** The feed does not degrade; only the UI stops. |
| C — degraded | Background mode denied, or the process was killed and not relaunched | Significant-change + visits, hundreds of metres apart, minutes to tens of minutes | Matching does the heavy lifting (§9.4) |
| D — widget sampling | Any time; opportunistic | A few dozen a day at best | Gap-filler only (§10) |

Tier B is worth stating plainly because it changes the problem's shape: with the background mode granted, pocketing the phone costs nothing but the screen. The sparse-data problem is Tier C and D — permission refused, or a jetsam kill — and those are the paths the matcher exists to rescue.

---

## 6. Accepting a fix

A pure, testable rule set, mirroring `LocationFixPolicy` (and reusing it where it already answers the question):

```swift
nonisolated enum RecordingFixPolicy {
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 50   // hard reject
    static let preferredHorizontalAccuracy: CLLocationAccuracy = 20 // below this, trust course
    static let maximumSpeed: CLLocationSpeed = 8                    // m/s; ~29 km/h
    static let minimumDisplacement: CLLocationDistance = 5
    static let maximumInterval: TimeInterval = 10                   // keep a heartbeat point
    static let bearingChangeDegrees: Double = 15
}
```

### 6.1 Gates, in order

1. `LocationFixPolicy.accepts(_:maximumAge:maximumHorizontalAccuracy:)` — reuse it. Catches invalid coordinates, negative accuracy, and the stale cached fix that arrives first on a relaunch.
2. `Mercator.isRepresentable(latitude:longitude:)` — reject beyond ±85.05°, exactly as `GPXImport.point` does. A hike at the pole is bad data, not something to clamp onto the map's edge.
3. Speed sanity: reject if the implied speed from the previous accepted point exceeds `maximumSpeed` *and* the reported `location.speed` disagrees. A single teleport (cell-tower fallback fix) otherwise adds kilometres.
4. Recording gate — append only if **any** of: moved ≥ `max(5 m, horizontalAccuracy × 0.5)`; ≥ 10 s since the last point; bearing changed > 15°.

Gate 4 is what keeps the point count sane. Ungated, a five-hour hike at 1 Hz is 18,000 points; gated, it's roughly 3,000–5,000 — which is the density GPX exports from Komoot and friends already have, and which every existing consumer (`RouteProfile`, the elevation chart's 500-sample budget, `decimate` for the widget) is tuned for.

### 6.2 Standing still

GPS wander at rest is the classic distance inflator: a phone on a picnic table adds a kilometre an hour. Two defences:

- A moving/stationary state machine with hysteresis: enter *stationary* after 30 s with net displacement < 15 m; leave it on a displacement > 20 m. While stationary, points are still journaled (for timing) but flagged, and **distance does not accumulate**.
- Optionally gate on `CMMotionActivityManager` (`stationary` vs `walking`) as corroboration. Cheap, and already needs the motion permission for §6.3.

Assert this in tests: ten minutes of jittered fixes at one spot must add < 5 m to `distanceMeters`.

### 6.3 Elevation

The recording view shows no elevation, but the saved hike's detail view draws a profile from `RouteCoordinate.elevation`, so the recorder must capture it well.

Raw GPS altitude is noisy enough that cumulative gain over a five-hour hike can be off by hundreds of metres. Fuse `CMAltimeter.startRelativeAltitudeUpdates` (barometric — excellent at deltas, drifts with weather) with GPS altitude (absolute, noisy) using a slow complementary filter: barometric deltas carry the shape, GPS anchors the absolute level over minutes. Gate GPS altitude on `verticalAccuracy` (reject > 15 m, and negative).

Store the fused value in `elevation`. `Hike.elevationGain` sums positive deltas point-to-point, so it inherits the quality directly.

---

## 7. Persistence during a session

**No SwiftData writes while recording.** `Hike.route` is an inline `Codable` array; appending to it re-encodes the whole array on every save. Over a hike that's O(n²) work on the main actor, and it would land in the middle of the map's update path. The `Hike` is created exactly once, at Stop.

### 7.1 The journal

An append-only, fixed-width binary file in the App Group container (`SharedStore` already resolves it), so the widget can read session metadata — falling back to Application Support when the App Group is unprovisioned, since nothing outside the app reads the journal before §10 and a missing entitlement must not be the difference between recording a hike and refusing to:

```
Header (64 B): magic "OTRK" | version u16 | sessionID uuid | startedAt f64 | reserved
Record (44 B): lat f64 | lon f64 | timestamp f64 | elevation f32
               | horizontalAccuracy f32 | course f32 | speed f32 | flags u32
```

The listed fields total 44 bytes. Fixed width buys three things: point count is `(fileSize − 64) / 44` without parsing; a torn tail record from a kill mid-write is detectable by a non-zero remainder and discardable; and recovery can decode complete records directly without a variable-length format.

- Written through `FileHandle` on a serial off-main actor, batched every 10 points or 5 s, `synchronize()` after each batch. 5,000 points ≈ 220 KB.
- Flush on `scenePhase` leaving `.active`, mirroring `AutoSaveController.sceneWillResignActive`.
- `assertOffMainThread("Track journal writes must stay off the main thread")` — the repo's existing pattern for hot-path work.

A sidecar `recording.json` holds session metadata (`sessionID`, `startedAt`, `endedAt`, `pausedIntervals`, `title`). `endedAt == nil` means an open session.

### 7.2 Crash recovery

On launch, `HikeRecorder` checks for an open sidecar:

- Session interrupted < 5 minutes ago and location is still authorized → resume silently, with a banner.
- Older → offer "Save the recorded track" or "Discard", with distance and duration so the user can decide.

Under `AppLaunchEnvironment.isHostingTests`, do neither. Both test bundles are hosted by the app, so it launches and runs before any test does; a recorder that auto-resumes a journal from a previous run races every suite that asserts on recording state — the same trap `restoreLastSelectedHike()` is already guarded for.

### 7.3 Interaction with existing subsystems

| Subsystem | Behavior while recording |
|---|---|
| `AutoSaveController` | Auto-save follows the *selected hike*, and a recording has none. Leave it pointed wherever it was. Claiming browsed tiles for a hike that doesn't exist yet is a bug waiting to happen; the saved hike can auto-save normally afterwards. |
| `BackgroundTrailTracker` | Coexists — its own manager, its own delegate, its own authorization. Recording must never trigger the Always prompt. |
| Widget snapshot | The recording takes over the shared snapshot (§10.1) and hands it back — pointed at the new hike — at Stop. |
| `WeatherManager` | Unaffected; it polls `LocationManager.coordinate` on its own timer. |
| `selectedHike` | Unchanged during recording. At Stop, the new hike is selected, exactly as `importGPX` does. |

---

## 8. Saving

At Stop, off-main: read the journal, run smoothing and matching, compute the distance, and hand back a prepared value. On main: build one `Hike`, insert, select, and pop to its detail view. This is `importGPX`'s shape, and it should look like it.

```swift
let hike = Hike(
    title: defaultTitle(for: startedAt),        // "Morning Hike", editable
    distanceMeters: prepared.distanceMeters,
    date: startedAt,
    tintHex: Hike.randomTintHex(),
    route: prepared.route
)
```

Refuse to save a session with fewer than two accepted points, and say so with the same wording as `GPXImport.ImportFailure.tooShort` — one point is a pin, not a route.

### 8.1 Matched geometry vs raw trace

The matched route is what the user asked for and what gets stored in `Hike.route`. The raw trace is still the only record of where the phone actually was, and a matcher that guesses wrong is unrecoverable without it.

Keep both. Add to `Hike`:

```swift
/// The unmatched GPS trace, when this hike was recorded rather than imported.
/// Inline `= []` default as well as the initializer default — SwiftData's
/// lightweight migration cannot backfill a mandatory attribute without it.
var rawRoute: [RouteCoordinate] = []
```

The inline default is not optional politeness — it's the repo's documented migration rule, and `Hike.autoSavedTileKeys` carries the comment explaining what breaks without it ("missing attribute values on mandatory destination attribute" for anyone with existing hikes).

Storing both roughly doubles a recorded hike's row (≈ 400 KB for a long day). If that proves too heavy, archive the journal file instead and reference it by session ID — but do not simply discard it.

**Phase 1 leaves it empty, deliberately.** Until a matcher exists, `route` *is* the raw trace, so filling `rawRoute` with a second identical copy pays the whole doubling for no information at all. An empty `rawRoute` therefore reads as "this route has never been moved"; the first phase that moves one fills it in. The field ships now because adding it later is a migration, and adding it now is a default.

---

## 9. Trail alignment

Two problems, often conflated:

- **Snapping** — dense, noisy fixes onto known geometry. Cosmetic and metric: it removes multipath zigzag and stops the distance readout from inflating.
- **Gap inference** — a fix at the trailhead and another 800 m away twelve minutes later. Which way did they go? This is the interesting one, and it's what Tier C/D data reduces to.

### 9.1 Phasing

| Phase | Matching against | Needs network | Value |
|---|---|---|---|
| 1 | nothing — raw filtered trace | no | Ships the feature |
| 2 | an OSM trail graph, HMM matching | prefetch only | **In progress:** save-time matching is wired; live matching and review remain |
| 3 | widget sampling + hardened recovery | no | Rescues Tier C/D sessions |

Matching against the user's own saved hikes was considered and cut: the app is either recording a new hike or following an imported one — there is no in-between state for a matcher to serve.

### 9.2 The trail graph

Build a routable graph from OSM ways in a corridor around the recording:

- Ways where `highway ∈ {path, footway, track, bridleway, steps, cycleway}`, plus `via_ferrata`.
- Keep `name`, `sac_scale`, `trail_visibility`, `access`, `surface`. `name` is what the "Following:" line shows; the rest can weight plausibility later.
- Fetch `route=hiking` relations too, so a matched way can carry a named long-distance route rather than an anonymous `footway`.
- Nodes shared between ways become graph junctions; that adjacency *is* the "which way did they go" question.

Corridor selection must reuse `TileBoundingBox`'s antimeridian-safe wrapping, not a naïve `min`/`max` on longitude. `TileCorridor`'s header comment records exactly what a plain longitude interval does to a trail near ±180°: a corridor spanning the globe. `Fixture.antimeridianRoute` exists to test it.

Cache the graph on disk under Application Support, keyed by a low-zoom tile index, with the same tier discipline (and trim policy) as `TileCache`. Prefetch at Start for a generous box around the first fix; extend opportunistically as the walk leaves it. The graph must be usable offline, because that's when hiking happens.

### 9.3 Where the geometry comes from

| Service | Provides | Limits | Offline | Verdict |
|---|---|---|---|---|
| **Overpass API** (public instances) | Raw OSM ways/relations in a bbox | Free, strict fair-use, no SLA, 429s under load; identify with a real `User-Agent` | Via your own cache | **Recommended source.** Prefetch + cache aggressively. |
| Self-hosted Overpass, or prebuilt graphs from Geofabrik extracts | Same, reliably | Server cost, or a build pipeline and shipped/downloaded regional graphs | Yes | Best long-term for a local-first app |
| **Valhalla / Meili** (self-hosted, or **Stadia Maps**) | `trace_route` / `trace_attributes` — real map matching, pedestrian profile, sparse-trace support | Stadia key mechanism *already exists* in this app (`Secrets.plist` → `StadiaAPIKey`); free tier limited. Verify current endpoint paths against provider docs. | No | **Recommended opt-in** online path |
| GraphHopper Map Matching | Matching, foot profile; open source | API credits, or a heavy self-host | Self-host only | Good alternative to Valhalla |
| Mapbox Map Matching | Matching, walking profile | 100 coordinates per request — a 3,000-point trace means chunking and stitching; paid | No | Awkward for this shape of data |
| OSRM `/match` | Matching | Public demo server is car-profile only | Self-host | Not viable without your own foot-profile server |
| MapKit | — | No public map-matching or trail-network API. `MKDirections` walking gives *a* route between points, not a match to one taken. | — | Not applicable |

**Recommendation: Overpass for geometry, matching on-device.** Three reasons, in order of weight:

1. `README.md` says OpenTrails is local-first with no backend. Uploading a user's GPS trace to a third party is a material change to that promise. It should be a switch the user flips, worded plainly, defaulting off.
2. It works offline. A hosted matcher is useless in the valley where the recording happened.
3. The hard geometry already lives here — haversine, local-tangent projection, segment projection with tie-breaking, antimeridian handling. The matcher is a Viterbi loop on top of code that exists.

Offer Stadia/Valhalla `trace_route` as **"Improve accuracy online"** in Settings, available only when a Stadia key is present, and only ever run after a recording ends — never mid-hike.

Respect Overpass's usage policy the way `TileProvider.supportsBulkDownload` respects tile policy: one bounded prefetch per session, cached, with backoff on 429, and a `User-Agent` identifying the app.

### 9.4 The matcher

Hidden Markov Model map matching, per Newson & Krumm (2009), *Hidden Markov Map Matching Through Noise and Sparseness* — which is the canonical treatment of exactly the sparse-trace case this feature has.

**States.** For each accepted fix, every graph edge within `r = max(50 m, 3σ)` where `σ` is the fix's own `horizontalAccuracy`. The projection onto the edge (edge id + offset along it) is the candidate state.

**Emission.** `p(z | s) ∝ exp(−d_perp² / 2σ²)`. The paper uses a fixed σ ≈ 4 m; using each fix's reported accuracy is better here, because consumer traces swing between 5 m in the open and 50 m under canopy, and the model should trust them differently.

**Transition.** `p(sₜ | sₜ₋₁) ∝ exp(−|d_route − d_great_circle| / β)`, where `d_route` is the shortest path between the two candidates on the graph. β ≈ 5–10 m for dense fixes; widen it with the time gap. Cap the Dijkstra/A* search by `Δt × maxSpeed` so impossible legs bail early instead of exploring the county.

**Decoding.** Viterbi forward; backtrack at the end. To show a matched line *during* recording, run it over a sliding window (~60 s / 20 fixes): points older than the window are committed, the tail stays provisional and may be revised. Committed geometry never moves under the user's eye.

**Gap inference — the part the user actually asked for.** When Δt is large (> 90 s) or Δd > 200 m, the emission terms are nearly uninformative and the transition term *is* the answer: among all paths through the trail network between two known points, prefer the one whose length best matches the distance actually travelled. Two extra constraints make this much sharper than shortest-path guessing:

- **Pedometer.** `CMPedometer.queryPedometerData(from:to:)` returns distance walked over a past window, from the motion coprocessor, with no GPS involved and no battery cost — and iOS keeps roughly seven days of history, so it can be queried retroactively for a gap that has already happened. A path 400 m long is implausible when the pedometer says the walker covered 1.2 km. This turns "which of these three trails" into a measurement rather than a guess, and it is the single highest-value addition to sparse-gap matching.
- **Speed plausibility.** Reject candidate paths implying a sustained pace above ~2.5 m/s on foot, allowing for the possibility of a lift or a vehicle only if `CMMotionActivity` says so.

### 9.5 Confidence, and refusing to guess

A matcher that is confidently wrong is worse than one that abstains, because the wrong answer is written into the saved hike.

- Per-gap confidence = ratio of the best path's likelihood to the runner-up's. Below a threshold (say the top two are within 15% in both length and likelihood), mark the gap **ambiguous**.
- An ambiguous gap falls back to the raw interpolated trace, drawn distinctly, and is *not* attributed to a named trail.
- Where no trail lies within the search radius at all — bushwhacking, beach, ski touring, a path OSM doesn't have — keep the raw trace. Never force a match. A global **Snap to trails** toggle turns matching off entirely for people who mostly walk off-trail.

**Post-recording review (worth building).** If a saved recording has ambiguous gaps, offer a review step: the map highlights option A and option B between the two known fixes, with "Which way did you go?" and a third choice, "Use GPS only". The user knows the answer, they were there, and asking once beats guessing wrong permanently. This is the cleanest resolution to the sparse-data problem in the whole design.

---

## 10. Widget-assisted sampling

Implemented in Phase 3, within the limits below.

**What a widget can do.** A WidgetKit extension can use `CLLocationManager` and `requestLocation()`; access derives from the containing app's authorization, and is broader with Always than with When In Use.

**What it can't.** Timeline refreshes are budgeted and system-paced — on the order of a few dozen a day for a widget on an active Home Screen page, with no guarantee and no way to request more. Realistically that's one sample every 15–60 minutes, only while the widget is actually installed and the page is visited. It is not a recording feed and cannot be made into one.

**So use it as what it is: a gap-filler for Tier C/D.** Each widget-sourced fix is one more anchor for §9.4's inference — and one anchor every 20 minutes turns an unknowable four-hour gap into a chain of solvable 20-minute ones.

### 10.1 Mechanics

- The widget writes to its **own** file in the App Group — `pending-fixes.json`, atomic write, capped at ~200 entries. It must never append to the journal: two processes writing one file with no locking is corruption waiting for a coincidence.
- The app folds pending fixes into the journal at the next foreground or the next accepted fix, deduplicating by timestamp (a widget fix and a Tier A/B fix seconds apart are the same moment), then clears the file.
- Widget-sourced points carry a flag bit in the journal record, so the matcher can weight them differently — they are typically much less accurate than a foreground fix.

### 10.2 What the widget shows while recording

Extend the shared payload rather than reinterpreting the existing one. `SharedTrailSnapshot` is a stable cross-target contract read by a shipped extension; the repo's convention is to keep such contracts stable and update all consumers together. Add a sibling file and type — `SharedRecordingSnapshot` (`sessionID`, `startedAt`, `distanceMeters`, `pointCount`, decimated `polyline`) — written by `HikeRecorder` through `SharedStore`, and let the widget prefer it when present. On Stop, clear it and publish the new hike's trail snapshot the usual way, so the widget lands on the freshly recorded hike.

Deep links: a widget tap while a recording is live opens the recording view, not a hike (`TrailWidgetDeepLink` gains a recording case).

---

## 11. Settings

New section, below Background Trail Tracking:

| Setting | Default | Notes |
|---|---|---|
| Recording accuracy | High | High (`BestForNavigation`) / Balanced (`Best`, 10 m filter) / Battery Saver (100 m desired accuracy, system-paced significant-change delivery) |
| Snap to trails | On | Off preserves the raw trace verbatim |
| Improve accuracy online | **Off** | Only selectable with a Stadia key; states plainly that the trace is sent to Stadia Maps |
| Keep raw GPS track | On | Off halves recorded-hike storage, at the cost of re-matching |

New `SettingsKey` entries follow the existing naming (`settings.recordingAccuracy`, …). Keys are persisted identifiers — the repo's rule is that they stay stable once shipped.

---

## 12. Performance budget

Targets, all measurable, all worth a test:

| Path | Budget |
|---|---|
| Main-thread work per accepted fix | < 1 ms |
| Map overlay update | ≤ 1 Hz, O(tail) — independent of hike length |
| SwiftData writes during a session | **zero** |
| Journal append | 44 B/point, batched, off-main |
| Resident memory for the live track | O(points) in coordinates, and only that — committed chunks stay in `RecordingTrace` so a rebuilt `MapCoordinator` can redraw them, but nothing derived from them is retained. ~64 KB for a five-hour hike. |
| `RecordingView.body` invalidations | Only on phase change — not per fix. Pinned by `RecordingIsolationTests.steadyRecordingDoesNotInvalidatePhaseReaders`, so it fails rather than merely getting slower. |
| Battery, High accuracy | ≤ ~10%/hour on a modern iPhone with the screen off |

`RENDER_SIGNPOST_LOG=1` in the scheme, and compare `RecordingBody` against `LiveFixAccepted`. If they fire at the same rate, isolation is broken.

---

## 13. Edge cases

### Permissions and system state

| Case | Behavior |
|---|---|
| Authorization revoked mid-recording | Pause, banner with a Settings link, keep everything journaled. Do not discard. |
| Reduced accuracy granted | Refuse to start; explain (§5.2). |
| Background mode denied / Background App Refresh off | Start anyway, warn that backgrounding will degrade to Tier C. `SettingsView` already checks `backgroundRefreshStatus` — reuse the pattern. |
| Low Power Mode | `isLowPowerModeEnabled` reduces delivery. Detect it, warn once, keep recording. |
| User force-quits the app | iOS does not relaunch for continuous background updates after a force quit. The session ends; recover the journal on next launch (§7.2). |
| Jetsam kill | The app *is* relaunched for location. `HikeRecorder` reconstructs from the sidecar in `init()` and keeps going. |
| Storage full | Journal write fails → surface it immediately and pause. Silent data loss is the one unacceptable failure here. |

### Signal and geometry

| Case | Behavior |
|---|---|
| No lock at Start (indoors, car park) | `waitingForFix`; don't start the distance clock on a cell-tower fix. |
| First fix is a stale cached one | Rejected by `LocationFixPolicy.accepts` on age. |
| Canyon / dense canopy multipath | Accuracy gate rejects; the matcher interpolates along the trail rather than drawing the zigzag. |
| Tunnel, no fix for minutes | A gap. §9.4 handles it; the pedometer bounds it. |
| Antimeridian crossing | `RouteGeometry` already normalizes longitude deltas. The graph corridor must too — use `TileBoundingBox`, not `min`/`max`. |
| Beyond ±85.05° latitude | Rejected at the door, as `GPXImport.point` does. |
| Loop closing on itself; out-and-back | The known-hard case. HMM transitions handle it where `nearestPoint`'s tie-break can't; `Fixture.loopRoute` and `Fixture.outAndBackRoute` exist for exactly this. |
| Off-trail walking | No match within radius → keep raw, don't force (§9.5). |
| Trail missing from OSM | Same. |
| Ski lift, gondola, shuttle bus | Speed gate flags it; `CMMotionActivity` can corroborate. Mark the segment rather than deleting it. **Phase 1 rejects instead:** without a way to mark a segment there is nowhere to put the distinction, and a lift whose receiver reports its real speed is accepted anyway (the gate only fires when the reported speed disagrees). Marking arrives with matching. |

### Time and data

| Case | Behavior |
|---|---|
| Out-of-order or duplicate timestamps | Sort and dedupe when preparing at Stop; the journal stays append-order. |
| System clock jump (NTP, DST, manual change) | Durations from `ProcessInfo.systemUptime` (monotonic); stored point times from `location.timestamp`. |
| Recording across midnight, or multi-day | Supported. `Hike.date` is the start. Journal size is not a concern (§7.1). |
| Zero- or one-point session | Refuse to save; `tooShort` wording. |
| Pause / resume | v1: pause stops distance accumulation and journals a marker; the saved route stays one continuous segment. This is a real tension with `GPXImport`'s stated assumption ("we don't need to support paused recordings" — multi-segment files are flattened). If pause ever needs to produce a genuine break in the line, both sides change together. |
| Auto-pause | Off, and `pausesLocationUpdatesAutomatically = false`. Losing the second half of a hike to a rest stop is unacceptable. |
| Two recordings at once | Impossible by construction: the button becomes Stop. |

### UI

| Case | Behavior |
|---|---|
| Navigating away mid-recording | Recording continues; the hikes-list pill (§2.1) is the way back. |
| Hike deleted while recording | Unrelated — the recording isn't a `Hike` yet. `MapSheet.delete` must not touch a `.recording` path entry. |
| Widget tap while recording | Pushes the hike *on top of* the recording; the recording stays in the stack. |
| Sheet dragged to compact | Allowed. The map is the point. |
| macOS / visionOS | No background location, no pedometer. Guard with `#if os(iOS)` and keep the recorder foreground-only elsewhere — cross-platform compilation is a repo rule, and the record button should simply not appear where it can't work. |
| VoiceOver | Announce phase changes politely (`.announcement`), not per-fix. Stat tiles get combined labels, as `TrailProgressView` does. |

---

## 14. Testing

Follows the repo's existing seams — everything that matters is injectable, and no suite touches process-global state.

**Seams**

```swift
@MainActor
protocol RecordingLocationSource: AnyObject {     // mirrors SignificantLocationMonitor
    var isAuthorized: Bool { get }
    var hasFullAccuracy: Bool { get }
    var sourceDelegate: CLLocationManagerDelegate? { get set }
    func startRecordingUpdates()
    func stopRecordingUpdates()
}
```

Plus an injected `clock: @Sendable () -> Date` (use `TestClock`), an injected journal directory, and a `RecordingSandbox` owning its own directory — the same shape as `TileSandbox`, and for the same reason: suites run in parallel and must not share a journal.

**Suites worth writing**

| Suite | Asserts |
|---|---|
| `RecordingFixPolicyTests` | Every gate in §6.1, pure, no I/O |
| `StationaryDriftTests` | Ten minutes of jitter at one spot adds < 5 m |
| `TrackJournalTests` | Round-trip; torn-tail recovery; point count from file size |
| `RecordingRecoveryTests` | Open sidecar → resume vs. offer-to-save; **no** auto-resume under `isHostingTests` |
| `TrailMatcherTests` | Dense snapping, antimeridian projection, and a synthesized 12-minute fork that resolves with pedometer distance and stays raw without it |
| `OverpassTrailGraphProviderTests` | OSM way/relation decoding, identifying bounded request, durable cache reuse |
| `RecordingWorkloadTests` | Journal writes and matching run off-main (`assertOffMainThread`), in the spirit of `ImportWorkloadTests` |
| `RecordingRenderIsolationTests` | A fix updates `RecordingStats`/`RecordingTrace` without invalidating `RecordingView.body`, in the spirit of `RenderIsolationTests` |

**Replay.** A `ReplayLocationSource` that plays a GPX through the delegate at controllable rates is the highest-value test tool here: one fixture, replayed at 1 Hz and again at one fix per 15 minutes, exercises Tier A and Tier C against the same ground truth. `SimulatedLocations/ThumseeLoopFast.gpx` is already in the repo, and `simctl location … start` drives the Simulator end-to-end.

**Verification.** `xcodebuild` will relaunch a crashed test host and still print a green summary — and a feature that runs Core Location inside the host app is exactly the kind that crashes it. Check the exit code and grep the log for `Restarting after unexpected exit`; a green summary alone is not a pass.

---

## 15. Milestones

| Phase | Deliverable | Depends on |
|---|---|---|
| **1** | Button, `SheetRoute`, recording view, `HikeRecorder`, feed Tiers A+B, filtering, journal, crash recovery, save. No matching. | — |
| **2** | Overpass prefetch, trail graph, on-device HMM, pedometer-constrained gap inference, confidence + post-recording review. | 1 |
| **3** | Widget sampling, `SharedRecordingSnapshot`, recording deep link, Settings. | 1, 2 |

Phase 1 is a complete, shippable feature on its own — it records hikes. Everything after it is accuracy.

---

## 16. Open questions

1. **Canonical geometry.** Matched route in `Hike.route` with the raw trace beside it (this doc's assumption), or raw as canonical with the match as a display layer? The first is simpler for every existing consumer; the second is more honest about provenance.
2. **Pause semantics.** Does a pause need to produce a real break in the drawn line? If yes, `GPXImport`'s flattening assumption and the single-segment model both change.
3. **Shipped trail graphs.** Is downloading prebuilt regional graphs (Geofabrik-derived) worth the pipeline, versus Overpass-on-demand with a local cache? It's the difference between "works offline where you've been" and "works offline where you're going".
4. **Widget takeover.** Should a live recording displace the selected hike on the widget, or should the widget keep showing the trail and add a small recording badge?
5. **Battery profile default.** High accuracy is the right default for a hiking app, but a 10%/hour drain over a six-hour hike is a real cost. Is Balanced the better default, with High as an explicit choice?
