# Code Review Notes

A point-in-time review of the codebase as of commit `f9d1929` ("feat: auto follow, thunderforest"), 2026-08-10. This is a snapshot, not living documentation — items here may already be stale by the time you read them; check the current code before assuming any of this still applies.

> **Later addition:** a UI-performance review as of `446eefa` is appended at the end — see [UI performance review](#ui-performance-review-446eefa). Several items in the original list below have since been fixed in the code (the `OfflineTileDownloader` cancel race now has a generation counter, GPX coordinates are validated through `Mercator.isRepresentable`, the "spring" pin-to-top is gone, and there is now a test target).

## Real bugs / high-confidence issues

### 1. Key-gated tile providers silently break with no bundled `Secrets.plist`, and the "user can enter their own key" path is dead code

`Secrets.swift:14-15` documents:

> "The in-app Settings key (if the user entered one) takes precedence over this."

No such UI exists. `SettingsKey.stadiaAPIKey` / `thunderforestAPIKey` (`TileProvider.swift:97-98`) are never used as actual `UserDefaults`/`@AppStorage` keys anywhere — they only serve as switch-case labels inside `Secrets.apiKey(for:)` (`Secrets.swift:22-28`). `TileProvider.requiresAPIKey` (`TileProvider.swift:28`) is defined but never read anywhere.

**Effect:** picking Stadia Outdoors or Thunderforest Outdoors in Settings without a bundled `Secrets.plist` produces a blank/failed map with zero explanation, and there's no way to fix it in-app.

### 2. `MapSheet.sortedHikes` hardcodes a "spring" keyword pin-to-top

`MapSheet.swift:217-222`:

```swift
private var sortedHikes: [Hike] {
    let keyword = "spring"
    let pinned = hikes.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
    let rest = hikes.filter { !$0.title.localizedCaseInsensitiveContains(keyword) }
    return pinned + rest
}
```

No setting, no UI, no other reference anywhere in the codebase — confirmed via `git log -p` that it's been present unchanged since the search feature was added, with no accompanying explanation. Any hike titled e.g. "Silver Spring Loop" or "Springfield Trail" jumps to the top of the list unexpectedly. Reads like a leftover debug/test artifact rather than an intentional feature.

### 3. Unvalidated GPX coordinates risk a crash

`GPXImport.point(_:)` (`GPXImport.swift:85-92`) only checks that latitude/longitude are *present*, not that they're in a valid range:

```swift
private static func point(_ waypoint: GPXWaypoint) -> Point? {
    guard let lat = waypoint.latitude, let lon = waypoint.longitude else { return nil }
    ...
```

A malformed track point at or near latitude ±90° sends `tan()`/`log()` in `SlippyTileMath.tileY` (`SlippyTileMath.swift:20-23`) toward a very large value; `Int(floor(...))` on a `Double` outside `Int`'s range traps at runtime in Swift. A hostile or corrupted `.gpx` file — arbitrary, untrusted user input via the file importer — can crash the app through this path.

### 4. `OfflineTileDownloader` has a stale-task race on rapid cancel + restart

`cancel()` (`OfflineTileDownloader.swift:67-73`) sets `phase = .idle` but doesn't stop the orphaned `run()` coroutine — its in-flight child fetches (up to 5) keep running in the background. If the user cancels and immediately starts a new download, the old task's tail end still executes:

```swift
phase = Task.isCancelled ? .idle : .finished   // OfflineTileDownloader.swift:118
```

after the new download has already set `phase = .downloading`, clobbering the new download's state back to `.idle` mid-flight.

## Smaller gaps

- **Silent GPX import failure** — `ContentView.importGPX` (`ContentView.swift:150`) just returns on an invalid/empty/single-point file; no alert or error state tells the user their import did nothing.
- **`recordHike()` is a live but unimplemented stub** (`ContentView.swift:142-143`) — the red record button in the hikes list does nothing when tapped, with no disabled state or "Coming soon" affordance (contrast the Apple Sign-In placeholder in `SettingsView.swift`, which *is* visibly disabled).
- **No app-wide offline storage cap** — each hike is capped individually (3,000 auto-saved tiles in `AutoSaveTileStore.swift:36`, ~4,000 bulk-downloaded in `OfflineTileDownloader.swift:40`), but nothing bounds total disk usage across many hikes; Settings only offers a manual "Delete All."
- **Two uncoordinated concurrency caps on the same blocking-I/O pool** — `TileLoadGate` limits on-screen tile loads to 4 concurrent (`CachingTileOverlayRenderer.swift:36`), while `OfflineTileDownloader` independently caps bulk fetches at 5 (`OfflineTileDownloader.swift:41`). Running a bulk download while auto-save is also active — a normal combination for Stadia/Thunderforest — can push up to 9 concurrent blocking disk/network ops through Swift's small cooperative thread pool: the exact scenario `TileLoadGate`'s own comment warns about, just not fully closed off.
- **`OSMTileOverlay.providerID`** (`OSMTileOverlay.swift:17`) is a mutable `var` on a class marked `@unchecked Sendable`. Currently safe because it's set once right after construction and never again, but nothing enforces that — a future change that mutates it post-publication would be a silent data race.
- **No test target** — the `.xcodeproj` has a single app target; none of the tile math, route-profile binary search, or elevation/speed stat calculations have unit tests.

## Note on scope

The durable, scope-level items from this list (unimplemented recording, no in-app key entry, no tests, no global storage cap) are also folded into `README.md`'s **Known Limitations** section, since they're useful context for anyone picking up the project. Everything above is a fix-me list, not a description of intended behavior.

---

# UI performance review (`446eefa`)

A second pass, 2026-08-10, looking only at what the UI does per frame, per keystroke, and per second. Every number below was measured on this machine's iPhone 17 Pro Simulator in a **Debug** build (`-Onone`) via the test target; a Release build on a device will differ in absolute terms, but the ratios and the shapes of the curves are what the items rest on. Where a finding is pinned by a test, the test name is given.

Items 1–4 have failing tests in `OpenTrailsTests`; 5–10 are reasoned from measurements and code reading, because the code involved is `private` inside a `View` and can't be reached from a test without extracting it first.

## 1. The elevation chart plots every track point — at drag frequency

`ElevationChartView.body` emits an `AreaMark` **and** a `LineMark` per elevation sample, both `catmullRom`-interpolated, inside `ForEach(profile.samples)`. `RouteProfile` keeps every point of the imported GPX, so a 1 Hz five-hour recording is 18,000 samples → 36,000 marks. The view is invalidated on every scrub event (drag frequency, via `tracker.trackerDistance`) and once a second by auto-follow.

Rendered at 390×200 pt through `ImageRenderer` (baseline overhead: 0.18 ms):

| samples | render |
|---|---|
| 200 | 19 ms |
| 1,000 | 74 ms |
| 5,000 | 349 ms |
| 20,000 | 1,369 ms |

A frame is 16 ms. Scrubbing a long hike isn't slow, it's stopped — and auto-follow re-pays the same cost every second while the view is open.

**Fix:** downsample for display (min/max per bucket keeps the envelope, and the peaks, which matter — see below), to something on the order of the chart's own pixel width. Roughly 500 points is already past what 390 pt at 3× can resolve.

The chart derives its axes from the plotted samples, so a naïve stride would break two things silently: `elevationDomain` reads `profile.elevationRange` (step over the summit and the drawn line leaves its own chart), and the x-scale is `0...samples.last.distanceMeters` while the live tracker is placed from `profile.distances` (drop the last sample and the walker's position falls off the end). Both are pinned by passing tests so the fix can't quietly regress them.

*Tests:* `a long track's chart stays inside a drawable budget` (failing), plus `the plotted samples still carry the route's high and low points`, `the last plotted sample reaches the end of the route`, `plotted samples ascend by distance`, `every distance along the route still resolves to a plotted sample`, `a short track is plotted in full`.

## 2. `ElevationSample.id` is a fresh UUID per instance

`ForEach` diffs the plotted samples by `id`, so rebuilding a profile for the same route yields entirely new identities and the chart diffs as a wholesale replacement rather than a match. It also isn't free to produce: of the **8.2 ms** it takes to build a 20,000-point `RouteProfile`, **4.6 ms is `UUID()`**. The sample's `distanceMeters` is already unique and stable within a profile.

(`Stat.id` in `HikeStatsViews.swift` has the same shape, but the stats grid is rebuilt once per hike, so it doesn't matter there.)

*Test:* `a sample's identity is stable across rebuilds of the same route` (failing).

## 3. `ElevationChartView.==` compares only counts

```swift
lhs.tint == rhs.tint
    && lhs.profile.samples.count == rhs.profile.samples.count
    && lhs.profile.distances.count == rhs.profile.distances.count
```

Its own comment says the check exists to "catch the parent reconstructing the view with a genuinely different `tint`/`profile`" — comparing lengths doesn't do that. Two different trails with the same number of points are indistinguishable to it, and the chart keeps drawing the old one.

Hard to reach today, since a pushed detail view is torn down per hike. It becomes reachable the moment a profile can change *in place* while its length is briefly unchanged — which is exactly what live recording, the next feature on the list, will do.

*Test:* `equality distinguishes two different trails of the same length` (failing). The deliberate half — that tracker movement reaches the chart through Observation and not through this comparison — is pinned by `equality ignores the tracker, and catches tint and length` (passing).

## 4. A stationary walker republishes their position once a second, forever

`LocationManager.publish` assigns `coordinate` on every accepted fix. Observation *does* filter a write that doesn't change an `Equatable` value — measured: `Double`, `Double?` and `CGFloat` equal-writes notify nobody — but `CLLocationCoordinate2D` is **not** `Equatable`, so an identical position is published as news. Someone standing at a viewpoint therefore wakes `MapView.Coordinator`'s location observation once a second, which re-registers itself through a `Task` hop each time, for as long as the app is open.

Nothing downstream wants the heartbeat: auto-follow and the weather poll both read `coordinate` on their own timers, and the map only uses it to center on the first fix.

**Fix:** compare latitude/longitude before assigning. The same applies to `RouteHighlight.coordinate`, the other coordinate-typed publisher, written at drag frequency.

Worth noting the corollary: the guards this codebase carefully places around `tracker.trackerDistance` / `liveTrackerDistance` (`Double`, `Double?`) are *already* free on this toolchain, and their comments ("reassigning `@Observable` storage to an equal value still triggers dependent views") no longer describe the runtime. The guards that carry weight are the two on coordinates.

*Tests:* `an unchanged fix isn't republished` (failing), `an equal write to an Equatable property notifies nobody`, `an equal write to a coordinate notifies anyway`, `a burst of fixes publishes once`, `a fix that moved is published`.

## 5. The whole hike detail view is rebuilt once per downloaded tile

`HikeDetailView.body` reads `downloader.progress` (through `downloadTile`) and `downloader.total` (through `downloadNote`), so every `completed += 1` invalidates the entire view — header, stats grid, action bar, metadata. A bulk download is up to 4,000 tiles. The elevation chart is spared (it's `.equatable()` and its inputs don't move); nothing else is.

**Fix:** move the progress readout into a small child view that reads `downloader`, the same way `ElevationChartView` isolates `tracker`.

The same shape applies to `hike.autoSavedTileKeys.count`, read from `body` via `autoSaveNote`: every auto-save drain (every 2 s while browsing) rebuilds the whole detail view. `autoSaveNote` also takes `AutoSaveTileStore`'s lock from inside `body`.

*Test:* `progress notifies once per tile` (passing — a characterisation of the publish rate; what should shrink is the body it invalidates, which isn't observable from a unit test).

## 6. Search ranking runs up to four times per keystroke, and scales badly

`MapSheet.matchingHikes` filters with `localizedCaseInsensitiveContains` and then sorts with a comparator that recomputes **two** `range(of:options:[.caseInsensitive, .anchored])` calls per comparison — so O(n log n) locale-aware searches where O(n) would do. Measured at **6.2 ms for 500 hikes**, on the main thread, in a computed property read from `body`.

And it's read repeatedly per body pass: `isSearching` calls it, then `suggestionsList` calls it again for `!matchingHikes.isEmpty`, for the `ForEach`, and for the section header — up to four evaluations, ~25 ms per keystroke at 500 hikes.

**Fix:** compute once into a local, and decorate-sort-undecorate so the prefix flag is computed once per hike instead of once per comparison.

Not testable as it stands (`private` inside a `View`); extracting the ranking into a `nonisolated` helper would make it both testable and cheaper in one move.

## 7. `ContentView.displayedRoute` re-maps the whole route on every body pass

`hike.coordinates` is `route.map(\.clCoordinate)` — measured at **1.33 ms for 20,000 points**, allocating the full array each time. `ContentView.body` builds it on every evaluation, and its body runs on far more than route changes: every keystroke (`searchText` is `@State` here), every sheet detent settle, every navigation push/pop, every weather refresh.

`MapView` is `.equatable()`, so the *diff* stops at the map — but the mapping has already happened by then, since the value must exist before it can be compared.

**Fix:** cache the mapped coordinates per selected hike (`@State` updated on selection), or let `DisplayedRoute` carry the `[RouteCoordinate]` and map once, inside `updateRoute`, where the polyline is actually built.

## 8. `Secrets.apiKey` reads and parses a plist from disk inside `body`

`ContentView.activeTileSource` is computed in `body` and calls `Secrets.apiKey(for:)`, which does `Bundle.main.url(forResource:)` + `NSDictionary(contentsOf:)` every time — **26 µs per call**, on the main thread, per body pass. Keyless providers (OSM, the default) return before touching the disk, so this only bites when Stadia or Thunderforest is selected. Small, but it is main-thread file I/O in a render path, which is the exact category `MainThreadWatchdog` exists to catch. A `static let` cache fixes it.

## 9. Overzoom placeholders are re-cropped on every draw pass

`CachingTileOverlayRenderer.fallbackImage` calls `TileImage.cropped(to:)` for each cache-missed tile — a full off-screen bitmap render, measured at **0.28 ms per tile**, uncached. During a zoom animation with a screen full of missing tiles that's several milliseconds per draw pass, repeated on every pass until the real tiles land.

**Fix:** either memoize the cropped placeholders, or skip materializing them altogether — clip the context to the destination rect and draw the ancestor tile scaled, which is what the crop is emulating.

## 10. `refreshStoredBytes()` re-measures everything every two seconds

`HikeDetailView` re-measures a hike's offline storage on every auto-save drain (`onChange(of: hike.autoSavedTileKeys.count)`). Each pass re-enumerates the tile grid for every download record (~3.8 ms for a 1,800-key record) and then stats two files per key: **126 ms warm for 3,000 keys**, the per-hike auto-save cap.

It's correctly off the main thread, so it costs no frames — but while the user pans around a well-saved hike it is ~130 ms of work every 2 s, on the same small cooperative pool the tile loads use, which is the resource `TileLoadGate` exists to protect.

**Fix:** throttle the re-measure (a saved tile is ~30 KB; the number doesn't need to be live to the byte), or add the delta for newly drained keys instead of recomputing the whole set.

## Measured and dismissed

- **`HikeRow.subtitle`** formats a `Measurement` and a `Date` per row per render: 0.14 ms for 20 rows. Fine.
- **`DirectionalPolylineRenderer.draw`** walks every polyline segment per draw call, but the off-screen skip is closed-form and the per-segment work is a handful of multiplications.
- **`TopEdgeReader`** looks like a per-frame write to `SheetMetrics.topY`, but `onChange` only fires on a changed value, and `CGFloat` is `Equatable` so an equal write wouldn't notify anyway.
- **The 1 Hz polling loops** (`ContentView.pollWeather`, `HikeDetailView.followLocation`) are two permanent timers, but each does almost nothing per tick and both exist specifically to keep `locationManager.coordinate` out of a `body`.
