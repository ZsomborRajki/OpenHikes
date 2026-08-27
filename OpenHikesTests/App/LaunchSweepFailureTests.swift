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
private struct ClaimFetchFailure: Error {}

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
            throw ClaimFetchFailure()
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

/// A photo store rooted in its own directory. Never `HikePhotoStore.shared`,
/// which writes into the host app's Application Support — and these tests
/// delete files on purpose.
///
/// A class rather than a value type so `deinit` does the cleanup, the same
/// arrangement ``TileSandbox`` uses and for the same reason.
nonisolated private final class ReclaimSandbox: Sendable {
    /// Comfortably past ``HikePhotoStore/reclaimOrphans(claimedBy:youngerThan:now:)``'s
    /// grace period, which exists so a photo being written right now is not
    /// mistaken for an orphan. A file left inside it is never a witness to
    /// anything.
    private static let pastTheGracePeriod: TimeInterval = 600

    let root: URL
    let store: HikePhotoStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reclaim-sandbox-\(UUID().uuidString)", isDirectory: true)
        store = HikePhotoStore(storageRoot: root)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes `name` and back-dates it out of the grace period, so the reclaim
    /// would delete it if nothing claimed it.
    func writeAgedFile(_ name: String) throws {
        let url = store.directory.appendingPathComponent(name)
        try Data("photo bytes".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -Self.pastTheGracePeriod)],
            ofItemAtPath: url.path
        )
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(name).path)
    }
}

/// One hike claiming exactly one of two files on disk.
private struct ClaimedPhotoFixture {
    let sandbox: ReclaimSandbox
    let hike: Hike
    /// The file the hike's photo occupies, which no sweep may ever delete
    /// while that hike exists.
    let claimed: String
    /// The file nothing points at, and the witness that a sweep ran at all.
    let stray: String
}

@Suite("Launch photo reclaim under a failed claim fetch")
struct LaunchPhotoReclaimFailureTests {
    /// What a red run on this suite means, in the terms the user would meet it.
    private static let emptyClaimSetComment: Comment = """
        The failed claim fetch swept with an empty claim set. In the app this deletes every \
        photo file on the device, at launch, while the hikes that referenced them stay in the \
        library pointing at nothing.
        """

    /// A hike holding one photo, with that photo's file on disk beside a stray
    /// one that nothing claims.
    private func sandboxWithClaimedPhoto() throws -> ClaimedPhotoFixture {
        let sandbox = try ReclaimSandbox()
        let context = try Fixture.modelContext()
        let photo = HikePhoto()
        let hike = Fixture.hike(in: context, title: "Holds the only claim on a file")
        hike.photos.append(photo)
        let stray = "\(UUID().uuidString).jpg"
        try sandbox.writeAgedFile(photo.fileName)
        try sandbox.writeAgedFile(stray)
        return ClaimedPhotoFixture(sandbox: sandbox, hike: hike, claimed: photo.fileName, stray: stray)
    }

    /// The assertion the whole file exists for, on the photo side.
    ///
    /// The failing sweep's task is awaited before anything on disk is read.
    /// In the correct implementation there is no task — the `guard` is checked
    /// synchronously and nothing is queued — so `nil` is the refusal, and
    /// awaiting it is a no-op. Under a `?? []` there *is* one, and awaiting it
    /// is what puts the destructive sweep before these assertions instead of
    /// somewhere after them. Without that the only detector would be whether
    /// a `.utility` task happened to outrun the `#expect`s below, which is
    /// not a test.
    @Test("a claim fetch that throws deletes no photo, not even an unclaimed one")
    func failedClaimFetchReclaimsNothing() async throws {
        let fixture = try sandboxWithClaimedPhoto()
        let (sandbox, claimed, stray) = (fixture.sandbox, fixture.claimed, fixture.stray)

        let refused = OpenHikesModel.reclaimOrphanedPhotos(from: sandbox.store) {
            throw ClaimFetchFailure()
        }
        await refused?.value

        #expect(refused == nil, "a claim fetch that failed must not reach the store at all")
        #expect(sandbox.exists(claimed), Self.emptyClaimSetComment)
        #expect(sandbox.exists(stray), Self.emptyClaimSetComment)

        let healthy = try #require(
            OpenHikesModel.reclaimOrphanedPhotos(from: sandbox.store) { [fixture.hike] }
        )
        await healthy.value

        // The control, in the same test: these two files were deletable all
        // along, so the assertions above are about the refusal rather than
        // about a sandbox the sweep could never reach.
        #expect(!sandbox.exists(stray))
        #expect(sandbox.exists(claimed), Self.emptyClaimSetComment)
    }

    /// The control, for the same reason as on the tile side.
    @Test("a claim fetch that succeeds still deletes the unclaimed file")
    func healthyClaimFetchReclaimsTheStrayFile() async throws {
        let fixture = try sandboxWithClaimedPhoto()
        let (sandbox, claimed, stray) = (fixture.sandbox, fixture.claimed, fixture.stray)

        let sweep = try #require(
            OpenHikesModel.reclaimOrphanedPhotos(from: sandbox.store) { [fixture.hike] }
        )
        await sweep.value

        #expect(!sandbox.exists(stray))
        #expect(sandbox.exists(claimed))
    }

    /// A hike whose photo has been removed leaves its file behind — deletion
    /// is fire-and-forget, so the sweep is the only thing that ever collects
    /// it. The claim set is honestly empty here, and it sweeps.
    @Test("a library with no photos is an honest empty claim, and reclaims")
    func emptyLibraryStillReclaims() async throws {
        let fixture = try sandboxWithClaimedPhoto()
        let (sandbox, claimed, stray) = (fixture.sandbox, fixture.claimed, fixture.stray)

        let sweep = try #require(OpenHikesModel.reclaimOrphanedPhotos(from: sandbox.store) { [] })
        await sweep.value

        #expect(!sandbox.exists(stray))
        #expect(!sandbox.exists(claimed))
    }
}
