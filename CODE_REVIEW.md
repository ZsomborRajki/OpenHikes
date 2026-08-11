# OpenTrails Code Review

Reviewed 2026-08-11 at commit `2ee19ea` (`main`). Themes: stability, defects, missing tests, UI performance.

## Executive summary

The app is in good shape structurally. The render-isolation architecture is real and holds where it's claimed, the off-main split in the tile pipeline is deliberate and asserted, and the algorithmic and offline-storage suites are unusually thorough. Nothing here is a crash or data-loss bug.

What this pass found is a consistent pattern rather than scattered defects: **the work the architecture pushed off the main thread is the work that was expensive in aggregate — per-tile, per-frame. The work still on it is expensive per-event, and it's proportional to the size of the imported GPX.** Importing a five-hour recording blocks the main thread for 60 ms; selecting it blocks for another 8–11 ms; the once-a-second auto-follow poll spends 4 ms there. None of that shows up on the six-point fixtures the suite is built from.

The second pattern is **unbounded repetition of a metered operation**: two throttles have escape hatches with no floor under them, so a walker hovering at a threshold can spend a WeatherKit call and a WidgetKit timeline reload every second, indefinitely.

The open items are pinned by tests using `withKnownIssue`, so the suite stays green and each one fails loudly the day it's fixed (prompting removal of the wrapper). The finding sections below name the test that pins each.

## Current build and test state

| Surface | Result | Notes |
|---|---:|---|
| iOS app build | Pass | `OpenTrails`, iPhone 17 Pro simulator |
| iOS app tests | Pass | **294 tests, 33 suites**, 6 known issues |
| Shared package tests | Pass | 42 tests, 5 suites |
| macOS build | Pass | Unsigned, arm64 |
| visionOS build | **Not verified** | No visionOS runtime installed on this machine |
| iPadOS | **Not verified** | No iPad simulator installed |
| CI | **Absent** | `.github/workflows` does not exist |

## Stability and correctness

## UI performance

Every item here runs on the main actor, and every one is proportional to the imported route's point count. Measurements are from the iPhone 17 Pro simulator on this machine, at 18,000 points — one point per second for five hours, the size of recording the app is explicitly built to import.

| Path | Cost | Where |
|---|---:|---|
| `GPXImport.load` | **60 ms** | `ContentView.importGPX`, synchronous |
| `Track.distanceMeters` | 5 ms **per read** | same, computed property |
| `hikeSelectionChanged` | 8–11 ms | `BackgroundTrailTracker`, on every selection tap |
| `RouteProfile(route:)` | 7 ms | built 2× per background fix |
| `nearestPoint(near:)` | 4.4 ms | once a second while auto-following |
| `nearestPoint` (no reference) | 2.9 ms | — the 1.5 ms difference is the candidate array |

### 7. GPX import blocks the main thread

`ContentView.importGPX(from:)` is `@MainActor` and does all of it before returning: security-scoped access, an XML parse of the whole document, an O(n) distance sum allocating two `CLLocation`s per point, a full re-map into `RouteCoordinate`, and a SwiftData insert. 60 ms is four dropped frames, spent while the document picker is dismissing — already the busiest moment for SwiftUI — and a 100,000-point multi-day export is within an order of magnitude of iOS's own watchdog threshold.

The fix is structural, not clever: `GPXImport` is already `nonisolated` and takes a `URL`, so the parse belongs in a detached task with only the `Hike` construction and insert hopping back.

While there, make `distanceMeters` stored rather than computed — it's an O(n) pass with two heap allocations per point on every access, and `coordinates` beside it has the same shape.

**Tests:** `importing a long recording doesn't block the main thread`, `the imported track's derived length is cheap to ask for twice`, `a long import still produces a usable route`.

### 8. Selecting a trail spends most of a frame publishing to the widget

`hikeSelectionChanged` does this synchronously on a tap: `RouteProfile(route:)`, then `hike.coordinates` (a second full pass), then `decimate` (a third), then `JSONEncoder`, then an **atomic write into the App Group container** — real disk I/O on the main actor, the exact thing `MainThreadWatchdog` exists to catch.

None of it needs to be there. The only main-actor-bound part is reading the `Hike`, and `TileOwnership` already demonstrates the snapshot-then-hop pattern that would move the rest off.

`updateStoredLiveFix` then compounds it: it rebuilds the snapshot — and with it a second `RouteProfile` — whenever nothing is stored for the hike, discarding the profile its caller is holding. `handleBackgroundFix` makes the waste explicit, building a profile, matching against it, and handing the *hike* to a function that builds another. That's the path a background relaunch takes, where nothing is stored yet.

