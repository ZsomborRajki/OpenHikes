# OpenTrails repository instructions

## Build and test

The main project requires Xcode 26.5+, the iOS and watchOS 26.5 platforms, and a development team capable of signing the WeatherKit entitlement. The shared package can be built and tested independently on macOS.

```sh
# Build the app and its embedded widget/Watch targets
xcodebuild build \
  -project OpenTrails.xcodeproj \
  -scheme OpenTrails \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Run all app-hosted tests
xcodebuild test \
  -project OpenTrails.xcodeproj \
  -scheme OpenTrails \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Run one app test suite or one test method
xcodebuild test -project OpenTrails.xcodeproj -scheme OpenTrails \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:OpenTrailsTests/HikeStatisticsTests
xcodebuild test -project OpenTrails.xcodeproj -scheme OpenTrails \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:OpenTrailsTests/HikeStatisticsTests/elevationGainAndLoss

# Run the standalone shared-package suite
swift test --package-path OpenTrailsShared

# Run one shared-package suite or test
swift test --package-path OpenTrailsShared --filter MercatorTests
swift test --package-path OpenTrailsShared \
  --filter 'OpenTrailsSharedTests.MercatorTests/tileIndicesUnchanged'
```

Tests use Swift Testing (`@Suite`, `@Test`, `#expect`), not XCTest. App tests use the in-memory SwiftData fixtures in `OpenTrailsTests/TestSupport.swift`; tests that require App Group entitlements or network access are conditionally enabled. There is no dedicated lint or formatting command.

## Architecture

- `OpenTrails` is the SwiftUI/SwiftData application. `OpenTrailsApp` creates the single `ModelContainer` and the long-lived `BackgroundTrailTracker`; `ContentView` owns selection, map, location, weather, navigation, and auto-save coordination. `Hike` is the persisted source of truth, while `RouteProfile` is the precomputed distance/elevation index used by both chart scrubbing and GPS route matching.
- The map is an imperative MapKit subsystem behind `MapView`. `MapCoordinator` observes stable controller objects and updates `MKMapView` directly. Tile drawing flows through `CachingTileOverlayRenderer` and `TileOverlay` into `TileCache`; passive durable saves go through `AutoSaveTileStore`, while policy-permitted bulk downloads go through `OfflineTileDownloader`.
- `OpenTrailsShared` is a local Swift package consumed by the app, iOS widget, Watch app, and Watch complication. Put cross-target payloads, projections, deep links, and shared presentation logic here rather than duplicating them in targets.
- The app precomputes a compact `SharedTrailSnapshot`, writes it atomically through `SharedStore`, and reloads widget timelines. The iOS widget reads that App Group store directly. The phone also transfers the snapshot with WatchConnectivity; the Watch app writes it to its device-local App Group store for the Watch UI and complication. Widgets and Watch surfaces do not recompute route matching or read location themselves.
- Target folders are Xcode file-system-synchronized groups. New Swift files under `OpenTrails/`, `OpenTrailsTests/`, `OpenWidget/`, `OpenWatch Watch App/`, or `OpenWatchWidget/` are discovered by their corresponding targets; place files in the target that should compile them.

## Repository-specific conventions

- Preserve render isolation. High-frequency GPS, sheet, chart-scrub, and map-command state lives in stable `@Observable` reference types such as `RouteHighlight`, `SheetMetrics`, `MapController`, `TrackerState`, and `LocationManager`. Parent SwiftUI bodies must not read their changing properties; `MapCoordinator` uses `withObservationTracking` to update only MapKit. Use `RenderSignpost` and the `RENDER_SIGNPOST_LOG=1` scheme variable when changing this flow.
- UI and SwiftData coordination are main-actor isolated. Delegate callbacks are `nonisolated` and explicitly hop to `Task { @MainActor in ... }`. Tile math, image encoding, disk enumeration, and other blocking pipeline work stay off the main thread; existing hot paths call `assertOffMainThread`. Keep shared off-main types `Sendable` and protect mutable singleton state with the existing lock pattern.
- Respect tile-provider policy. `TileProvider.supportsBulkDownload` gates prefetching: OpenStreetMap is passive auto-save only. Tile identity includes provider, zoom/x/y, and display scale. When deleting durable tiles, use `TileOwnership` so tiles shared by multiple hikes are not removed.
- `TileCache` intentionally has memory, ephemeral cache, and durable Application Support tiers. Do not turn a render miss into synchronous disk/network work, and do not move expensive storage measurement into a SwiftUI body.
- When adding non-optional properties to the SwiftData `Hike` model, give them inline declaration defaults as well as initializer defaults so lightweight migration can backfill existing stores.
- Keep persisted identifiers stable: provider IDs, `SettingsKey` strings, `SharedStore.appGroupID`, widget kind, cache-key shape, and deep-link format are shared across launches or targets. Update all entitlements/consumers together if an App Group contract changes.
- Cross-platform app code must continue compiling for iOS/iPadOS, macOS, and visionOS. Follow the existing `canImport(UIKit)`/`canImport(AppKit)` aliases and `#if os(iOS)` plus no-op-stub pattern for APIs such as WatchConnectivity.
- Never commit `OpenTrails/Secrets.plist`. Copy `Secrets.example.plist` locally for Stadia or Thunderforest keys; OpenStreetMap remains the keyless default.
