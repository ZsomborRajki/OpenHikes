# Code Review Notes

A point-in-time review of the codebase as of commit `f9d1929` ("feat: auto follow, thunderforest"), 2026-08-10. This is a snapshot, not living documentation — items here may already be stale by the time you read them; check the current code before assuming any of this still applies.

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
