# OpenTrails Code Review

Original review: 2026-08-11 at commit `2ee19ea`. Recording review at `d5d0058`. This pass reviewed the working tree at `806c1ae` (`main`), with a focus on UI performance, correctness, optimization, dead code and missing tests.

## Executive summary

The app remains structurally sound, and the render-isolation discipline it is built around is real and largely enforced by tests. The tile pipeline, the background-relaunch path, the recorder and the widget all have injectable seams; the suites own their state; every target that builds, builds; every test that runs, passes.

Nothing found in this pass is a crash or a data-loss defect. What it did find is a set of **second channels** — paths that reach a view, a thread or a race by a route the existing isolation work doesn't cover, precisely because that work closed the obvious route and stopped there:

- `RouteStyle` keeps a colour drag out of `OpenTrailsView.body`, and a test pins it. Nothing pins `MapSheet`, whose `@Query` sees the same write.
- `GPXImport.runOffMain` keeps an 18,000-point parse off the main actor, and a test measures it. Opening that same hike then builds its `RouteProfile` and its ten stat passes on the main actor.
- The test targets build at `SWIFT_STRICT_CONCURRENCY = complete`. The app target and the widget extension — where every `@unchecked Sendable`, every lock and every detached task actually lives — build at `minimal`.

Each is cheap to close, and each is closed the same way the first instance was: name the read, isolate it, and pin it with a test.

## Current build and test state

Measured on this machine at `806c1ae`, Xcode 26.5 / iPhone 17 Pro simulator.

| Surface | Result | Notes |
|---|---:|---|
| iOS app build | Pass | `OpenTrails`, iPhone 17 Pro simulator |
| iOS app + widget tests | Pass | `xcodebuild test` green; **498 `@Test` / 60 suites** declared in `OpenTrailsTests`, **19 / 3** in `OpenWidgetTests` |
| Shared package tests | Pass | **51 tests, 8 suites** |
| UI tests | Pass | **4 XCTest methods**, one of which is the launch-performance metric |
| SwiftLint | Pass | 0 violations |
| macOS build | **Not verified** | Not re-run this pass |
| visionOS build | **Not verified** | No visionOS runtime installed on this machine |
| iPadOS | **Not verified** | No iPad simulator installed |
| CI | **Absent** | `.github/workflows` does not exist |

The counts above supersede the previous pass's (452 / 17 / 49); the suites have grown since.

## UI performance

### `MapSheet`'s `@Query` is a second invalidation channel

`RouteAppearanceIsolationTests` is explicit about the problem it solved: a `ColorPicker` or `Slider` drag used to invalidate `OpenTrailsView.body`, "and with it the `.sheet` closure that builds `MapSheet`". `RouteStyle` closed that route, and two tests hold it closed.

But `MapSheet` also holds `@Query(sort: \Hike.date, order: .reverse) private var hikes: [Hike]`, and `tintHex`/`routeWidth` are persisted attributes of a model that query returns. The drag therefore still reaches the sheet — not through the root view, through the store. What it costs on each sample is the sheet's whole body: the `NavigationStack`, the `navigationDestination` closure, the hikes `List`, and every `HikeRow` in it.

The auto-save drain takes the same path. `hike.autoSavedTileKeys` grows every couple of seconds while the map is panned, and each append is a model change the query observes.

This is a suggestion to *confirm first*: the fix depends on whether SwiftData coalesces those notifications, and that is worth a test before it is worth a redesign.

### `HikeDetailView.body` rebuilds wholesale on both a drag and a drain

The file already isolates four things for exactly this reason — `ElevationChartView` is `.equatable()`, `TrailProgressView`, `OfflineDownloadButton` and `OfflineDownloadStatus` each exist to keep a high-frequency observation out of the parent body. Two readers were left behind:

- `widthSlider` reads `hike.routeWidth` to render `"\(Int(hike.routeWidth)) pt"`.
- `autoSaveNote` reads `hike.autoSavedTileKeys.count` for the idle note, and `storedTilesRow` reads `autoSavedTileKeys.isEmpty`.

Both sit inside `actionBar`, inside the single `body`. So every slider sample and every auto-save drain re-evaluates `header`, `statsGrid`, `metadataSection`, the full `actionBar` and `storedTilesRow` — the same class of waste `OfflineDownloadStatus` was extracted to prevent, one level up.

