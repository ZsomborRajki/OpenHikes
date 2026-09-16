//
//  LaunchSweepFailureTests.swift
//  OpenHikesTests
//
//  The launch-time sweeps when the claim fetch fails.
//
//  Both sweeps delete files that nothing in SwiftData points at any more, and
//  both decide what "nothing points at it" means from one fetch. The rule the
//  app states is that a fetch which fails sweeps *nothing* rather than
//  sweeping with an empty claim set — because an empty claim set is not a
//  cautious answer, it is the maximally destructive one: every durable tile a
//  user downloaded for a walk, and every photo they took on one, becomes
//  unclaimed at the same instant.
//
//  There is no way to make a `ModelContext` throw on demand — a fetch against
//  a schema it does not know returns an empty result rather than an error —
//  which is why both sweeps take their fetch as a closure. Without that seam
//  the `guard` could be rewritten as `?? []` and every other test in the
//  bundle would still pass, while the app quietly deleted the contents of two
//  directories at the next launch.
//
//  Each suite here follows the same shape: two orphaned files, a *failing*
//  sweep, then a *healthy* sweep that claims one of the two. The healthy
//  sweep deleting the unclaimed file is the positive effect waited for; the
//  claimed file still being there afterwards is the assertion.
//
//  What differs between the two is how the failing sweep is drained, and it
//  is the difference between a decisive test and a coin toss. The tile trim
//  goes through ``TileCache/scheduleMaintenance(_:)``, one serial queue, so a
//  later block running is already proof the earlier one finished — issuing the
//  healthy sweep second and waiting for its effect drains the failing one for
//  free. The photo reclaim queues an unstructured `Task`, and two of those
//  have no order at all: observing the files after only the healthy sweep's
//  effect asks which task won a race, and under a `?? []` that race is
//  winnable both ways. So that sweep hands its task back, and the test awaits
//  it. `nil` is the refusal itself — a failed claim fetch queues nothing.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// The failure a `ModelContext` cannot be made to produce.
struct LaunchClaimFetchFailure: Error {}

@Suite("Launch tile trim under a failed claim fetch")
struct LaunchTileTrimFailureTests {
    /// The tile a hike claims, and the one nothing does. Both are written into
    /// the durable directory — `OSMTilesSaved` — because that is where the
    /// stakes are: browsing residue is re-fetched for free, while a tile in
    /// there was downloaded on purpose for a walk with no signal.
    private static let claimedKey = "osm/14/8723/5685@2.0"
    private static let strayKey = "osm/14/8724/5685@2.0"
    /// Small enough that two tile files exceed it, so the trim's
    /// `total > limit` guard is genuinely crossed rather than skipped.
    private static let trimLimit: Int64 = 1

    private func writeTile(_ key: String, in sandbox: TileSandbox) throws {
        let url = sandbox.savedFile(for: key)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("tile bytes".utf8).write(to: url)
    }

    private func exists(_ key: String, in sandbox: TileSandbox) -> Bool {
        FileManager.default.fileExists(atPath: sandbox.savedFile(for: key).path)
    }

    /// The assertion the whole file exists for.
    ///
    /// Ordering is not in question on this side: `TileCache.scheduleMaintenance`
    /// runs its blocks on one serial `DispatchQueue`, so the failing sweep — if
    /// it enqueued anything at all — runs before the healthy one that the wait
    /// below observes.
    @Test("a claim fetch that throws deletes no tile, not even an unclaimed one")
    func failedClaimFetchTrimsNothing() async throws {
        let sandbox = TileSandbox()
        try writeTile(Self.claimedKey, in: sandbox)
        try writeTile(Self.strayKey, in: sandbox)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Downloaded for a walk with no signal")
        hike.autoSavedTileKeys = [Self.claimedKey]
        try #require(hike.hasStoredTiles, "a hike claiming nothing cannot witness anything")

        OpenHikesModel.trimTileCache(sandbox.cache, limit: Self.trimLimit) {
            throw LaunchClaimFetchFailure()
        }
        // Nothing has been enqueued to hop off yet, so this is already true if
        // it is ever going to be.
        #expect(exists(Self.claimedKey, in: sandbox))
        #expect(exists(Self.strayKey, in: sandbox))

        OpenHikesModel.trimTileCache(sandbox.cache, limit: Self.trimLimit) { [hike] }

        await settleDelegateHop(until: "the trim to have evicted the tile no hike claims") {
            !exists(Self.strayKey, in: sandbox)
        }
        #expect(
            exists(Self.claimedKey, in: sandbox),
            """
            The failed claim fetch swept with an empty claim set. In the app this deletes \
            every tile every hike downloaded for offline use, at launch, silently.
            """
        )
    }

    /// The control. Without it the test above would pass just as happily if
    /// `trimTileCache` had stopped deleting anything at all.
    @Test("a claim fetch that succeeds still evicts what no hike claims")
    func healthyClaimFetchTrimsTheStrayTile() async throws {
        let sandbox = TileSandbox()
        try writeTile(Self.claimedKey, in: sandbox)
        try writeTile(Self.strayKey, in: sandbox)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Claims one of the two")
        hike.autoSavedTileKeys = [Self.claimedKey]

        OpenHikesModel.trimTileCache(sandbox.cache, limit: Self.trimLimit) { [hike] }

        await settleDelegateHop(until: "the trim to have evicted the unclaimed tile") {
            !exists(Self.strayKey, in: sandbox)
        }
        #expect(exists(Self.claimedKey, in: sandbox))
    }

    /// And the boundary the guard is *not* allowed to blur: a library with no
    /// hikes in it is an honestly empty claim set, and that one does sweep.
    /// This is precisely the case a `?? []` makes indistinguishable from a
    /// failure, which is why the distinction lives in the type.
    @Test("a library with no hikes is an honest empty claim, and evicts")
    func emptyLibraryStillTrims() async throws {
        let sandbox = TileSandbox()
        try writeTile(Self.strayKey, in: sandbox)

        OpenHikesModel.trimTileCache(sandbox.cache, limit: Self.trimLimit) { [] }

        await settleDelegateHop(until: "the trim to have evicted the tile with no library to claim it") {
            !exists(Self.strayKey, in: sandbox)
        }
    }
}
