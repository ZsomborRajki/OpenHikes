//
//  HikeDeletionFailureTests.swift
//  OpenHikesTests
//
//  Deleting one hike's tiles when a claim read fails.
//
//  The third site that spends a tile claim set, after the launch sweeps and
//  the Settings actions, and the rule it follows is theirs:
//  `StoredTileDeletionPlan` deletes what its survivor set does *not* name, so
//  a set that is short by one hike is not a cautious answer — it is the
//  destructive one. Cache keys carry no hike identity, so the tiles the
//  missing hike downloaded for a valley with no signal are deleted along with
//  the doomed hike's, while its manifest goes on listing them: nothing
//  re-downloads them, and `trimCache(claimedBy:)` cannot see the hole, because
//  a claim with no file behind it looks exactly like a claim that is
//  satisfied.
//
//  There is no way to make a `ModelContext` throw on demand — a fetch against
//  a schema it does not know returns an empty result rather than an error —
//  and `HikeLocalState`'s fetch, where a claim actually lives, is not
//  injectable either. So the plan takes both claim reads as closures, the way
//  the sweeps take their fetch. Without that seam the refusal could be
//  rewritten as a `try?` with a fallback and every other test in the bundle
//  would still pass, while deleting one hike stripped its neighbour's map.
//
//  The shape is the one `SettingsStorageFailureTests` settled on: two tiles in
//  durable storage, one of them shared with a surviving hike, a *failing*
//  plan, then a *healthy* one whose effect on the doomed hike's own tile is
//  the positive result waited for. The shared tile still being there
//  afterwards is the assertion.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// The failure neither a `ModelContext` nor a sidecar fetch can be made to
/// produce on demand.
private struct ClaimReadFailure: Error {}

@Suite("Deleting a hike under a failed claim read")
struct HikeDeletionFailureTests {
    /// The tile both hikes claim, and the one only the doomed hike does. Both
    /// are written into the durable directory — `OSMTilesSaved` — because that
    /// is where the stakes are: browsing residue is re-fetched for free, while
    /// a tile in there was saved on purpose for a walk with no signal.
    private static let sharedKey = "osm/14/8723/5685@2.0"
    private static let exclusiveKey = "osm/14/8724/5685@2.0"

    /// What a red run on this suite means, in the terms the user would meet it.
    private static let strippedCoverageComment: Comment = """
        A claim read that failed left the surviving hike out of the survivor set, and deleting the \
        other hike took its tiles too. In the app that hike still lists them, nothing re-downloads \
        them, and the walker finds out where there is no signal.
        """

    private let context: ModelContext

    init() throws {
        context = try Fixture.modelContext()
    }

    /// Two hikes over the same ground, claiming by auto-saved key so the claim
    /// is exactly the two tiles on disk rather than a recomputed route grid.
    private func sandboxWithSharedTile() throws -> (sandbox: TileSandbox, doomed: Hike, survivor: Hike) {
        let sandbox = TileSandbox()
        try sandbox.save(key: Self.sharedKey)
        try sandbox.save(key: Self.exclusiveKey)
        let doomed = Fixture.hike(in: context, title: "Doomed")
        let survivor = Fixture.hike(in: context, title: "Still on the device")
        doomed.autoSavedTileKeys = [Self.sharedKey, Self.exclusiveKey]
        survivor.autoSavedTileKeys = [Self.sharedKey]
        try #require(survivor.hasStoredTiles, "a survivor claiming nothing cannot witness anything")
        return (sandbox, doomed, survivor)
    }

    /// The assertion the whole file exists for.
    @Test("a survivor claim that throws frees nothing, not even the doomed hike's own tile")
    func failedSurvivorClaimFreesNothing() async throws {
        let (sandbox, doomed, survivor) = try sandboxWithSharedTile()

        let refused = StoredTileDeletionPlan(
            doomedClaim: { TileOwnership(doomed) },
            survivingClaims: { throw ClaimReadFailure() }
        )
        await refused?.removeExclusiveTiles(from: sandbox.cache)

        #expect(refused == nil, "a survivor claim that failed must not reach the cache at all")
        #expect(sandbox.isSaved(Self.sharedKey), Self.strippedCoverageComment)
        #expect(sandbox.isSaved(Self.exclusiveKey), Self.strippedCoverageComment)

        // The control, in the same test: the doomed hike's own tile was
        // deletable all along, so the assertions above are about the refusal
        // rather than about a sandbox the deletion could never reach.
        let healthy = try #require(StoredTileDeletionPlan(removing: doomed, among: [doomed, survivor]))
        await healthy.removeExclusiveTiles(from: sandbox.cache)

        #expect(!sandbox.isSaved(Self.exclusiveKey))
        #expect(sandbox.isSaved(Self.sharedKey), Self.strippedCoverageComment)
    }

    /// The doomed side of the same guard. Losing this claim is the benign
    /// half — an unreadable manifest deletes nothing rather than too much —
    /// but it is refused rather than read as an empty claim so that the plan
    /// has one answer, and so the caller emptying the manifest afterwards does
    /// not write through a sidecar it could not read.
    @Test("a doomed claim that throws frees nothing")
    func failedDoomedClaimFreesNothing() async throws {
        let (sandbox, _, _) = try sandboxWithSharedTile()

        let refused = StoredTileDeletionPlan(
            doomedClaim: { throw ClaimReadFailure() },
            survivingClaims: { [] }
        )
        await refused?.removeExclusiveTiles(from: sandbox.cache)

        #expect(refused == nil)
        #expect(sandbox.isSaved(Self.sharedKey))
        #expect(sandbox.isSaved(Self.exclusiveKey))
    }

    /// And the boundary the guard is *not* allowed to blur: the last hike in
    /// the library is an honestly empty survivor set, and that one does free
    /// everything it claims. This is precisely the case a fallback makes
    /// indistinguishable from a failure, which is why the distinction lives in
    /// the type.
    @Test("the last hike in the library is an honest empty survivor set, and frees its tiles")
    func onlyHikeStillFreesItsTiles() async throws {
        let sandbox = TileSandbox()
        try sandbox.save(key: Self.exclusiveKey)
        let doomed = Fixture.hike(in: context, title: "The only one")
        doomed.autoSavedTileKeys = [Self.exclusiveKey]

        let plan = try #require(StoredTileDeletionPlan(removing: doomed, among: [doomed]))
        await plan.removeExclusiveTiles(from: sandbox.cache)

        #expect(!sandbox.isSaved(Self.exclusiveKey))
    }

    /// A hike that never saved a tile has no sidecar row at all, and that is a
    /// claim of nothing rather than a claim that could not be read: the plan
    /// is built, and deletes nothing.
    @Test("a hike that stored nothing plans a deletion of nothing")
    func hikeWithoutStoredTilesIsNotARefusal() async throws {
        let sandbox = TileSandbox()
        try sandbox.save(key: Self.sharedKey)
        let doomed = Fixture.hike(in: context, title: "Never saved anything")
        let survivor = Fixture.hike(in: context, title: "Still on the device")
        survivor.autoSavedTileKeys = [Self.sharedKey]

        let plan = try #require(StoredTileDeletionPlan(removing: doomed, among: [doomed, survivor]))
        await plan.removeExclusiveTiles(from: sandbox.cache)

        #expect(sandbox.isSaved(Self.sharedKey), Self.strippedCoverageComment)
    }
}