The remedy matches the file's own precedent: a small view owning the width/colour controls, and another owning the auto-save note.

### Opening a hike does its O(n) work on the main actor

`.task(id: hike.id)` builds `RouteProfile(route: hike.route)` — a haversine per point, three arrays, plus the drawing downsample — and then `Self.makeStats(for: hike)`, both on the main actor, while the navigation push is animating.

`ImportWorkloadTests` already measured and fixed the identical shape of problem one step earlier in the same flow: parsing an 18,000-point GPX cost 60 ms on the main thread, "four dropped frames at 60 Hz", and the fix was structural — `GPXImport` was already `nonisolated`, so the parse moved to a detached task. `RouteProfile` is `nonisolated` and `[RouteCoordinate]` is `Sendable`; the same move applies here with no redesign, and the same test can measure it.

### Two independent 1 Hz timers run for as long as the app is open

`OpenTrailsModel.pollWeather()` loops forever on `Task.sleep(for: .seconds(1))` to compute a ~1.1 km grid key that `WeatherPollState` then throttles anyway. `HikeDetailView.followLocation` runs a second 1 Hz loop for as long as a hike is selected.

`LocationManager` already publishes at most once a second *and* already drops an unchanged fix, so neither loop is buying resolution the source can deliver. Driving both from that publish instead of from a timer would make them stop ticking entirely while the walker is standing still — which is most of a rest stop, and all of the time the phone is in a pocket with the detail view open.

## Correctness

### The app target is the one target not checked for concurrency

| Target | `SWIFT_STRICT_CONCURRENCY` |
|---|---|
| `OpenTrails` | *not set* → `minimal` |
| `OpenWidgetExtension` | *not set* → `minimal` |
| `OpenTrailsTests` | `complete` |
| `OpenTrailsUITests` | `complete` |
| `OpenTrailsShared` | Swift 6 language mode (strictest) |

This is inverted. `OpenTrails` is where `TileCache` is a `@unchecked Sendable` singleton, where `MemoryTile` and `FetchedTile` opt out of checking by hand, where five `OSAllocatedUnfairLock`s guard shared state, and where detached tasks do disk and network work — and it is the target the compiler is checking least. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set, which is what makes most of the app safe by default, but it is exactly the deliberately-`nonisolated` code that most needs the diagnostic.

Turning it on is likely to surface work rather than none. That is the point of doing it deliberately rather than discovering it later.

### `RenderSignpost`'s console counters rely on default isolation

`callCounts` and `lastFireTimes` are `static var` dictionaries mutated from `mark(_:_:)`. Today that is safe — default actor isolation makes `RenderSignpost` main-actor, and every call site is main-actor — but the safety is implicit, it is inherited from a build setting rather than stated in the file, and it is the kind of thing a future `nonisolated` annotation silently breaks. The tile layer's lock pattern already exists in this codebase; this is one of the few places that keeps mutable static state without it.

## Optimizations

### `makeStats` walks the route about ten times

`Hike+Statistics` is written as independent computed properties, and `makeStats` calls nine of them in a row:

- `maxElevation`, `minElevation`, `elevationGain`, `elevationLoss` each rebuild `elevations` from scratch — four full `compactMap` passes and four full arrays.
- `startDate`, `endDate`, `duration` and `averageSpeed` each rebuild `timestamps` — a whole-route allocation to read `.first` or `.last`.
- `maxSpeed` allocates **two `CLLocation` objects per segment** — 36,000 objects for an 18,000-point track — while `RouteGeometry.distanceMeters` exists in this very repo with the doc comment "great-circle distance without allocating Core Location objects per leg".

One pass producing all of it would be cheaper, would allocate almost nothing, and would keep the stats from disagreeing with each other. `HikeStatisticsTests` already covers the behaviour well enough to refactor against.

### `Hike.coordinates` is the route remapped in full

`DisplayedRouteCoordinateCache` exists because this is expensive, and it caches the map's copy. `HikeDetailView.zoomButton`'s download path and `refreshStoredBytes` each remap independently — the latter correctly does so inside its detached task, the former on the main actor at tap time.

## API modernization

