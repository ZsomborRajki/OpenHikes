//
//  LaunchPhotoReclaimFailureTests.swift
//  OpenHikesTests
//
//  "Launch photo reclaim under a failed claim fetch", split out of
//  LaunchSweepFailureTests.swift so that a file declares one @Suite. That
//  file's header still holds the context the two share.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

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
            throw LaunchClaimFetchFailure()
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