**Tests:** `selecting a long trail doesn't spend a frame on the main actor`, `publishing a fix doesn't rebuild a route profile the caller already has`.

### 9. Route tint and width are the one hot path still inside SwiftUI

`ContentView.displayedRoute` reads `hike.tint` and `hike.routeWidth` in `ContentView.body` to hand them to the map. Both live on the `@Model` and both are written continuously — a `Slider` drag and a `ColorPicker` drag — so **every drag sample invalidates the root view**, and with it the `.sheet` closure that builds `MapSheet`: `rankedMatchingHikes()` re-runs, the `NavigationStack` rebuilds, and the pushed `HikeDetailView` that owns the slider being dragged is re-evaluated.

`MapView` is `.equatable()`, so the diff stops before MapKit. Nothing stops it before the sheet.

Measured: 9 slider steps → 9 root-view invalidations; 10 colour writes → 10. A real `ColorPicker` drag emits touch samples, not integer steps.

The fix is the pattern the rest of the app already uses: hold the drawn route's appearance in a stable `@Observable` reference type the coordinator observes directly, as `RouteHighlight` does, rather than reading it out of the model in `body`.

**Tests:** `dragging the width slider doesn't invalidate the root view`, `dragging the colour picker doesn't invalidate the root view`, with `a new selection still reaches the map` pinning what must keep working.

### 10. Per-second and per-point costs worth removing

- **`RouteProfile.nearestPoint(near:)` allocates an `n−1` element array** on every call purely so it can make a second pass over the same candidates. Once a second, on the main actor, while auto-follow is on. A second loop over segments would need no allocation at all — 1.5 ms of the 4.4 ms.
- **`RouteProfile.init` allocates two `CLLocation` objects per point** to call `distance(from:)`. 36,000 heap objects for an 18,000-point route, 7 ms. A direct haversine over the coordinates avoids all of it, and this initializer is on the selection path, the background-fix path, and the detail-view path.
- **`MapSheet.body` calls `rankedMatchingHikes()` on every pass**, including the detent changes a sheet drag produces, whenever `searchText` is non-empty.
- **`DisplayedRouteCoordinateCache` has no invalidation.** It's keyed on `hike.id` and never cleared — not on deselection, not on deletion — so it holds the largest route the user ever selected for the lifetime of `ContentView`, which is the lifetime of the app.

## Test gaps

The suite's algorithmic and storage coverage is genuinely strong. What remains is coverage that needs a seam that doesn't exist yet — which is the finding, more than the missing tests themselves.

**Blocked on missing seams (worth building the seam):**

1. **No injectable location, defaults, or clock.** The background-relaunch path — authorization transitions, persisted selection, delegate delivery, off-route clearing, deleted-hike behaviour — is the app's least testable and most failure-prone surface.
2. **MapKit integration is uncovered.** `MapCoordinator` registration, route-overlay churn, recentering, sheet insets, and highlight updates are verified by `RenderSignpost` in Instruments rather than by tests.
3. **The widget has no test target.** `TrailWidgetProvider`'s timeline, families, empty state, basemap pairing, and clears are untested; only the shared payload underneath them is covered.

**Structural problems in the suite itself:**

4. **Suites share process-global singletons and the real application directories, and nothing enforces it.** `TileCache` now takes a `storageRoot`, so a suite *can* have directories of its own — `TileTransportTests` does — but every other tile suite still goes through `TileCache.shared` and the real `Caches`/`Application Support` pair, and `AutoSaveTileStore.shared` still has exactly one active hike with no seam at all. Swift Testing runs top-level suites in parallel, so the only thing keeping those apart is that the affected suites are hand-nested inside `AutoSaveTests` to inherit its `.serialized` trait.

   This bit during this review: two new suites written as top-level suites corrupted `AutoSaveTileTests` and `StorageAccountingTests` nondeterministically until they were nested too. A convention that must be rediscovered by breaking it is not a convention. Inject the cache root and the store instance, or make the nesting requirement impossible to miss.
5. **Conditional suites can vanish silently.** `WidgetFeedTests` and `WidgetFeedBudgetTests` disable entirely without the App Group container; several tile tests are gated on live `NWPathMonitor` state. A run that skips them looks identical to a run that passes them.
6. **Fixed sleeps remain** in the download and location suites, and randomized tests are unseeded, so a Mercator or route-appearance failure can't be reproduced exactly.
7. **No disk-persistence or migration test for `Hike`.** Every fixture is in-memory, so the lightweight-migration defaults that `Hike`'s comments call out as load-bearing are never exercised against a real store.