A scan for legacy types and superseded APIs found the codebase already clear of the usual suspects: no Combine, no `ObservableObject`/`@Published`/`@StateObject`, no `NSKeyedArchiver`, no `Timer`/`RunLoop`, no `NotificationCenter`. Observation is `@Observable` throughout, ordered background work is `AsyncStream`, and the two `DispatchQueue`s that remain are `Task.detached(executorPreference:)` targets — SE-0417, not GCD holdovers. What the scan did find is a codebase that has adopted every *setting* Swift 6 asks for without adopting the *language mode* or the standard library that comes with it.

### The app still compiles in Swift 5 language mode

All **10** build configurations in `project.pbxproj` carry `SWIFT_VERSION = 5.0`, while the same configurations already set `SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`, against an iOS/macOS/visionOS 26.5 floor. `OpenTrailsShared` is already `swift-tools-version: 6.0` and therefore already builds in Swift 6 mode.

This is the last step of the migration the *Correctness* section above started, and the cheapest one remaining: raising strict concurrency to `complete` was the change that surfaces the real diagnostics, and that has landed. The language-mode flip mostly promotes what are already warnings into errors, which is the point — it is what stops the next regression from being merged as a warning nobody read.

### `OSAllocatedUnfairLock` predates the standard library's own answer

`import Synchronization` appears **zero** times in the repository. The lock pattern the tile layer established — and which the rest of the codebase correctly follows — is `OSAllocatedUnfairLock`, an `os`-framework type from before the standard library had one. `Mutex` requires iOS 18 / macOS 15 / visionOS 2; the app's floor is 26.5, so it is available on every target that ships.

**14** declarations and **49** `withLock` call sites across seven files:

| File | Locks |
|---|---|
| `Tiles/Cache/TileCache.swift` | 4 — `online`, `inFlightFetches`, `mutationVersions`, `observers` |
| `Tiles/Rendering/CachingTileOverlayRenderer.swift` | 3 — `inFlight`, `failures`, `retryWake` |
| `Tiles/AutoSave/AutoSaveTileStore.swift` | 1 — `state` |
| `General/Diagnostics/MainThreadWatchdog.swift` | 2 — `started`, `responded` |
| `Map/Location/BackgroundTrailTracker.swift` | 1 — a generation counter |
| `OpenTrailsTests/General/StubTileProtocol.swift` | 1 — `state` |
| `OpenTrailsTests/General/TestSupport.swift` | 1 — **`NSLock`** |

The migration is worth more than a type swap, because `Mutex` is `Sendable` by construction. Where a class's *only* reason for `@unchecked Sendable` was lock-guarded stored properties, the annotation becomes a plain conformance — a promise the compiler checks instead of one it takes on faith. `AutoSaveTileStore` and the test suite's `TestClock` are both in that position.

The rest are not, and it is worth being precise about why: `TileCache` holds an `NSCache`, `MemoryTile` and `FetchedTile` hold a `TileImage`, and `CachingTileOverlayRenderer`, `TileOverlay` and `StubTileProtocol` all inherit from Objective-C classes the SDK does not declare `Sendable`. No lock migration can fix those, because the lock was never what made them unchecked. They keep the annotation, and their doc comments should say the superclass is the reason rather than leaving a reader to assume the locks were.

Two sites deserve narrower treatment than a mutex:

- **`BackgroundTrailTracker.swift:468`** wraps a bare `UInt64` counter in a lock. `Atomic<UInt64>` from the same module expresses exactly that, without the mutual exclusion the counter never needed.
- **`TestSupport.swift:480`** is the repository's only real `NSLock`, and the only lock not following the pattern every other file follows. It guards a single `Date` behind manual `lock()`/`defer { unlock() }` pairs.

### Smaller items

- **`RenderInstrumentation.swift`** measures elapsed time with four `CFAbsoluteTimeGetCurrent()` calls. `CFAbsoluteTime` is wall-clock: it can jump backwards on an NTP correction and report a negative interval. `ContinuousClock` is monotonic and is what the retry path in `CachingTileOverlayRenderer` already uses.
- **`MainThreadWatchdog.swift`** runs its ping loop on a raw `Thread` with `Thread.sleep` and `DispatchQueue.main.async`, and guards a start flag and a ping flag with two locks. The *flags* should be `Atomic<Bool>` — the start guard in particular is a `compareExchange`, stated as one operation rather than a lock's read-test-write. The `Thread` should stay: a watchdog scheduled on the cooperative pool would be starved by exactly the congestion it exists to report (see this renderer's own note on tile loads jamming that pool) and would time its own delay as the main thread's. The same goes for `DispatchQueue.main.async` over a `@MainActor` hop, which would route the ping through the pool before it ever reached the main queue.
- **`String(format: "%.2f")`** at four sites predates `Duration.formatted(.units(...))` and `.formatted(.number.precision(...))`.
- **`TileCache.swift:294`** holds a lone `DispatchQueue.main.async` in a file that is otherwise structured concurrency throughout.

