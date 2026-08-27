//
//  SharedStoreAtomicityTests.swift
//  OpenHikesSharedTests
//
//  Every write in SharedStore passes `options: .atomic`, which is the whole of
//  this type's answer to a hazard that is cross-process and so beyond any
//  in-process isolation: the widget extension reads the same files the app is
//  writing, in a different process, at a moment neither controls. These tests
//  hold that answer in place.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Shared store atomicity")
struct SharedStoreAtomicityTests {
    /// The observable signature of `Data.write(options: .atomic)` is that it
    /// writes a temporary file and renames it over the target, so the target
    /// gets a *new* inode. An in-place rewrite — `options: []` — keeps the
    /// inode and truncates first, which is the window a concurrent reader
    /// falls into. Asserting on the inode is what makes this deterministic:
    /// it fails on the very first run of any write path that drops `.atomic`,
    /// rather than only on the run where a reader happened to be looking.
    @Test("replacing a trail snapshot swaps the file rather than rewriting it in place")
    func trailSaveReplacesTheFile() throws {
        try withSharedStoreSandbox { root in
            let url = root.appendingPathComponent(SharedStoreSandbox.trailFileName)
            SharedStore.save(SharedStoreSandbox.trailSnapshot(title: "First", pointCount: 400))
            let before = try inode(of: url)

            SharedStore.save(SharedStoreSandbox.trailSnapshot(title: "Second", pointCount: 4))

            #expect(try inode(of: url) != before)
            #expect(SharedStore.load()?.title == "Second")
        }
    }

    @Test("replacing a recording snapshot swaps the file rather than rewriting it in place")
    func recordingSaveReplacesTheFile() throws {
        try withSharedStoreSandbox { root in
            let url = root.appendingPathComponent(SharedStoreSandbox.recordingFileName)
            let session = UUID()
            try SharedStore.saveRecording(
                SharedStoreSandbox.recordingSnapshot(sessionID: session, pointCount: 400)
            )
            let before = try inode(of: url)

            try SharedStore.saveRecording(
                SharedStoreSandbox.recordingSnapshot(sessionID: session, pointCount: 4)
            )

            #expect(try inode(of: url) != before)
            #expect(SharedStore.loadRecording()?.pointCount == 4)
        }
    }

    @Test("replacing a basemap manifest swaps the file rather than rewriting it in place")
    func basemapSetSaveReplacesTheFile() throws {
        try withSharedStoreSandbox { root in
            let url = root.appendingPathComponent(SharedStoreSandbox.basemapSetFileName)
            let hike = UUID()
            SharedStore.saveBasemapSet(
                SharedStoreSandbox.basemapSet(hikeID: hike, fileNames: ["a.png", "b.png", "c.png"])
            )
            let before = try inode(of: url)

            SharedStore.saveBasemapSet(SharedStoreSandbox.basemapSet(hikeID: hike, fileNames: ["a.png"]))

            #expect(try inode(of: url) != before)
            #expect(SharedStore.loadBasemapSet(for: hike)?.images.count == 1)
        }
    }

    /// The one that matters most in the field: a basemap is hundreds of KB, so
    /// its write is the longest window in the container, and the widget draws
    /// whatever bytes it finds. A half-written PNG is a broken image, not a
    /// missing one, and the fallback to the line-only glyph never fires.
    @Test("rewriting a basemap image swaps the file rather than rewriting it in place")
    func basemapImageWriteReplacesTheFile() throws {
        try withSharedStoreSandbox { root in
            let url = root
                .appendingPathComponent(SharedStoreSandbox.basemapDirectoryName, isDirectory: true)
                .appendingPathComponent("a.png")
            #expect(SharedStore.writeBasemapImage(Data(repeating: 0xAB, count: 64_000), named: "a.png"))
            let before = try inode(of: url)

            #expect(SharedStore.writeBasemapImage(Data(repeating: 0xCD, count: 32), named: "a.png"))

            #expect(try inode(of: url) != before)
            #expect(SharedStore.basemapImageData(named: "a.png")?.count == 32)
        }
    }

