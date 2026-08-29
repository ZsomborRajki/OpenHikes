//
//  SettingsStorageFailureTests.swift
//  OpenHikesTests
//
//  The Settings storage actions when the claim fetch fails.
//
//  The companion to `LaunchSweepFailureTests`, on the other path that spends a
//  tile claim set — and the rule is the same one. `Clear Map Cache` frees
//  every tile the claim set does not name, walking the durable directory as
//  well as the browsing one, so a set built from a fetch that failed is not a
//  cautious answer: it is the maximally destructive one. Every tile every hike
//  downloaded for a valley with no signal becomes unclaimed at the same
//  instant, under a footer promising that clearing the cache "costs you
//  nothing offline".
//
//  There is no way to make a `ModelContext` throw on demand — a fetch against
//  a schema it does not know returns an empty result rather than an error —
//  which is why ``OfflineStorageActions`` takes its fetch as a closure. Without
//  that seam its refusals could be rewritten as `?? []` and every other test in
//  the bundle would still pass, while the app deleted the user's offline maps
//  the first time SwiftData hiccupped with this sheet open.
//
//  Each test here follows the shape that file settled on: two tiles in durable
//  storage, one of them claimed, a *failing* action, then a *healthy* one whose
//  effect on the unclaimed tile is the positive result waited for. The claimed
//  tile still being there afterwards is the assertion. Both actions hand their
//  work back as a task and the test awaits it, so the destructive sweep is
//  ordered before the assertions rather than racing them; `nil` is the refusal
//  itself, and a refusal queues nothing.
//
//  The sidecar half of the same guard is not reachable from here. `Hike`'s tile
//  claim is stored in `HikeLocalState`, whose own fetch is not injectable, so
//  what a test can prove is the hike fetch; the sidecar failure is refused by
//  type, through `Hike.tileClaim()` throwing where the passthroughs answer "no
//  tiles". `docs/CODE_REVIEW.md` records that as an unobserved claim.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// The failure a `ModelContext` cannot be made to produce.
private struct ClaimFetchFailure: Error {}

@Suite("Settings storage actions under a failed claim fetch")
struct SettingsStorageFailureTests {
    /// The tile a hike claims, and the one nothing does. Both are written into
    /// the durable directory — `OSMTilesSaved` — because that is where the
    /// stakes are: browsing residue is re-fetched for free, while a tile in
    /// there was downloaded on purpose for a walk with no signal.
    private static let claimedKey = "osm/14/8723/5685@2.0"
    private static let strayKey = "osm/14/8724/5685@2.0"

    /// What a red run on this suite means, in the terms the user would meet it.
    private static let emptyClaimSetComment: Comment = """
        The failed claim fetch cleared the cache with an empty claim set. In the app this deletes \
        every tile every hike downloaded for offline use, from a button whose own footer says \
        clearing costs the walker nothing offline.
        """

    /// One hike claiming exactly one of the two tiles on disk.
    private func sandboxWithClaimedTile() throws -> (sandbox: TileSandbox, hike: Hike) {
        let sandbox = TileSandbox()
        try sandbox.save(key: Self.claimedKey)
        try sandbox.save(key: Self.strayKey)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Downloaded for a walk with no signal")
        hike.autoSavedTileKeys = [Self.claimedKey]
        try #require(hike.hasStoredTiles, "a hike claiming nothing cannot witness anything")
        return (sandbox, hike)
    }

    /// The assertion the whole file exists for.
    @Test("a claim fetch that throws clears no tile, not even an unclaimed one")
    func failedClaimFetchClearsNothing() async throws {
        let (sandbox, hike) = try sandboxWithClaimedTile()

        let refused = OfflineStorageActions.clearMapCache(in: sandbox.cache) {
            throw ClaimFetchFailure()
        }
        await refused?.value

        #expect(refused == nil, "a claim fetch that failed must not reach the cache at all")
        #expect(sandbox.isSaved(Self.claimedKey), Self.emptyClaimSetComment)
        #expect(sandbox.isSaved(Self.strayKey), Self.emptyClaimSetComment)

        // The control, in the same test: the stray tile was deletable all
        // along, so the assertions above are about the refusal rather than
        // about a sandbox the sweep could never reach.
        let healthy = try #require(OfflineStorageActions.clearMapCache(in: sandbox.cache) { [hike] })
        await healthy.value

        #expect(!sandbox.isSaved(Self.strayKey))
        #expect(sandbox.isSaved(Self.claimedKey), Self.emptyClaimSetComment)
    }

    /// And the boundary the guard is *not* allowed to blur: a library with no
    /// hikes in it is an honestly empty claim set, and that one does clear.
    /// This is precisely the case a `?? []` makes indistinguishable from a
    /// failure, which is why the distinction lives in the type.
    @Test("a library with no hikes is an honest empty claim, and clears")
    func emptyLibraryStillClears() async throws {
        let sandbox = TileSandbox()
        try sandbox.save(key: Self.strayKey)

        let sweep = try #require(OfflineStorageActions.clearMapCache(in: sandbox.cache) { [] })
        await sweep.value

        #expect(!sandbox.isSaved(Self.strayKey))
    }

    /// The measurement is the same guard seen from the other side, and it is
    /// the brake rather than a cosmetic detail: both buttons in the section are
    /// disabled while `usage` is `nil`, so a claim set that cannot be built
    /// leaves the screen unable to delete anything at all.
    @Test("a claim fetch that throws measures nothing, which disables both buttons")
    func failedClaimFetchMeasuresNothing() {
        let sandbox = TileSandbox()
        let measurement = OfflineStorageActions.measureDiskUsage(in: sandbox.cache) {
            throw ClaimFetchFailure()
        }

        #expect(measurement == nil, "an unmeasurable claim set must not be reported as zero coverage")
    }

    /// "Delete All Saved Tiles" deletes everything by design, so what the fetch
    /// buys it is the other half of its promise: no hike left listing tiles
    /// that are gone. A fetch that failed would clear no manifest, and every
    /// hike sheet would go on reporting offline coverage that no longer exists.
    @Test("a claim fetch that throws deletes no tile and empties no manifest")
    func failedClaimFetchDeletesNothing() async throws {
        let (sandbox, hike) = try sandboxWithClaimedTile()

        let refused = OfflineStorageActions.deleteAllTiles(in: sandbox.cache) {
            throw ClaimFetchFailure()
        }
        await refused?.value

        #expect(refused == nil, "a claim fetch that failed must not reach the cache at all")
        #expect(sandbox.isSaved(Self.claimedKey))
        #expect(sandbox.isSaved(Self.strayKey))
        #expect(
            hike.autoSavedTileKeys == [Self.claimedKey],
            "a manifest emptied beside tiles that survived claims coverage the device no longer has"
        )

        let healthy = try #require(OfflineStorageActions.deleteAllTiles(in: sandbox.cache) { [hike] })
        await healthy.value

        #expect(!sandbox.isSaved(Self.claimedKey))
        #expect(!sandbox.isSaved(Self.strayKey))
        #expect(hike.autoSavedTileKeys.isEmpty)
    }
}