### Deliberate, and to be left alone

Three findings look legacy and are not. Each is already documented in place, and the scan confirms the reasoning still holds:

- **`CLLocationManagerDelegate` over `CLLocationUpdate.liveUpdates()`** (`LocationManager.swift:7`): the newer async-stream API stalls after the first fix when the Simulator's location is driven by `simctl location … start`, which is how this project's GPX playback works.
- **`NSCache` in `TileCache`**: no Swift-native equivalent offers cost-based eviction. The three sites are already annotated `// swiftlint:disable:next legacy_objc_type`.
- **`@preconcurrency MKLocalSearchCompleterDelegate`** (`SearchCompleter.swift:39`): this *replaced* a hand-written `MainActor.assumeIsolated`. It is the newer form, not the older one.

## Code to remove

- **`violations.txt` (43 KB) is tracked in git.** It is a stale SwiftLint report: it lists errors under rules the current `.swiftlint.yml` no longer trips, and a fresh `swiftlint lint` over the whole project now reports **2** violations, not the hundreds in the file. Delete it and add the pattern to `.gitignore`.
- **The two live lint violations** are both in `OpenTrailsUITests/OpenTrailsUITests.swift`: an `unneeded_throws_rethrows` on `setUpWithError()` and a `balanced_xctest_lifecycle` (a `setUp` with no `tearDown`).
- **`OpenWatch Watch App/` and `OpenWatchWidget/` are empty shells.** Both contain nothing but empty `.xcassets` colorset directories, neither appears anywhere in `OpenTrails.xcodeproj` (`grep -c OpenWatch` → 0), and git tracks no file under either. They are still listed in `.swiftlint.yml`'s `included:`. Remove the directories and the two config entries, or land the watch target they were scaffolded for.

## Test gaps

**Conditional suites can still vanish silently.** `WidgetFeedSuites` and the widget target's `Trail widget` suite disable entirely without the App Group container. Both now report the skip, and strict mode turns it into a failure:

```sh
xcodebuild test … "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) REQUIRE_ALL_SUITES"
```

Nothing passes that yet, because nothing runs the tests except a person. It becomes real coverage the moment CI does.

**The sheet has no isolation test, though the root view has two.** `RouteAppearanceIsolationTests` counts what `OpenTrailsView.body` reads by calling `DisplayedRoute.forSelection` — the real call, deliberately, "so a read added back … fails here rather than passing against a copy". There is no equivalent for what `MapSheet` reads, which is why the `@Query` channel above is a question rather than a known quantity. The same technique applies: an `ObservationCounter` over the sheet's actual read set, asserting a width drag and an `autoSavedTileKeys` append cost it nothing.

**No suite measures the cost of opening a hike.** `ImportWorkloadTests` measures the import; `ElevationChartWorkloadTests` measures the drawn sample budget. Nothing measures the step between them — `RouteProfile` construction plus `makeStats` on an 18,000-point route, which is what actually runs when the detail view appears. `ImportWorkloadTests`'s `ranOnMainThread` probe is the pattern to copy.

**Untested source files.** Every one is small, and most are pure functions, which is what makes their absence worth listing rather than excusing:

| File | What is untested |
|---|---|
| `Map/Search/SearchCompleter.swift` | Debounce and result delivery — `HikeSearch`, its sibling in the same screen, has a full suite |
| `Weather/WeatherManager.swift` | `WeatherPollingTests` covers `WeatherPollState`, not the manager |
| `Map/Rendering/DirectionalPolylineRenderer.swift` | Arrow placement and spacing |
| `Map/Rendering/TrailBasemapRenderer.swift` | App-side rendering (the shared `TrailBasemap` is covered) |
| `Map/TopEdgeReader.swift` | The sheet-top reporting the whole map-button position depends on |
| `General/Diagnostics/MainThreadWatchdog.swift` | Stall detection and the start-once guard |

