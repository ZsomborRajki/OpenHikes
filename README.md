# OpenTrails

A SwiftUI hiking/trail-mapping app for iOS, iPadOS, macOS, and visionOS. OpenTrails renders an OpenStreetMap-style raster map with a persistent, Apple Maps–style bottom sheet, lets you import GPX tracks and browse them with an interactive elevation profile, and saves map tiles for offline use — either by bulk pre-download or by passively caching whatever you've actually viewed, depending on what each tile provider's usage policy allows.

## Features

- **Full-screen map** (MapKit) with a persistent bottom sheet for search and your hikes list, in the style of Apple Maps.
- **Multiple tile providers** — OpenStreetMap (default, no API key needed), Stadia Outdoors, and Thunderforest Outdoors — switchable in Settings.
- **Offline maps**, via two complementary mechanisms: bulk pre-download for providers that permit it, and passive auto-save of tiles you've actually browsed (the only offline mechanism OpenStreetMap's tile usage policy allows).
- **GPX import** (via [CoreGPX](https://github.com/vincentneo/CoreGPX)), pulling track points plus author/description/keywords metadata.
- **Hike detail view** with an interactive elevation profile (Swift Charts) you can scrub, distance/elevation-gain/elevation-loss/speed/duration stats, a customizable route tint and line width, and directional chevrons on the map showing travel direction.
- **Live GPS auto-follow** — while a hike is open, the elevation chart and map track your live position along that trail.
- **Home Screen widget and Watch complication** — the selected trail's shape, over a pre-rendered basemap, with your last-known position along it. Fed by the app through an App Group; neither surface reads location or computes geometry itself.
- **Background trail tracking** (opt-in, iOS) — keeps those surfaces current while the app is closed, using significant-location-change delivery rather than continuous GPS.
- **Weather badge** for your current location (WeatherKit).
- **Search** — MapKit place search, plus matching against your own saved hikes, surfaced together in one suggestions list.
- **Offline storage that accounts for itself** — Settings separates tiles your hikes are keeping for offline use from tiles the map merely happened to draw, and lets you reclaim the latter without touching the former.

## Requirements

- Xcode 26.5 or later.
- Deployment targets: iOS/iPadOS 26.5, macOS 26.5, visionOS 26.5 (`TARGETED_DEVICE_FAMILY = 1,2,7`).
- An Apple Developer Program team — **WeatherKit requires a paid membership**; the project won't build against a free personal team without removing that entitlement.
- An App Group (`group.tappium.com.OpenTrails` as committed), shared by the app, the iOS widget, and the Watch complication — it's how the trail snapshot and the widget's basemap images get from the app to those surfaces.
- Network access for map tiles, weather, and search. Once a hike's tiles are downloaded or auto-saved, its map works offline.

## Getting started

1. Clone the repo and open `OpenTrails.xcodeproj` in Xcode.
2. In **Signing & Capabilities**, change the team from the placeholder (`697EW27G9U`) to your own — on all four targets (`OpenTrails`, `OpenWidgetExtension`, `OpenWatch Watch App`, `OpenWatchWidgetExtension`). If your team can't claim `group.tappium.com.OpenTrails`, change the App Group on all four to one you own, and update `SharedStore.appGroupID` in `OpenTrailsShared` to match.
3. *(Optional)* Enable the key-gated providers (Stadia Outdoors, Thunderforest Outdoors):
   ```
   cp Secrets.example.plist OpenTrails/Secrets.plist
   ```
   Fill in your own API keys ([Stadia](https://client.stadiamaps.com/), [Thunderforest](https://www.thunderforest.com/docs/apikeys/)) — instructions are in the file's header comment. `OpenTrails/Secrets.plist` is gitignored, so your key never gets committed. Without it, OpenStreetMap (the default, keyless) still works fully; Stadia/Thunderforest remain selectable in Settings but won't load tiles (see [Known limitations](#known-limitations)).
4. Build and run. Grant "While Using the App" location access when prompted.
5. To exercise location-driven features (auto-follow, weather) in the Simulator: **Debug ▸ Simulate Location**, or set a GPX under the scheme's **Run ▸ Options ▸ Core Location** tab — `OpenTrails/SimulatedLocations/ThumseeLoopFast.gpx` is bundled for this.

## Architecture

```
OpenTrailsApp                       owns the SwiftData container + BackgroundTrailTracker
 └─ ContentView                     full-screen map + persistent sheet, owns shared state
     ├─ MapView                     MKMapView wrapper (UIViewRepresentable/NSViewRepresentable)
     │   └─ MapCoordinator          MKMapViewDelegate; imperative overlay/annotation updates
     └─ MapSheet                    search + hikes list
         ├─ SettingsView            tile-provider picker, offline storage, background tracking
         └─ HikeDetailView          elevation chart, stats, offline/color/width controls

OpenTrailsShared (SwiftPM)          snapshot, Mercator, basemap geometry, deep links
 ├─ OpenWidget                      iOS Home Screen widget
 ├─ OpenWatch Watch App             minimal fallback surface
 └─ OpenWatchWidget                 Watch complication
```

### Keeping SwiftUI's diffing out of the hot paths

The most distinctive pattern in this codebase: state that changes at high frequency — GPS fixes (~1/sec), a dragged sheet's top edge (frame rate), an elevation-chart scrub (drag frequency) — is held in plain `@Observable` reference types (`RouteHighlight`, `SheetMetrics`, `MapController`, `TrackerState`, `LocationManager`) and passed down the view tree as stable object *references*, not as `@State`/`@Binding` value state.

The owning SwiftUI views (`ContentView`, `MapSheet`, `HikeDetailView`) never read these objects' properties in their own `body`. Only the imperative code that actually needs them does — e.g. `MapCoordinator` observes them with `withObservationTracking` and updates MapKit directly, entirely outside SwiftUI's render loop. That keeps a ~1/sec location publish or a per-frame sheet drag from invalidating (and re-diffing) an expensive view tree, while still moving the one small piece of UI — a map annotation, a button constraint, a chart marker — that actually needs to move.

One consequence is worth knowing before you touch either coordinate publisher: Observation filters a repeat write to an `Equatable` value automatically, but `CLLocationCoordinate2D` isn't `Equatable`, so the same position reads as news. Both places that publish one compare latitude/longitude by hand — `LocationManager.publish`, and `RouteHighlight`, whose `coordinate` is `private(set)` behind `move(to:)` precisely so no call site can skip the check. Without them, a walker standing still wakes the map's observation once a second forever, and a scrub crossing one track point's worth of trail wakes it once per drag event.

This is explained at length in comments throughout `MapView.swift`, `MapCoordinator.swift`, `MapControllers.swift`, `ContentView.swift`, and `HikeDetailView.swift`, with `RenderSignpost` marks to verify it empirically (see [Debug tooling](#debug-tooling)). Worth reading before changing how state flows through those files — it's easy to accidentally reintroduce the re-render storms this works around.

### Tile pipeline

```
MKMapView draw pass
 └─ CachingTileOverlayRenderer.draw(_:zoomScale:in:)
     └─ TileOverlay.cachedImage(at:)             sync memory-cache lookup
          hit  → draw immediately
          miss → draw a cropped lower-zoom tile as a placeholder ("overzoom" fallback)
               → loadTileIfNeeded() spawns a Task, gated by TileLoadGate (max 4 concurrent)
                   → TileOverlay.cacheTile(at:)
                       → TileCache.loadTile: memory → ephemeral disk → durable disk → network
                       → AutoSaveTileStore.considerPersisting (opportunistic durable save)
                   → setNeedsDisplay() on success, re-triggering the draw pass
```

`TileCache` is a two-tier (memory + disk) cache with two disk stores: an ephemeral one (`Caches/`, subject to OS storage-pressure eviction) and a durable one (`Application Support/`, for tiles explicitly worth keeping). It monitors network reachability (`NWPathMonitor`) and notifies renderers to retry failed tiles on reconnect.

Which tier a tile lands in follows from *why* it was fetched, not from how it's drawn. A tile fetched to draw the map goes to the ephemeral store; anything meant to survive goes durable, by one of two routes:

- `saveTileDurably(forKey:url:)` — the bulk-download path: fetch straight into durable storage. Offline coverage the user explicitly asked for can't sit in the first directory the OS purges under storage pressure.
- `promoteCachedTile(forKey:)` — the auto-save path: *move* the already-cached file across, bytes unchanged. A move rather than a re-encode because providers serve PNG, which is both the smallest and the only lossless representation on offer for flat-filled cartography (a lossless PNG round-trip through ImageIO measured +10%; HEIC at full quality +178%), and because it keeps a decode and an encode off the drawing path entirely.

### Offline maps: two complementary mechanisms

- **Bulk download** (`OfflineTileDownloader`) — only for providers whose usage policy allows pre-fetching (`TileProvider.supportsBulkDownload`). Enumerates a route's tiles from an overview zoom down to the provider's deepest, through `TileBoundingBox` (which treats longitude as cyclic, so an antimeridian route gets the short arc rather than a band around the world), and fetches up to 5 concurrently. The 4,000-tile budget binds at every level including the overview — a route too sprawling for even that gets a *shallower* overview rather than nothing at all.
- **Auto-save** (`AutoSaveTileStore` + `AutoSaveController`) — passively persists tiles as they're actually browsed while a hike is selected, scoped to a `TileCorridor` (the route's bounding box, padded 1,500 m) and capped at 3,000 tiles per hike. This is the *only* offline mechanism OpenStreetMap's tile usage policy permits, and it doubles as a gap-filler for bulk-capable providers — any tile a bulk pass missed still gets saved the moment it's browsed. A background drain (every 2s) merges newly-saved keys into the hike's SwiftData record; every teardown path (deselect, switch, disable, delete, delete-all) flushes that pending set first, so tiles saved in the last drain window can't outlive the record that would free them.

Both mechanisms record just enough (`OfflineDownloadRecord`, `Hike.autoSavedTileKeys`) to *recompute* — and so measure and delete — exactly the tiles each one saved, rather than storing redundant tile lists. `TileOwnership` answers the question that follows from tile keys being purely geographic (`providerID/z/x/y@scale`, with no hike in them): two hikes in the same area claim literally the same tiles, so deleting one hike frees only what no other hike still claims.

Everything on disk that no manifest claims is browsing residue — real, and often large, since MapKit caches every tile it draws. Settings reports it separately from offline coverage and can clear it on its own, and it's bounded: once-per-launch housekeeping trims it back under 500 MB, oldest tile first. Offline coverage is deliberately exempt from that ceiling — a hike's saved map is what the user has when there's no signal, so nothing removes it to save space except the user.

### Data & persistence

`Hike` is a SwiftData `@Model`: title, route (`[RouteCoordinate]`, inline `Codable`), tint/width, and offline-download bookkeeping. Derived stats (distance, elevation gain/loss, average/max speed, duration) are computed properties over the route. `RouteProfile` precomputes a cumulative-distance index once per hike so scrubbing the elevation chart resolves a map location in O(log n) via binary search, and so live GPS auto-follow can project a fix onto the route. It also downsamples the elevation samples for drawing — see [Known limitations](#known-limitations) for why that budget exists and what it preserves.

### Widget, complication, and background tracking

All the work happens in the app process; the widget and complication only render what they're handed.

`BackgroundTrailTracker` assembles a `SharedTrailSnapshot` — the trail's decimated shape, your matched position along it, and a status line — and writes it to the App Group through `SharedStore`, then reloads the relevant timelines. It's fed from two independent sources: a throttled foreground push from `HikeDetailView`'s existing auto-follow loop (no extra permission needed), and, if the user opts in, significant-location-change delivery, which can relaunch the app after it's been suspended or terminated. That's why it's constructed in `OpenTrailsApp.init()` rather than lazily in a view — a background relaunch may never reach a view's `.task`.

The iOS widget also gets a real basemap under the trail line, because WidgetKit can't host a live `Map`/`MKMapView` at any OS version. `TrailBasemapRenderer` rasterizes the trail's surroundings with `MKMapSnapshotter` (two shapes × light and dark) into the App Group, and `TrailBasemap` in the shared package pins each image to the patch of Earth it covers. Basemaps need the network, so a trail selected offline can end up without them; the app re-checks on every foreground.

The Watch is fed by `WatchConnectivityBridge` (iOS-only, owned internally by `BackgroundTrailTracker`) into the watch-local `SharedStore`. Tapping either surface deep-links back into the app via `TrailWidgetDeepLink`.

### Debug tooling

Both are `#if DEBUG`-gated and no-op entirely in Release builds:

- **`RenderInstrumentation.swift`** (`RenderSignpost`) — marks SwiftUI body evaluations and `UIViewRepresentable`/`NSViewRepresentable` update calls as `os_signpost` events, visible in Instruments' Points of Interest track. Set `RENDER_SIGNPOST_LOG=1` in the scheme's environment variables to also print each mark to the console with a running per-name call count and time-since-last-fire — useful for confirming the render-isolation pattern above is actually working, without an Instruments session.
- **`MainThreadWatchdog.swift`** — a background thread pings the main run loop every 0.2s and logs a warning if it doesn't answer within 0.15s, catching synchronous work (disk I/O, image encoding, large collection ops) that slipped onto the main thread. Also defines `assertOffMainThread(_:)`, asserted at the top of every function in the tile pipeline that's documented as "must not run on main."

## Tests

Two suites, both [Swift Testing](https://developer.apple.com/documentation/testing):

```
xcodebuild test -scheme OpenTrails -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
cd OpenTrailsShared && swift test
```

- **`OpenTrailsTests`** (178 tests) — a unit-test target hosted by the app, covering the logic behind the features: tile indexing and the auto-save corridor, offline tile enumeration (budget, antimeridian) and the shared-tile bookkeeping that decides what a delete may actually free, how offline coverage and browsing residue are told apart on disk, `RouteProfile`'s scrub lookups, downsampling and auto-follow route matching, derived hike statistics, GPX parsing (including malformed and hostile files), tint persistence, the snapshot feed the widget and Watch render from, and the render-isolation behaviour the architecture above depends on (what Observation notifies, and how much the elevation chart is asked to draw).
- **`OpenTrailsSharedTests`** (42 tests) — the shared package's own suite: the Mercator projection, the widget's basemap geometry, deep links, and the trail snapshot's progress/decimation.

Not covered: SwiftUI view bodies, `MapView`/`MapCoordinator`'s imperative MapKit updates, and `TileCache`'s network path. The render-isolation pattern described above is verified with `RenderSignpost` marks in Instruments rather than by tests — see [Debug tooling](#debug-tooling).

Both suites pass in full. The seven tests that used to fail on purpose each pinned a defect that has since been fixed; `CODE_REVIEW.md` records what they were, alongside the issues that are still open.

## Project layout

App sources live under `OpenTrails/` in three folders: `UI/`, `Models/`, and `Managers/`.

**App shell** — `UI/`
| File | Role |
|---|---|
| `OpenTrailsApp.swift` | `@main` entry point; builds the SwiftData container and `BackgroundTrailTracker`; starts `MainThreadWatchdog` in DEBUG. |
| `ContentView.swift` | Root view — full-screen map + persistent sheet; owns the shared reference-type state; polls weather; handles GPX import. |

**Map & rendering** — `UI/Map/`, `Managers/`
| File | Role |
|---|---|
| `MapView.swift` | `MKMapView` wrapper (`UIViewRepresentable`/`NSViewRepresentable`). |
| `MapCoordinator.swift` | Its `MKMapViewDelegate`: owns overlays/annotations and applies highlight/sheet/controller changes imperatively. |
| `MapControllers.swift` | The reference-type state the map observes directly: `RouteHighlight`, `SheetMetrics`, `MapController`. |
| `DisplayedRoute.swift` | The route to draw, keyed by id so the map only redraws when it changes. |
| `CachingTileOverlayRenderer.swift` | Custom `MKOverlayRenderer`: draws cached tiles, crops lower-zoom tiles for overzoom, gates concurrent tile loads. |
| `DirectionalPolylineRenderer.swift` | Custom `MKPolylineRenderer`: route line plus evenly-spaced direction chevrons. |
| `TileOverlay.swift` | `MKTileOverlay` subclass backed by `TileCache`; tile-path helpers for overzoom. |

**Tile pipeline & offline maps** — `Models/`, `Managers/`
| File | Role |
|---|---|
| `TileProvider.swift` | Catalog of selectable tile sources + settings keys. |
| `TileCache.swift` | Two-tier memory/disk cache; ephemeral vs. durable stores; claimed/unclaimed accounting; reachability monitor. |
| `SlippyTileMath.swift` | Slippy-map tile index ↔ coordinate conversions, plus `TileBoundingBox` (antimeridian-aware route bounds). |
| `TileCorridor.swift` | A route's padded bounding box, scoping auto-saved tiles to "near the trail." |
| `TileOwnership.swift` | Which tiles a hike claims, and which of those nothing else still needs — the basis for measuring and deleting. |
| `OfflineTileDownloader.swift` | Bulk tile pre-fetch for policy-permitting providers. |
| `AutoSaveTileStore.swift` / `AutoSaveController.swift` | Passive save-what-you-view pipeline; promotes browsed tiles into durable storage; drains saved keys into the active hike. |

**Data & import** — `Models/`, `Managers/`
| File | Role |
|---|---|
| `Hike.swift` | The SwiftData `@Model`. |
| `Hike+Statistics.swift` / `Hike+Presentation.swift` | Derived stats over the route; display-side helpers (coordinates, tint). |
| `HikeSupportingTypes.swift` | `RouteCoordinate`, `ElevationSample`, `OfflineDownloadRecord`. |
| `HikeFormat.swift` / `Color+Hex.swift` | Stat formatting; tint hex ↔ `Color`. |
| `GPXImport.swift` | Parses a `.gpx` file (via CoreGPX) into points + metadata; rejects unrepresentable coordinates. |
| `RouteProfile.swift` | Precomputed distance/elevation index for O(log n) scrub lookups and route-matching; downsamples samples for drawing. |

**UI** — `UI/`
| File | Role |
|---|---|
| `MapSheet.swift` | Persistent bottom sheet: search + suggestions, hikes list, import/record actions. |
| `HikeRow.swift` | One hike row, shared by the list and the search suggestions. |
| `HikeDetailView.swift` | Pushed hike detail: elevation chart, stats grid, offline/color/width controls, auto-follow. |
| `ElevationChartView.swift` / `HikeStatsViews.swift` | The scrubberable Swift Charts profile; the stats-grid building blocks. |
| `SettingsView.swift` | Tile-provider picker, offline storage split + clear/delete, background tracking, account placeholder. |
| `SearchCompleter.swift` | Wraps `MKLocalSearchCompleter` for the search bar's autocomplete. |
| `TopEdgeReader.swift` | Reports a view's top edge for the "my location" button's sheet-aware positioning. |

**Location, weather & companion surfaces** — `Managers/`
| File | Role |
|---|---|
| `LocationManager.swift` | Throttled `CLLocationManager` wrapper (delegate-based — see the file header for why not the async `liveUpdates()` stream). |
| `WeatherManager.swift` | WeatherKit current-conditions fetch. |
| `BackgroundTrailTracker.swift` | Builds and publishes the trail snapshot; owns the separate significant-location-change manager. |
| `TrailBasemapRenderer.swift` | Rasterizes the widget's basemap images into the App Group. |
| `WatchConnectivityBridge.swift` | Phone-side push of the snapshot to a paired Watch (iOS-only; stubbed elsewhere). |

**Other targets**
| Target | Role |
|---|---|
| `OpenTrailsShared/` | SwiftPM package shared by every target: `SharedTrailSnapshot`, `SharedStore`, `Mercator`, `TrailBasemap`, `TrailMapView`/`TrailGlyphView`, `TrailWidgetDeepLink`. |
| `OpenWidget/` | iOS Home Screen widget. |
| `OpenWatch Watch App/` | Minimal Watch app — a fallback surface for the complication. |
| `OpenWatchWidget/` | Watch complication. |

**Debug tooling** — `Managers/RenderInstrumentation.swift`, `Managers/MainThreadWatchdog.swift` (see above).

**Tests** — `OpenTrailsTests/` (app target logic, hosted by the app), `OpenTrailsShared/Tests/` (shared package). See [Tests](#tests).

**Secrets** — `Secrets.swift`, `Secrets.plist` (gitignored, real keys), `Secrets.example.plist` (committed template).

## Tile providers

| Provider | ID | API key | Max zoom | Bulk download | Attribution |
|---|---|---|---|---|---|
| OpenStreetMap | `osm` | No | 19 | No (auto-save only) | © OpenStreetMap contributors |
| Stadia Outdoors | `stadia_outdoors` | Yes | 20 | Yes | © Stadia Maps, © OpenMapTiles, © OpenStreetMap contributors |
| Thunderforest Outdoors | `thunderforest_outdoors` | Yes | 22 | Yes | Maps © Thunderforest, Data © OpenStreetMap contributors |

## Privacy & entitlements

- Location: "when in use" only (`NSLocationWhenInUseUsageDescription`), used to show your position and drive auto-follow. Background trail tracking is opt-in in Settings and uses significant-location-change delivery, not continuous GPS.
- `OpenTrails.entitlements` grants WeatherKit access, outbound network client access, and the App Group; App Sandbox and Hardened Runtime are both enabled. The widget and complication get the App Group only.
- All map/weather/search requests go directly from the device to the relevant provider (OpenStreetMap, Stadia, Thunderforest, Apple Weather/Maps) — there is no OpenTrails backend. The trail snapshot and basemap images stay on-device, in the App Group container.

## Known limitations

Scope-level gaps, plus the defects that are still open. `CODE_REVIEW.md` has the full current list with file references, measurements, and suggested fixes — including the UI-performance items not repeated here.

**Not built yet**

- **Recording a live hike isn't implemented** — only GPX import works today. The record button was removed rather than left promising something it couldn't do; it comes back with a recording session behind it.
- **Sign in with Apple** in Settings is a visual placeholder, not yet functional.
- **No in-app API key entry** — Stadia and Thunderforest keys are a build-time concern, supplied via the bundled `Secrets.plist`. Deliberate rather than pending: without a key those providers are shown as "Needs API key" and can't be selected, so the app tells you why instead of drawing a blank map.

**Open defects**

- **Six UI-performance items remain open** — chiefly that the whole hike detail view rebuilds once per downloaded tile, search ranking runs up to four times per keystroke, and the selected route's coordinates are re-mapped on every `ContentView` body pass. All are measured in `CODE_REVIEW.md`.

**Deliberate, but surprising**

- **The elevation chart doesn't plot every track point.** `RouteProfile` thins the samples to a fixed 500 for drawing — already past what a 390 pt chart resolves at 3×, and the difference between a scrub that tracks your finger and one that doesn't on a long track. It's min/max per bucket, not a stride, so the route's true high and low points, both endpoints, and strictly ascending distances all survive; the tests pin all four, because the chart derives its axes and the live tracker's placement from exactly those. The budget is a constant, though, not a function of the chart's actual width.
