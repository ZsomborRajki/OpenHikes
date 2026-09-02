//
//  TileRendererWiringTests.swift
//  OpenHikesTests
//
//  `TileOverlay` takes its ``TileCache`` and its ``AutoSaveTileStore`` as
//  initializer arguments specifically so a test's overlay can be wired to a
//  stub transport and its own directories instead of the app's singletons.
//  `CachingTileOverlayRenderer` reached past that: it registered its network-
//  policy listener on `TileCache.shared`, and read `isOnline` from it, whatever
//  cache the overlay it was constructed with was actually serving.
//
//  That is invisible in the app, where the two are the same object, and wrong
//  everywhere else: an offline test wired to its own cache still had its
//  renderer's retry decisions made by the host machine's real connection, and
//  every renderer built under test attached a listener to the app's singleton
//  and left it there.
//

import Foundation
import MapKit
@testable import OpenHikes
import Synchronization
import Testing

@Suite("Tile renderer wiring")
struct TileRendererWiringTests {
    private func overlay(for sandbox: TileSandbox) -> TileOverlay {
        TileOverlay(
            providerID: "osm_renderer_test",
            urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png",
            cache: sandbox.cache,
            autoSaveStore: sandbox.store
        )
    }

    private func isRegistered(_ renderer: CachingTileOverlayRenderer, with cache: TileCache) -> Bool {
        cache.observers.withLock { boxes in
            boxes.contains { $0.value === renderer }
        }
    }

    /// The headline. The policy listener is what clears a renderer's failed
    /// tiles, so registering it on the wrong cache means a renderer never
    /// hears that its actual cache can fetch again.
    @Test("the renderer listens to its overlay's cache")
    func rendererObservesTheInjectedCache() {
        let sandbox = TileSandbox(reachable: false)
        let renderer = CachingTileOverlayRenderer(overlay: overlay(for: sandbox))

        #expect(
            isRegistered(renderer, with: sandbox.cache),
            "the cache the overlay serves tiles from is the one whose reconnect matters"
        )
    }

    /// And the other half: nothing is left attached to the app's singleton.
    /// Observers are held weakly, so a stray registration is not a leak — but
    /// it is a renderer being woken by a cache it never reads.
    @Test("the renderer doesn't attach itself to the shared cache")
    func rendererLeavesTheSharedCacheAlone() {
        let sandbox = TileSandbox(reachable: false)
        let renderer = CachingTileOverlayRenderer(overlay: overlay(for: sandbox))

        #expect(!isRegistered(renderer, with: .shared))
    }

    /// Unregistering has to name the same cache registering did, or a
    /// renderer's listener outlives it in whichever list it landed in.
    @Test("the renderer unregisters from the cache it registered with")
    func rendererUnregistersFromTheInjectedCache() {
        let sandbox = TileSandbox(reachable: false)
        autoreleasepool {
            let renderer = CachingTileOverlayRenderer(overlay: overlay(for: sandbox))
            #expect(isRegistered(renderer, with: sandbox.cache), "precondition: it registered")
        }

        // `removeObserver` drops the box outright; a box merely emptied by the
        // weak reference going nil would still be counted here — which is what
        // unregistering from the wrong cache leaves behind.
        let remaining = sandbox.cache.observers.withLock { $0.count }
        #expect(remaining == 0)
    }

    /// Two renderers on two sandboxes stay in their own lists — the property
    /// that makes tile suites safe to run in parallel.
    @Test("renderers on different caches don't share a listener list")
    func renderersAreIsolatedPerCache() {
        let first = TileSandbox()
        let second = TileSandbox()
        let firstRenderer = CachingTileOverlayRenderer(overlay: overlay(for: first))
        let secondRenderer = CachingTileOverlayRenderer(overlay: overlay(for: second))

        #expect(isRegistered(firstRenderer, with: first.cache))
        #expect(!isRegistered(firstRenderer, with: second.cache))
        #expect(isRegistered(secondRenderer, with: second.cache))
        #expect(!isRegistered(secondRenderer, with: first.cache))
    }
}