**UI automation is four tests wide.** It covers launch, GPX import, a simulated-location recording start, and launch performance. The flows most likely to regress silently are not among them: the widget deep link (`openWidgetLink` has branches for a live recording, a pushed hike, and a deleted hike), hike deletion while its detail view is pushed (the `path.removeAll` in `MapSheet.delete` exists specifically for that), and the recording ambiguity review, which is the one screen that gates a SwiftData insert behind user choices.

## Recording: completed implementation

Recording now covers the full reviewed flow: it records hikes, survives a jetsam kill, and saves one `Hike` only after Stop and any required review.

**Live matching uses a bounded provisional window.** `HikeRecorder` continuously runs the HMM matcher over at most 21 points while retaining roughly the latest 20 points / 60 seconds as provisional geometry. Older matched geometry becomes stable, newer fixes remain raw until the next pass, stale tasks cannot overwrite a newer session, and `RecordingStats.matchedTrailName` drives the live "Following:" status.

**Ambiguous legs wait for the hiker.** Sparse-route alternatives remain attached to the exact `TrailMatchResult` shown after Stop. The review presents option A, option B, and GPS for each uncertain leg, highlights that leg distinctly on the map, and does not insert a `Hike` until every choice is resolved. A finished journal survives relaunch until the review is saved or discarded.

**Graph coverage extends with the route.** Prefetching is keyed by exact zoom-12 graph regions, so every newly entered region is requested once rather than only the starting region. Cache readers await an active refresh and use expired data only when that refresh fails.

**Motion activity participates in recording.** An injectable Core Motion source corroborates stationary periods and permits otherwise implausible non-pedestrian movement such as a lift or shuttle. That metadata is persisted on route coordinates and preserved when Stadia returns simplified geometry.

The rest of the recording design remains present and tested: the entry point and `SheetRoute`, the isolated recording UI and chunked map trace, the accuracy-aware fix policy and stationary-drift control, barometric elevation fusion, the fixed-width journal with torn-tail and open-session recovery, one-time save, Overpass fetching with a real `User-Agent` and 429 backoff, pedometer-constrained gap inference, widget anchor sampling, the recording snapshot takeover and deep link, and the four recording settings.

## Repository hygiene

- **No CI.** `.github/workflows` does not exist (the only file under `.github/` is `copilot-instructions.md`). The passing state above is local and unprotected on pull requests; cross-platform compile failures have reached `main` before. Add compile gates for iOS, macOS, and visionOS plus all three test suites and SwiftLint, run them in strict mode (see above) so a suite that can't run fails rather than disappearing.
- **A build artifact is tracked.** `violations.txt`, 43 KB of stale SwiftLint output, is in git and is not in `.gitignore`. See *Code to remove*.
- **Concurrency checking is configured per target, and inconsistently.** See *Correctness*; this belongs in the same commit as the CI work, since CI is what will keep it from drifting back.
- **No localization catalog.** All user-facing strings are in source — fine for a single-language prototype, a product-readiness task before localization.

## Open questions

Carried over from the recording design, and still unanswered. Each one changes code, so none of them should be settled by drift.

1. **Canonical geometry.** Today the matched route is `Hike.route` and the raw trace sits beside it in `rawRoute`, kept only when a match actually moved the line. The alternative is raw-as-canonical with the match as a display layer: more honest about provenance, more work for every existing consumer. The current choice is the simpler one, not necessarily the right one.
2. **Pause semantics.** A pause stops distance accumulation and journals a marker, but the saved route stays one continuous segment. If a pause should produce a genuine break in the drawn line, `GPXImport`'s flattening assumption and the single-segment route model both have to change together.
3. **Shipped trail graphs.** Overpass-on-demand with a local cache works offline only where you have already been. Prebuilt regional graphs from Geofabrik extracts would work offline where you are going, at the cost of a build pipeline and a download story. Worth it?
4. **Widget takeover.** A live recording currently displaces the selected hike on the widget entirely. The alternative is keeping the trail on screen with a small recording badge.


## TODO

Ordered by priority within each group. Each item names the file it lands in, so none of them needs this document re-read to start.

### UI performance

