//
//  TileRendererSuppressionTests.swift
//  OpenHikesTests
//
//  A tile the network policy refused to request is not a tile that failed to
//  load, and the renderer is where that distinction has to survive: it is the
//  only place that turns a missing image into a backoff.
//
//  It did not survive. Under Low Data Mode every interactive fetch was denied,
//  the denial arrived at the renderer as an ordinary miss, and each visible
//  tile escalated through the retry ladder to its five-minute ceiling — so
//  turning Low Data Mode off left the map holed for minutes while the walker
//  waited out a backoff recorded against the app's own policy.
//
//  Both halves are pinned here: a refused load stays out of the failure log,
//  and the renderer skips the tile until the policy edge that clears it.
//
//  No stub transport, because there is nothing to script — the policy refuses
//  before the cache reaches the network, and the suite keeps its distance from
//  the process-wide response script the other tile suites share.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

@Suite("Tile renderer policy suppression")
struct TileRendererSuppressionTests {
    private static let path = MKTileOverlayPath(x: 9500, y: 14_600, z: 15, contentScaleFactor: 2)

    private func overlay(for sandbox: TileSandbox) -> TileOverlay {
        TileOverlay(
            providerID: "osm_suppression_test",
            urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png",
            cache: sandbox.cache,
            autoSaveStore: sandbox.store
        )
    }

    /// Builds a renderer whose next load is already refused, and waits for the
    /// refusal to land — the state every test here starts from.
    @MainActor
    private func suppressedRenderer(on sandbox: TileSandbox) async -> CachingTileOverlayRenderer {
        sandbox.cache.setNetworkConditions(
            TileNetworkConditions(isOnline: true, isConstrained: true)
        )
        let renderer = CachingTileOverlayRenderer(overlay: overlay(for: sandbox))
        renderer.loadTileForTesting(at: Self.path)
        await settleDelegateHop(until: "the refused load to reach the renderer") {
            renderer.skipCounts.suppressed == 1
        }
        return renderer
    }

    /// The headline. Nothing was asked, so nothing may back off — the tile is
    /// skipped by the list the policy transition clears, not by the ladder
    /// that assumes a tile server behaving badly.
    @Test("a refused load is skipped without entering the failure log")
    @MainActor
    func refusedLoadIsNotAFailure() async {
        let sandbox = TileSandbox()
        let renderer = await suppressedRenderer(on: sandbox)

        #expect(renderer.skipCounts.failed == 0, "no server was asked, so nothing may back off")
        #expect(renderer.skipCounts.suppressed == 1)
    }

    /// And the skip has teeth: without it the offline map re-asks every
    /// uncached tile on every draw pass, spending a task and two
    /// ``TileLoadGate`` hops each time to be refused again.
    @Test("a refused tile is not asked for again while the policy stands")
    @MainActor
    func refusedTileIsNotReasked() async {
        let sandbox = TileSandbox()
        let renderer = await suppressedRenderer(on: sandbox)

        #expect(!renderer.mayAskForTile(at: Self.path))
    }

    /// The other end of the issue: leaving Low Data Mode is a transition that
    /// unblocks interactive fetching, and the renderer must ask again on the
    /// spot rather than waiting out a backoff it should never have recorded.
    @Test("leaving Low Data Mode releases the refused tile")
    @MainActor
    func leavingLowDataModeReleasesTheTile() async {
        let sandbox = TileSandbox()
        let renderer = await suppressedRenderer(on: sandbox)

        sandbox.cache.setNetworkConditions(TileNetworkConditions(isOnline: true))

        await settleDelegateHop(until: "the policy transition to reach the renderer") {
            renderer.skipCounts.suppressed == 0
        }
        #expect(renderer.mayAskForTile(at: Self.path))
    }
}
