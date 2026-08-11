# Code Review Notes

**What's left to fix.** A snapshot, not living documentation — check the current code before assuming any of it still applies. Fixed items are dropped rather than annotated; `git log` is the record of what changed.

Last reviewed 2026-08-11, against the working tree on top of `98f2267`. Both suites pass in full: 196 tests in `OpenTrailsTests`, 42 in `OpenTrailsSharedTests`.

Numbering is stable across revisions — 1–7 were the correctness and UX items, and are done.

## Open — UI performance

Measurements are from a pass on this machine's iPhone 17 Pro Simulator in a **Debug** build (`-Onone`); the code they describe is unchanged, so they still stand. All six are `private` inside a `View`, which is why none is pinned by a test — extracting them is part of the fix in each case.

Line references may have drifted by a few lines; the symbol names are current.

### 8. The whole hike detail view is rebuilt once per downloaded tile

`HikeDetailView.body` reads `downloader.progress` (through `downloadTile`, `HikeDetailView.swift:311-316`) and `downloader.total` (through `downloadNote`, `:370-375`), so every `completed += 1` invalidates the entire view — header, stats grid, action bar, metadata. A bulk download is up to 4,000 tiles. The elevation chart is spared (it's `.equatable()`); nothing else is.

The same shape applies to `hike.autoSavedTileKeys.count`, read from `body` via `autoSaveNote` (`:381-385`): every auto-save drain (every 2 s while browsing) rebuilds the whole detail view, and `autoSaveNote` takes `AutoSaveTileStore`'s lock from inside `body`.

**Fix:** move the progress readout into a small child view that reads `downloader`, the same way `ElevationChartView` isolates `tracker`.

*Test:* `progress notifies once per tile` (passing — a characterisation of the publish rate; what should shrink is the body it invalidates, which isn't observable from a unit test).

### 9. Search ranking runs up to four times per keystroke, and scales badly

`MapSheet.matchingHikes` (`MapSheet.swift:51-62`) filters with `localizedCaseInsensitiveContains` and then sorts with a comparator that recomputes **two** `range(of:options:[.caseInsensitive, .anchored])` calls per comparison — O(n log n) locale-aware searches where O(n) would do. Measured at **6.2 ms for 500 hikes**, on the main thread, in a computed property read from `body`.

And it's read repeatedly per body pass: `isSearching` calls it (`:45`), then `suggestionsList` calls it again for `!matchingHikes.isEmpty` (`:292`), for the `ForEach` (`:294`), and for the section header — up to four evaluations, ~25 ms per keystroke at 500 hikes.

**Fix:** compute once into a local, and decorate-sort-undecorate so the prefix flag is computed once per hike instead of once per comparison. Extracting the ranking into a `nonisolated` helper makes it both testable and cheaper in one move.

### 10. `ContentView.displayedRoute` re-maps the whole route on every body pass

`hike.coordinates` is `route.map(\.clCoordinate)` (`Hike+Presentation.swift:41`) — measured at **1.33 ms for 20,000 points**, allocating the full array each time. `ContentView.body` builds it via `displayedRoute` (`ContentView.swift:47-55`) on every evaluation, and that body runs on far more than route changes: every keystroke (`searchText` is `@State` here), every sheet detent settle, every navigation push/pop, every weather refresh.

`MapView` is `.equatable()`, so the *diff* stops at the map — but the mapping has already happened by then, since the value must exist before it can be compared.

**Fix:** cache the mapped coordinates per selected hike (`@State` updated on selection), or let `DisplayedRoute` carry the `[RouteCoordinate]` and map once, inside `updateRoute`, where the polyline is actually built.

### 11. `Secrets.apiKey` reads and parses a plist from disk inside `body`

`ContentView.activeTileSource` is computed in `body` and calls `Secrets.apiKey(for:)` (`ContentView.swift:60`), which does `Bundle.main.url(forResource:)` + `NSDictionary(contentsOf:)` every time (`Secrets.swift:24-32`) — **26 µs per call**, on the main thread, per body pass. `HikeDetailView.swift:411` does the same on the download path. Keyless providers (OSM, the default) return before touching the disk, so this only bites when Stadia or Thunderforest is selected.

Small, but it is main-thread file I/O in a render path, which is the exact category `MainThreadWatchdog` exists to catch. A `static let` cache fixes it.

### 12. Overzoom placeholders are re-cropped on every draw pass

`CachingTileOverlayRenderer.fallbackImage` (`:187-196`) calls `TileImage.cropped(to:)` for each cache-missed tile — a full off-screen bitmap render, measured at **0.28 ms per tile**, uncached. During a zoom animation with a screen full of missing tiles that's several milliseconds per draw pass, repeated on every pass until the real tiles land.

**Fix:** either memoize the cropped placeholders, or skip materializing them altogether — clip the context to the destination rect and draw the ancestor tile scaled, which is what the crop is emulating.

### 13. `refreshStoredBytes()` re-measures everything every two seconds

`HikeDetailView` re-measures a hike's offline storage on every auto-save drain (`onChange(of: hike.autoSavedTileKeys.count)`, `HikeDetailView.swift:143`). Each pass re-enumerates the tile grid for every download record (~3.8 ms for a 1,800-key record) and then stats two files per key: **126 ms warm for 3,000 keys**, the per-hike auto-save cap.

It's correctly off the main thread, so it costs no frames — but while the user pans around a well-saved hike it is ~130 ms of work every 2 s, on the same small cooperative pool the tile loads use, which is the resource `TileLoadGate` exists to protect.

**Fix:** throttle the re-measure (a saved tile is ~30 KB; the number doesn't need to be live to the byte), or add the delta for newly drained keys instead of recomputing the whole set.

## Measured and dismissed

Unchanged from the earlier pass, and re-confirmed against the current code:

- **`HikeRow.subtitle`** formats a `Measurement` and a `Date` per row per render: 0.14 ms for 20 rows. Fine.
- **`DirectionalPolylineRenderer.draw`** walks every polyline segment per draw call, but the off-screen skip is closed-form and the per-segment work is a handful of multiplications.
- **`TopEdgeReader`** looks like a per-frame write to `SheetMetrics.topY`, but `onChange` only fires on a changed value, and `CGFloat` is `Equatable` so an equal write wouldn't notify anyway.
- **The 1 Hz polling loops** (`ContentView.pollWeather`, `HikeDetailView.followLocation`) are two permanent timers, but each does almost nothing per tick and both exist specifically to keep `locationManager.coordinate` out of a `body`.
- **The `Double`-typed Observation guards** (`tracker.trackerDistance`, `liveTrackerDistance`) are free on this toolchain — Observation already filters an equal write to an `Equatable` value. The guards that carry weight are the two on coordinates, which is where they now live.