- [ ] **Pin what `MapSheet` reads, then close it** (`OpenTrails/Map/MapSheet.swift`, `OpenTrailsTests/Map/RouteAppearanceIsolationTests.swift`): add an `ObservationCounter` test over the sheet's real read set and assert that a `routeWidth`/`tintHex` drag and an `autoSavedTileKeys` append cost it nothing. If `@Query` does invalidate per sample, narrow what the sheet observes to the fields `HikeRow` actually renders.
- [x] **Extract the two remaining high-frequency readers out of `HikeDetailView.body`** (`OpenTrails/Hikes/HikeDetailView.swift`): one small view owning the width slider and colour picker, one owning the auto-save note and `storedTilesRow`. Follows the precedent already set by `OfflineDownloadStatus` and `TrailProgressView` in `HikeDetailComponents.swift`.
- [x] **Move `RouteProfile` construction and `makeStats` off the main actor** (`OpenTrails/Hikes/HikeDetailView.swift`): `.task(id:)` currently does both inline. `RouteProfile` is already `nonisolated` and `[RouteCoordinate]` is `Sendable`, so this is the same move `GPXImport.runOffMain` already made one step earlier in the flow.
- [x] **Replace the two 1 Hz polling loops with observation of `LocationManager.coordinate`** (`OpenTrails/App/OpenTrailsModel.swift` `pollWeather()`, `OpenTrails/Hikes/HikeDetailView.swift` `followLocation()`): the source already throttles to 1/sec and already filters an unchanged fix, so both timers can stop ticking while the walker is stationary.

### Correctness

- [x] **Raise `SWIFT_STRICT_CONCURRENCY` to `complete` on `OpenTrails` and `OpenWidgetExtension`**: the two targets that own every `@unchecked Sendable`, every `OSAllocatedUnfairLock` and every detached task are the two the compiler currently checks least, while both test targets are already at `complete` and the shared package is in Swift 6 mode. Expect this to surface work; do it deliberately rather than discovering it in a crash report.
- [ ] **Set `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on `OpenWidgetExtension` and `OpenWidgetTests`**: surfaced by the item above, which left the widget the one remaining target configured differently from the app it ships inside. Its UI code is main-actor by convention rather than by default, so the two targets disagree about what an unannotated type means — and `OpenWidget/` is compiled into both.
- [x] **State `RenderSignpost`'s isolation rather than inheriting it** (`OpenTrails/General/Diagnostics/RenderInstrumentation.swift`): `callCounts`/`lastFireTimes` are mutable statics that are safe only because `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes them so. Mark the console path `@MainActor` explicitly, or put them behind the lock pattern the tile layer already uses.

### Optimization

- [x] **Compute the hike statistics in one pass** (`OpenTrails/Hikes/Hike+Statistics.swift`): today `makeStats` triggers roughly ten full walks of the route, four `elevations` arrays and four `timestamps` arrays. `HikeStatisticsTests` already covers the behaviour to refactor against.
- [x] **Stop `maxSpeed` allocating two `CLLocation`s per segment** (`OpenTrails/Hikes/Hike+Statistics.swift`): use `RouteGeometry.distanceMeters`, which exists in this repo precisely to avoid that allocation, and folds into the single pass above.

### API modernization