    /// Corroborates the inode tests empirically. A reader loop runs beside a
    /// writer loop that alternates between a large payload and a tiny one — so
    /// every write both shrinks and grows the file, which is when an in-place
    /// rewrite tears worst — and every observation must be one whole snapshot
    /// or the other. Never a `nil`, which is what a decode of half a file
    /// produces, and never a mix.
    ///
    /// Bounded loops rather than a spin on a shared "writer finished" flag:
    /// neither side suspends, so a flag would deadlock a single-core runner
    /// where the writer never gets scheduled. The deterministic proof lives in
    /// the inode tests above; this one is the corroboration.
    @Test("a reader beside a writer never sees a mix of old and new bytes")
    func concurrentReaderSeesWholeSnapshots() async throws {
        try await withSharedStoreSandbox { root in
            let url = root.appendingPathComponent(SharedStoreSandbox.trailFileName)
            let big = SharedStoreSandbox.trailSnapshot(title: "Big", pointCount: 4000)
            let small = SharedStoreSandbox.trailSnapshot(title: "Small", pointCount: 2)
            SharedStore.save(big)

            async let writes: Int = {
                for index in 0 ..< 400 { SharedStore.save(index.isMultiple(of: 2) ? small : big) }
                return 400
            }()
            async let observations: [String?] = {
                (0 ..< 600).map { _ in SharedStore.load()?.title }
            }()

            let (written, seen) = await (writes, observations)
            #expect(written == 400)
            #expect(seen.count == 600)
            #expect(seen.allSatisfy { $0 == "Big" || $0 == "Small" })

            // Proves the check above is not vacuous: the same classification
            // reports a torn file as torn, so `allSatisfy` passing means the
            // reader really never met one.
            let encoded = try JSONEncoder().encode(big)
            try Data(encoded.prefix(encoded.count / 2)).write(to: url)
            #expect(SharedStore.load()?.title == nil)
        }
    }

    /// `pruneBasemapImages(keeping:)` sweeps the directory by exclusion, so a
    /// render writing its own files while another prune runs would lose them.
    /// `removeBasemapImages(named:)` exists for that case and names what it
    /// deletes; the two are one line apart and easy to reach for wrongly.
    @Test("pruning keeps exactly what it was told to keep")
    func pruningKeepsNamedImages() throws {
        try withSharedStoreSandbox { _ in
            for name in ["keep.png", "drop-a.png", "drop-b.png"] {
                SharedStore.writeBasemapImage(Data("x".utf8), named: name)
            }

            SharedStore.pruneBasemapImages(keeping: ["keep.png"])

            #expect(SharedStore.basemapImageData(named: "keep.png") != nil)
            #expect(SharedStore.basemapImageData(named: "drop-a.png") == nil)
            #expect(SharedStore.basemapImageData(named: "drop-b.png") == nil)
        }
    }

    @Test("removing by name leaves a concurrent render's files alone")
    func removingByNameSparesOthers() throws {
        try withSharedStoreSandbox { _ in
            for name in ["mine-a.png", "mine-b.png", "theirs.png"] {
                SharedStore.writeBasemapImage(Data("x".utf8), named: name)
            }

            SharedStore.removeBasemapImages(named: ["mine-a.png", "mine-b.png"])

            #expect(SharedStore.basemapImageData(named: "mine-a.png") == nil)
            #expect(SharedStore.basemapImageData(named: "mine-b.png") == nil)
            #expect(SharedStore.basemapImageData(named: "theirs.png") != nil)
        }
    }

    private func inode(of url: URL) throws -> UInt64 {
        var info = stat()
        let status = stat(url.path(percentEncoded: false), &info)
        try #require(status == 0, "expected a file at \(url.lastPathComponent)")
        return UInt64(info.st_ino)
    }
}
