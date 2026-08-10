# OpenTrails

A SwiftUI hiking/trail-mapping app for iOS, iPadOS, macOS, and visionOS. OpenTrails renders an OpenStreetMap-style raster map with a persistent, Apple Maps–style bottom sheet, lets you import GPX tracks and browse them with an interactive elevation profile, and saves map tiles for offline use — either by bulk pre-download or by passively caching whatever you've actually viewed, depending on what each tile provider's usage policy allows.

## Features

- **Full-screen map** (MapKit) with a persistent bottom sheet for search and your hikes list, in the style of Apple Maps.
- **Multiple tile providers** — OpenStreetMap (default, no API key needed), Stadia Outdoors, and Thunderforest Outdoors — switchable in Settings.
- **Offline maps**, via two complementary mechanisms: bulk pre-download for providers that permit it, and passive auto-save of tiles you've actually browsed (the only offline mechanism OpenStreetMap's tile usage policy allows).
- **GPX import** (via [CoreGPX](https://github.com/vincentneo/CoreGPX)), pulling track points plus author/description/keywords metadata.
- **Hike detail view** with an interactive elevation profile (Swift Charts) you can scrub, distance/elevation-gain/elevation-loss/speed/duration stats, a customizable route tint and line width, and directional chevrons on the map showing travel direction.
- **Live GPS auto-follow** — while a hike is open, the elevation chart and map track your live position along that trail.
- **Weather badge** for your current location (WeatherKit).
- **Search** — MapKit place search, plus matching against your own saved hikes, surfaced together in one suggestions list.

## Requirements

- Xcode 26.5 or later.
- Deployment targets: iOS/iPadOS 26.5, macOS 26.5, visionOS 26.5 (`TARGETED_DEVICE_FAMILY = 1,2,7`).
- An Apple Developer Program team — **WeatherKit requires a paid membership**; the project won't build against a free personal team without removing that entitlement.
- Network access for map tiles, weather, and search. Once a hike's tiles are downloaded or auto-saved, its map works offline.

## Getting started

1. Clone the repo and open `OpenTrails.xcodeproj` in Xcode.
2. In **Signing & Capabilities**, change the team from the placeholder (`697EW27G9U`) to your own.
3. *(Optional)* Enable the key-gated providers (Stadia Outdoors, Thunderforest Outdoors):
   ```
   cp Secrets.example.plist OpenTrails/Secrets.plist
   ```
   Fill in your own API keys ([Stadia](https://client.stadiamaps.com/), [Thunderforest](https://www.thunderforest.com/docs/apikeys/)) — instructions are in the file's header comment. `OpenTrails/Secrets.plist` is gitignored, so your key never gets committed. Without it, OpenStreetMap (the default, keyless) still works fully; Stadia/Thunderforest remain selectable in Settings but won't load tiles (see [Known limitations](#known-limitations)).
4. Build and run. Grant "While Using the App" location access when prompted.
5. To exercise location-driven features (auto-follow, weather) in the Simulator: **Debug ▸ Simulate Location**, or set a GPX under the scheme's **Run ▸ Options ▸ Core Location** tab — `OpenTrails/SimulatedLocations/ThumseeLoopFast.gpx` is bundled for this.

## Architecture

```
OpenTrailsApp
 └─ ContentView                     full-screen map + persistent sheet, owns shared state
     ├─ OSMMapView                  MKMapView wrapper (UIViewRepresentable/NSViewRepresentable)
     └─ MapSheet                    search + hikes list
         ├─ SettingsView            tile-provider picker, offline storage
         └─ HikeDetailView          elevation chart, stats, offline/color/width controls
```

### Keeping SwiftUI's diffing out of the hot paths

The most distinctive pattern in this codebase: state that changes at high frequency — GPS fixes (~1/sec), a dragged sheet's top edge (frame rate), an elevation-chart scrub (drag frequency) — is held in plain `@Observable` reference types (`RouteHighlight`, `SheetMetrics`, `MapController`, `TrackerState`, `LocationManager`) and passed down the view tree as stable object *references*, not as `@State`/`@Binding` value state.

The owning SwiftUI views (`ContentView`, `MapSheet`, `HikeDetailView`) never read these objects' properties in their own `body`. Only the imperative code that actually needs them does — e.g. `OSMMapView.Coordinator` observes them with `withObservationTracking` and updates MapKit directly, entirely outside SwiftUI's render loop. That keeps a ~1/sec location publish or a per-frame sheet drag from invalidating (and re-diffing) an expensive view tree, while still moving the one small piece of UI — a map annotation, a button constraint, a chart marker — that actually needs to move.

This is explained at length in comments throughout `OSMMapView.swift`, `ContentView.swift`, and `HikeDetailView.swift`, with `RenderSignpost` marks to verify it empirically (see [Debug tooling](#debug-tooling)). Worth reading before changing how state flows through those files — it's easy to accidentally reintroduce the re-render storms this works around.

### Tile pipeline

```
MKMapView draw pass
 └─ CachingTileOverlayRenderer.draw(_:zoomScale:in:)
     └─ OSMTileOverlay.cachedImage(at:)          sync memory-cache lookup
          hit  → draw immediately
          miss → draw a cropped lower-zoom tile as a placeholder ("overzoom" fallback)
               → loadTileIfNeeded() spawns a Task, gated by TileLoadGate (max 4 concurrent)
                   → OSMTileOverlay.cacheTile(at:)
                       → TileCache.loadTile: memory → ephemeral disk → durable disk → network
                       → AutoSaveTileStore.considerPersisting (opportunistic durable save)
                   → setNeedsDisplay() on success, re-triggering the draw pass
```

`TileCache` is a two-tier (memory + disk) cache with two disk stores: an ephemeral one (`Caches/`, subject to OS storage-pressure eviction) and a durable one (`Application Support/`, for tiles explicitly worth keeping). It monitors network reachability (`NWPathMonitor`) and notifies renderers to retry failed tiles on reconnect.

### Offline maps: two complementary mechanisms

- **Bulk download** (`OfflineTileDownloader`) — only for providers whose usage policy allows pre-fetching (`TileProvider.supportsBulkDownload`). Enumerates a route's bounding-box tiles across zoom levels (`SlippyTileMath`), fetches up to 5 concurrently, capped at 4,000 tiles.
- **Auto-save** (`AutoSaveTileStore` + `AutoSaveController`) — passively persists tiles as they're actually browsed while a hike is selected, scoped to a `TileCorridor` (the route's bounding box, padded 1,500 m) and capped at 3,000 tiles per hike. This is the *only* offline mechanism OpenStreetMap's tile usage policy permits, and it doubles as a gap-filler for bulk-capable providers — any tile a bulk pass missed still gets saved the moment it's browsed. A background drain (every 2s) merges newly-saved keys into the hike's SwiftData record.

Both mechanisms record just enough (`OfflineDownloadRecord`, `Hike.autoSavedTileKeys`) to *recompute* — and so measure and delete — exactly the tiles each one saved, rather than storing redundant tile lists.

### Data & persistence

`Hike` is a SwiftData `@Model`: title, route (`[RouteCoordinate]`, inline `Codable`), tint/width, and offline-download bookkeeping. Derived stats (distance, elevation gain/loss, average/max speed, duration) are computed properties over the route. `RouteProfile` precomputes a cumulative-distance index once per hike so scrubbing the elevation chart resolves a map location in O(log n) via binary search, and so live GPS auto-follow can project a fix onto the route.

### Debug tooling

Both are `#if DEBUG`-gated and no-op entirely in Release builds:

- **`RenderInstrumentation.swift`** (`RenderSignpost`) — marks SwiftUI body evaluations and `UIViewRepresentable`/`NSViewRepresentable` update calls as `os_signpost` events, visible in Instruments' Points of Interest track. Set `RENDER_SIGNPOST_LOG=1` in the scheme's environment variables to also print each mark to the console with a running per-name call count and time-since-last-fire — useful for confirming the render-isolation pattern above is actually working, without an Instruments session.
- **`MainThreadWatchdog.swift`** — a background thread pings the main run loop every 0.2s and logs a warning if it doesn't answer within 0.15s, catching synchronous work (disk I/O, image encoding, large collection ops) that slipped onto the main thread. Also defines `assertOffMainThread(_:)`, asserted at the top of every function in the tile pipeline that's documented as "must not run on main."

## Project layout

**App shell**
| File | Role |
|---|---|
| `OpenTrailsApp.swift` | `@main` entry point; starts `MainThreadWatchdog` in DEBUG; sets up the SwiftData container. |
| `ContentView.swift` | Root view — full-screen map + persistent sheet; owns the shared reference-type state; polls weather; handles GPX import. |

**Map & rendering**
| File | Role |
|---|---|
| `OSMMapView.swift` | `MKMapView` wrapper; `Coordinator` drives imperative updates; defines `RouteHighlight`/`SheetMetrics`/`MapController`/`DisplayedRoute`. |
| `CachingTileOverlayRenderer.swift` | Custom `MKOverlayRenderer`: draws cached tiles, crops lower-zoom tiles for overzoom, gates concurrent tile loads. |
| `DirectionalPolylineRenderer.swift` | Custom `MKPolylineRenderer`: route line plus evenly-spaced direction chevrons. |
| `OSMTileOverlay.swift` | `MKTileOverlay` subclass backed by `TileCache`; tile-path helpers for overzoom. |

**Tile pipeline & offline maps**
| File | Role |
|---|---|
| `TileProvider.swift` | Catalog of selectable tile sources + settings keys. |
| `TileCache.swift` | Two-tier memory/disk cache; ephemeral vs. durable stores; reachability monitor. |
| `SlippyTileMath.swift` | Slippy-map tile index ↔ coordinate conversions. |
| `TileCorridor.swift` | A route's padded bounding box, scoping auto-saved tiles to "near the trail." |
| `OfflineTileDownloader.swift` | Bulk tile pre-fetch for policy-permitting providers. |
| `AutoSaveTileStore.swift` / `AutoSaveController.swift` | Passive save-what-you-view pipeline; HEIC-encodes tiles; drains saved keys into the active hike. |

**Data & import**
| File | Role |
|---|---|
| `Hike.swift` | SwiftData model + derived stats + `Color` hex helpers. |
| `GPXImport.swift` | Parses a `.gpx` file (via CoreGPX) into points + metadata. |
| `RouteProfile.swift` | Precomputed distance/elevation index for O(log n) scrub lookups and route-matching. |

**UI**
| File | Role |
|---|---|
| `MapSheet.swift` | Persistent bottom sheet: search + suggestions, hikes list, import/record actions. |
| `HikeDetailView.swift` | Pushed hike detail: elevation chart, stats grid, offline/color/width controls, auto-follow. |
| `SettingsView.swift` | Tile-provider picker, offline storage total + delete-all, account placeholder. |
| `SearchCompleter.swift` | Wraps `MKLocalSearchCompleter` for the search bar's autocomplete. |
| `TopEdgeReader.swift` | Reports a view's top edge for the "my location" button's sheet-aware positioning. |

**Location & weather**
| File | Role |
|---|---|
| `LocationManager.swift` | Throttled `CLLocationManager` wrapper (delegate-based — see the file header for why not the async `liveUpdates()` stream). |
| `WeatherManager.swift` | WeatherKit current-conditions fetch. |

**Debug tooling** — `RenderInstrumentation.swift`, `MainThreadWatchdog.swift` (see above).

**Secrets** — `Secrets.swift`, `Secrets.plist` (gitignored, real keys), `Secrets.example.plist` (committed template).

## Tile providers

| Provider | ID | API key | Max zoom | Bulk download | Attribution |
|---|---|---|---|---|---|
| OpenStreetMap | `osm` | No | 19 | No (auto-save only) | © OpenStreetMap contributors |
| Stadia Outdoors | `stadia_outdoors` | Yes | 20 | Yes | © Stadia Maps, © OpenMapTiles, © OpenStreetMap contributors |
| Thunderforest Outdoors | `thunderforest_outdoors` | Yes | 22 | Yes | Maps © Thunderforest, Data © OpenStreetMap contributors |

## Privacy & entitlements

- Location: "when in use" only (`NSLocationWhenInUseUsageDescription`), used to show your position and drive auto-follow.
- `OpenTrails.entitlements` grants WeatherKit access and outbound network client access; App Sandbox and Hardened Runtime are both enabled.
- All map/weather/search requests go directly from the device to the relevant provider (OpenStreetMap, Stadia, Thunderforest, Apple Weather/Maps) — there is no OpenTrails backend.

## Known limitations

- **Recording a live hike isn't implemented yet** — the record button in the hikes list is wired up but currently a no-op (`ContentView.recordHike`); only GPX import works today.
- **Sign in with Apple** in Settings is a visual placeholder, not yet functional.
- **No in-app API key entry** — Stadia and Thunderforest keys can only be supplied via the bundled `Secrets.plist`; there's no Settings field to paste one in on-device.
- **No automated tests** — the project currently has a single app target and no unit/UI test target.
- **No app-wide offline storage cap** — each hike's tiles are capped individually (3,000 auto-saved / ~4,000 bulk-downloaded), but total disk usage across many hikes is unbounded aside from the manual "Delete All" in Settings.