- [x] **Replace `NSLock` in `TestClock` with `Mutex`** (`OpenTrailsTests/General/TestSupport.swift`): the repository's only `NSLock`, and the only lock not following the pattern every other file follows. Guards a single `Date` behind manual `lock()`/`defer { unlock() }` pairs; `Mutex<Date>` removes both the pairs and the `@unchecked Sendable`.
- [x] **Use `Atomic<UInt64>` for the generation counter** (`OpenTrails/Map/Location/BackgroundTrailTracker.swift`): a bare counter currently wrapped in `OSAllocatedUnfairLock`, which is mutual exclusion it never needed.
- [x] **Migrate `OSAllocatedUnfairLock` to `Synchronization.Mutex`** (`TileCache.swift`, `TileCache+StorageManagement.swift`, `CachingTileOverlayRenderer.swift`, `AutoSaveTileStore.swift`, `MainThreadWatchdog.swift`, `StubTileProtocol.swift`): 14 declarations and 49 `withLock` sites. `Mutex` needs iOS 18 / macOS 15 / visionOS 2 and the floor is 26.5, so every shipping target qualifies. Zero `OSAllocatedUnfairLock` remain.
- [x] **Drop the `@unchecked Sendable` the migration makes redundant**: `AutoSaveTileStore` and `TestClock` are now plain `Sendable`. The remaining eight are *not* lock-related and stay — `TileCache` holds an `NSCache`, `MemoryTile`/`FetchedTile` hold a `TileImage`, and `CachingTileOverlayRenderer`, `TileOverlay` and `StubTileProtocol` inherit from Objective-C classes the SDK does not declare `Sendable`. Their doc comments now name the superclass as the reason rather than the locks.
- [x] **Raise `SWIFT_VERSION` to `6.0`** on all 10 build configurations: the app and widget compiled in Swift 6 mode with **zero** source changes — the earlier `SWIFT_STRICT_CONCURRENCY = complete` work had already absorbed the cost. The four errors it did surface were all in test code and all genuine: two file-scope constants implicitly `@MainActor` under `SWIFT_DEFAULT_ACTOR_ISOLATION` but read from `nonisolated` contexts (`RecordingFixPolicyTests`, `OverpassTrailGraphProviderTests`), a main-actor `store` captured by a `@Sendable` closure (`AutoSaveTileTests`), and one trailing closure that SE-0286's forward scan binds to `clock:` rather than `transport:` (`OverpassTrailGraphProviderTests`) — a silent mis-binding Swift 5 mode's backward-scan fallback had been hiding.
- [x] **Use `ContinuousClock` for elapsed-time measurement** (`OpenTrails/General/Diagnostics/RenderInstrumentation.swift`): four `CFAbsoluteTimeGetCurrent()` calls measured intervals with a wall clock that can jump backwards on an NTP correction and report a negative duration. Also replaced the two `String(format:)` calls with `Duration.formatted(.units(...))`.
- [x] **Modernize the watchdog's flags, keep its thread** (`OpenTrails/General/Diagnostics/MainThreadWatchdog.swift`): both locks became `Atomic<Bool>`, the once-only start guard becoming a single `compareExchange` instead of a lock's read-test-write. The raw `Thread` and `DispatchQueue.main.async` were **deliberately kept** and are now documented as such: a watchdog scheduled on the cooperative pool would be starved by the same congestion it exists to report, and a `@MainActor` hop would measure the pool's scheduling on top of the main queue's. Replacing them would have been a regression dressed as a modernization.

### Code to remove

- [x] **Delete `violations.txt`** and add it to `.gitignore`. It is a stale 43 KB SwiftLint report; the current config reports 2 violations, not the hundreds it lists.
- [x] **Fix the two live lint violations** in `OpenTrailsUITests/OpenTrailsUITests.swift`: `unneeded_throws_rethrows` on `setUpWithError()`, and `balanced_xctest_lifecycle`.
- [x] **Delete `OpenWatch Watch App/` and `OpenWatchWidget/`** and their `.swiftlint.yml` `included:` entries — empty asset shells, absent from the Xcode project and from git — or land the watch target they were scaffolded for.

### Missing test cases

- [ ] **A sheet-isolation suite**, as described under *UI performance* above. This is the highest-value missing test: it is the one channel the existing isolation tests were written to close and don't cover.
- [x] **A "cost of opening a hike" workload suite** (`OpenTrailsTests/Hikes/`), modelled on `ImportWorkloadTests`: build a `RouteProfile` and the stat set for an 18,000-point route, assert the work does not run on the main thread, and assert the stats stay correct across the one-pass refactor.
- [ ] **Unit suites for the six untested files** listed in *Test gaps* — `SearchCompleter`, `WeatherManager`, `DirectionalPolylineRenderer`, `TrailBasemapRenderer`, `TopEdgeReader`, `MainThreadWatchdog`.
- [ ] **UI automation for the three unguarded flows**: the widget deep link's three branches (live recording, pushed hike, deleted hike) in `openWidgetLink`; deleting a hike whose detail view is pushed, which `MapSheet.delete`'s `path.removeAll` exists for; and the recording ambiguity review, which gates a SwiftData insert behind user choices.

### Infrastructure

- [ ] **Add CI** (hygiene): compile gates for iOS, macOS and visionOS; the app, widget and shared-package test suites; SwiftLint; strict mode, so a suite that can't run fails instead of disappearing. Nothing above is protected on a pull request until this exists.

### Product readiness

- [ ] **Add a localization catalog** before the app is offered in more than one language.