## Repository hygiene

- **No CI.** `.github/workflows` does not exist. The passing state above is local and unprotected on pull requests; cross-platform compile failures have reached `main` before. Add compile gates for iOS, macOS, and visionOS plus both test suites, and report skipped conditional suites explicitly rather than letting them pass silently.
- **Two user-specific Xcode files are still tracked** despite `.gitignore` covering `xcuserdata`:
  - `OpenTrails.xcodeproj/project.xcworkspace/xcuserdata/zsomborrajki.xcuserdatad/UserInterfaceState.xcuserstate`
  - `OpenTrails.xcodeproj/xcuserdata/zsomborrajki.xcuserdatad/xcschemes/xcschememanagement.plist`
- **README is out of date on its own claims.** It cites 213 app tests (now 243); it says "Six UI-performance items remain open — ... All are measured in `CODE_REVIEW.md`" and "`CODE_REVIEW.md` records what they were", neither of which was true of the document this replaces. Point it at the sections above.
- **No localization catalog.** All user-facing strings are in source — fine for a single-language prototype, a product-readiness task before localization.

## TODO

Ordered by value per unit of risk. A ✅ test name is the test that already pins the item — it is wrapped in
`withKnownIssue`, so fixing the code makes it fail with "known issue was not recorded", and the fix is
finished when the wrapper comes off. Items with no test named need a seam built first.

### Now — user-visible breakage

- [ ] **Parse GPX off the main actor** (finding 7). `GPXImport` is already `nonisolated`; move the parse into a
      detached task and hop back only for the `Hike` construction and insert.
      ✅ `importing a long recording doesn't block the main thread`
- [ ] **Store `Track.distanceMeters` instead of computing it** (finding 7).
      ✅ `the imported track's derived length is cheap to ask for twice`

### Next — correctness and waste


### Then — main-actor cost

- [ ] **Move the widget publish off the main actor** (finding 8). Snapshot the `Hike` on-main, do the profile,
      decimation, encoding and App Group write off it — the `TileOwnership` pattern.
      ✅ `selecting a long trail doesn't spend a frame on the main actor`
- [ ] **Pass the caller's `RouteProfile` into `updateStoredLiveFix`** (finding 8).
      ✅ `publishing a fix doesn't rebuild a route profile the caller already has`
- [ ] **Move route tint and width out of `ContentView.body`** (finding 9) into a stable `@Observable` the
      coordinator observes directly, as `RouteHighlight` does.
      ✅ `dragging the width slider doesn't invalidate the root view`, `dragging the colour picker doesn't invalidate the root view`
- [ ] **Drop the candidate array in `nearestPoint(near:)`** (finding 10) — a second pass over segments needs no allocation.
- [ ] **Replace `CLLocation`-per-point with a direct haversine in `RouteProfile.init`** (finding 10).
- [ ] **Memoize or gate `rankedMatchingHikes()`** so a sheet drag doesn't re-rank (finding 10).
- [ ] **Invalidate `DisplayedRouteCoordinateCache` on deselection and deletion** (finding 10).

### Infrastructure — unblocks everything above

- [ ] **Add CI** (hygiene): compile gates for iOS, macOS and visionOS, both test suites, and an explicit
      report of which conditional suites were skipped.
- [ ] **Inject location, `UserDefaults` and a clock into `BackgroundTrailTracker`** (test gap 1) — the
      background-relaunch path is the least tested and most failure-prone surface in the app.
- [ ] **Move the remaining tile suites onto their own `storageRoot`, and give `AutoSaveTileStore` the same
      seam** (test gap 4). Until then, any new suite touching `TileCache.shared` or auto-save *must* be nested
      inside `AutoSaveTests` to inherit `.serialized`, or it will corrupt unrelated suites nondeterministically.
- [ ] **Add a widget test target** (test gap 3): timeline, families, empty state, basemap pairing, clears.
- [ ] **Add `MapCoordinator` integration tests** (test gap 2).
- [ ] **Fail, don't skip, when a conditional suite's precondition is missing in CI** (test gap 5).
- [ ] **Seed the randomized tests; replace fixed sleeps with injected clocks** (test gap 6).
- [ ] **Add a disk-backed `Hike` persistence/migration test** (test gap 7).
- [ ] **Untrack the two `xcuserdata` files** and correct README's test counts and its references to items this
      document no longer contains (hygiene).
