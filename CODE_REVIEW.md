# OpenTrails Code Review

Reviewed 2026-08-11 at commit `773a253` (`main`, aligned with `origin/main`).

## Executive summary

The iOS application is in a strong state for a young, multi-target SwiftUI project. Its algorithmic and offline-storage tests are unusually thorough, the main-thread/off-main split is deliberate, and render isolation is well designed. The app suite passes **209 tests in 24 suites**. The shared package passed **42 tests in 5 suites**, and iOS, macOS, and visionOS compile cleanly.

There are no confirmed critical or high-priority defects. The remaining findings are medium-priority correctness, lifecycle, performance, and release-engineering risks.

## Current build and test state

| Surface | Result | Notes |
|---|---:|---|
| iOS app build | Pass | `OpenTrails`, iPhone 17 Pro simulator, iOS 26.5 |
| iOS app tests | Pass | 209 tests, 24 suites |
| Shared package tests | Pass | 42 tests, 5 suites |
| macOS build | Pass | Platform-specific authorization handling; iOS extensions excluded from embedding |
| visionOS build | Pass | visionOS authorization and material fallbacks compile with the 26.5 simulator SDK |
| CI | **Absent** | No workflow exists under `.github/workflows` |

## Medium-priority correctness and lifecycle findings

### 1. GPX segment boundaries become fictitious route legs

**File:** `OpenTrails/Managers/GPXImport.swift:28-42,101-109`

All tracks and segments are flattened into one point array, and distance is summed across every adjacent point. Separate GPX segments commonly represent pauses, transport, GPS loss, or disconnected trail sections.

**Impact:** Imports can gain artificial straight-line legs that inflate distance and distort profiles, matching, rendering, and offline tile bounds.

**Recommendation:** Preserve segment boundaries in the route model, or at minimum exclude cross-segment edges from distance/profile/matching calculations.

### 2. Location fixes are accepted without freshness or accuracy checks

**Files:** `OpenTrails/Managers/LocationManager.swift:54-80`, `OpenTrails/Managers/BackgroundTrailTracker.swift:194-223,258-269`

Core Location can initially deliver cached samples or samples with invalid/poor accuracy. They are immediately used for map centering, weather, route matching, and shared snapshots. Background snapshots stamp `.now` rather than preserving `CLLocation.timestamp`, which makes an old delivered sample appear fresh.

**Recommendation:** Reject negative or excessive `horizontalAccuracy`, reject stale timestamps, and preserve the source timestamp in `SharedTrailSnapshot.LiveFix`.

### 3. Map searches can apply out-of-order responses

**File:** `OpenTrails/UI/Map/MapSheet.swift:355-380`

Each selected suggestion or submitted query starts an uncancelled task. A slower earlier request can finish after a newer request and move the map back to stale user intent.

**Recommendation:** Retain a cancellable search task or generation token and invalidate it whenever a new search starts.

### 4. Weather failures are not retried while stationary

**Files:** `OpenTrails/UI/ContentView.swift:218-229`, `OpenTrails/Managers/WeatherManager.swift:21-27`

`pollWeather()` records the coarse location key before the request. `WeatherManager` swallows errors and returns no success signal. A transient failure therefore suppresses all retries until the user moves roughly one kilometre.

**Recommendation:** Advance the successful key only after a fetch succeeds, and add a bounded retry/freshness policy.

### 5. Offline byte measurements can complete out of order

**File:** `OpenTrails/UI/Hike/HikeDetailView.swift:155-195`

Every manifest change launches an independent detached measurement. Older work can finish last and overwrite a newer byte count; a measurement already in flight can also replace the zero assigned during deletion.

**Recommendation:** Cancel the previous task or use a generation token before publishing `storedBytes`.

### 6. There is no automated build/test workflow

Only local instructions exist; `.github/workflows` is empty. The current suite depends on Xcode 26.5, iOS runtimes, signing capabilities, App Group access, and simulator health.

**Impact:** The passing local state is not protected on pull requests, cross-platform compile failures reached `main`, and entitlement-dependent suites can silently skip.

**Recommendation:** Add CI for the shared package, unsigned platform compilation, and app tests on a controlled simulator. Report skipped conditional suites explicitly.

## Performance backlog

These findings remain valid from the prior measured pass:

1. **Download progress invalidates the whole detail view.** `HikeDetailView.body` reads per-tile `downloader.progress` and `downloader.total`; up to 4,000 progress writes rebuild the header, stats, controls, and metadata. Isolate progress in a small observing child view.
2. **Search ranking is recomputed repeatedly per body pass.** `MapSheet.matchingHikes` performs locale-aware filtering and sorting and is read by both `isSearching` and `suggestionsList`. Compute it once and precompute ranking keys.
3. **`ContentView.displayedRoute` remaps the full route on unrelated state changes.** `hike.coordinates` allocates a new coordinate array before `MapView` equality can stop the diff. Cache by selected hike or map only when the route changes.
4. **Secrets are parsed from disk in render-related paths.** `Secrets.apiKey(for:)` loads and parses a plist on each key-gated provider lookup. Cache the plist once.
5. **Overzoom placeholders are re-cropped on each draw.** `CachingTileOverlayRenderer.fallbackImage` materializes a cropped bitmap for every fallback. Memoize crops or clip and draw the ancestor directly.
6. **Stored-byte accounting re-enumerates and stats the full manifest every two seconds during auto-save.** It is correctly off-main, but competes with tile work. Throttle or update from newly drained deltas.

## Test review

### Strong coverage

- GPX parsing and rejection behavior
- Hike statistics and route appearance
- Route-profile and elevation-chart workloads
- Projection, antimeridian behavior, tile geometry, and provider identity
- Offline enumeration, budgets, cancellation, ownership, and cache accounting
- Auto-save caps, claim rollback, and storage trimming
- Shared snapshot payloads, deep links, basemap geometry, and widget feed generation

The test names and explanatory comments are notably good: they capture user-visible regressions rather than only implementation details.

### Highest-value missing or fragile coverage

1. **No direct widget tests.** Shared payload tests do not exercise timeline providers, families, empty states, basemap pairing, or clears.
2. **The actual background-location relaunch path is untested.** Authorization transitions, persisted selection, delegate delivery, off-route clearing, and deleted-hike behavior need injected location/defaults/clock tests.
3. **MapKit integration is weakly covered.** Render-isolation tests characterize observable controllers but do not verify `MapCoordinator` registration, route-overlay churn, recentering, sheet insets, or highlight updates.
4. **Tile HTTP and renderer behavior lacks a controlled transport.** Status handling, invalid images, headers, cache ordering, expiry/revalidation, reconnect retry, deduplication, and fallback image output are not covered.
5. **SharedStore file behavior is under-tested.** Several tests described as App Group round trips are JSON encode/decode tests rather than real file operations. Add malformed file, wrong hike ID, partial basemap, pruning, and publication-order cases.
6. **Conditional tests can silently disappear.** The entire `WidgetFeedTests` suite is disabled when the App Group container is unavailable, and several tests depend on live `NWPathMonitor` state.
7. **Some concurrency tests use fixed sleeps.** Replace timing assumptions with injected clocks, explicit continuations, or synchronization probes.
8. **Tests share process-global caches and real application directories.** Inject cache roots/instances so unrelated suites cannot influence each other and teardown is guaranteed.
9. **There is no disk persistence or migration test for `Hike`.** In-memory SwiftData fixtures are fast, but they do not validate lightweight migration defaults or stable persisted identifiers.
10. **Randomized tests are not seeded.** Failures in Mercator and route-appearance randomized cases cannot be reproduced exactly.

## Repository hygiene

- `.gitignore` correctly excludes `xcuserdata`, but two user-specific Xcode state files are already tracked:
  - `OpenTrails.xcodeproj/project.xcworkspace/xcuserdata/zsomborrajki.xcuserdatad/UserInterfaceState.xcuserstate`
  - `OpenTrails.xcodeproj/xcuserdata/zsomborrajki.xcuserdatad/xcschemes/xcschememanagement.plist`
- The untracked `.github/copilot-instructions.md` contains useful repository guidance but is not currently part of the committed project state.
- No localization catalog exists; all user-facing strings are currently embedded in source. This is acceptable for a single-language prototype but becomes a product-readiness task before localization.

## Architectural strengths

- `OpenTrailsApp` owns one `ModelContainer` and the long-lived background tracker, which is the right lifetime for background location delivery.
- High-frequency state is isolated in stable observable reference types instead of invalidating parent SwiftUI views.
- `MapCoordinator` uses imperative MapKit updates and Observation tracking rather than rebuilding the map.
- Blocking tile math, disk enumeration, and image work are consistently pushed off the main thread.
- Tile identity includes provider, coordinates, zoom, and display scale.
- Tile files expire after seven days and are removed at launch or rejected lazily before display.
- `TileOwnership` correctly recognizes that multiple hikes can share the same geographic tile.
- Auto-save uses locking, caps, corridor checks, deduplication, and failed-claim rollback.
- Downloader generation tracking prevents an abandoned run from overwriting a newer run.
- Shared snapshots are compact and precomputed; the widget does not duplicate route matching.
- SharedStore uses atomic writes, and basemap publication writes images before advertising the manifest.
- The codebase has strong inline rationale around concurrency, lifecycle, rendering, and policy decisions.

## Recommended order of work

1. Add CI compile gates for iOS, macOS, and visionOS.
2. Add controlled integration seams for location, HTTP, filesystem, and MapKit.
3. Address the measured render/search/storage performance backlog.
