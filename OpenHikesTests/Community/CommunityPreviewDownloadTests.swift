//
//  CommunityPreviewDownloadTests.swift
//  OpenHikesTests
//
//  When a preview's downloads are allowed to go, and what must have finished
//  first.
//
//  These are somebody else's photographs, held for as long as the screen
//  showing them and no longer — which cuts both ways, and the second way is
//  the one that was wrong. Deleting the directory while the *import* is
//  reading out of it costs the hiker the pictures of a hike they asked for;
//  deleting it while the *download* is still writing into it leaves files
//  behind instead, because the writer re-creates the directory after the
//  remove and nothing ever comes back for it.
//
//  Asserted against the ordering rather than against the view, for the reason
//  `CommunityPhotoPairingTests` is `CKRecord`-free: what is worth pinning is
//  invisible in the result. A discard that waited and a discard that raced
//  both leave no directory on a good day.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@MainActor
@Suite("Community preview downloads")
struct CommunityPreviewDownloadTests {
    /// A directory with a file in it, so a premature remove is something a
    /// test can see rather than something it has to infer.
    private func downloadDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommunityHikeTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: directory.appendingPathComponent("photo-0.jpeg"))
        return directory
    }

    private func exists(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.path)
    }

    /// The discard is fire-and-forget off a detached task, so this waits for
    /// the directory to go rather than for a length of time — the same shape
    /// `CommunityStagingTests` waits for a staging directory in.
    private func settleRemoval(of directory: URL) async {
        await settleDelegateHop(until: "the download directory to be deleted") {
            !exists(directory)
        }
    }

    /// The reported bug. Backing out mid-download left the load running: the
    /// remove landed first, and the download then re-created the directory and
    /// wrote a stranger's photographs into it, where nothing would ever
    /// collect them.
    @Test("a download still running holds the directory open")
    func anUnfinishedDownloadDelaysTheRemoval() async throws {
        let directory = try downloadDirectory()
        let gate = AsyncGate()
        let download = Task { await gate.wait() }

        CommunityHikeView.discardDownloads(at: directory, after: [download, nil])

        await settleDelegateHop(until: "the discard to have had a chance to run")
        #expect(exists(directory), "the directory went while a download was still writing into it")

        await gate.open()
        await settleRemoval(of: directory)
        #expect(!exists(directory))
    }

    /// The half that was already right, and must stay right: the import is
    /// reading a stranger's photographs out of here, and deleting underneath
    /// it costs the hiker the pictures of a hike they asked for.
    @Test("an import still running holds the directory open")
    func anUnfinishedImportDelaysTheRemoval() async throws {
        let directory = try downloadDirectory()
        let gate = AsyncGate()
        let importing = Task { await gate.wait() }

        CommunityHikeView.discardDownloads(at: directory, after: [nil, importing])

        await settleDelegateHop(until: "the discard to have had a chance to run")
        #expect(exists(directory))

        await gate.open()
        await settleRemoval(of: directory)
        #expect(!exists(directory))
    }

    /// Both at once is the ordinary shape of leaving a screen mid-import, and
    /// neither one finishing is enough on its own.
    @Test("the directory outlives whichever finishes first")
    func bothMustFinishBeforeTheRemoval() async throws {
        let directory = try downloadDirectory()
        let downloadGate = AsyncGate()
        let importGate = AsyncGate()
        let download = Task { await downloadGate.wait() }
        let importing = Task { await importGate.wait() }

        CommunityHikeView.discardDownloads(at: directory, after: [download, importing])

        await downloadGate.open()
        await settleDelegateHop(until: "the discard to have had a chance to run")
        #expect(exists(directory), "one of the two finishing is not enough")

        await importGate.open()
        await settleRemoval(of: directory)
        #expect(!exists(directory))
    }

    /// A preview the hiker backed out of before anything started, which is the
    /// common case and must not wait on anything.
    @Test("nothing in flight removes the directory at once")
    func nothingPendingRemovesImmediately() async throws {
        let directory = try downloadDirectory()

        CommunityHikeView.discardDownloads(at: directory, after: [nil, nil])

        await settleRemoval(of: directory)
        #expect(!exists(directory))
    }
}
