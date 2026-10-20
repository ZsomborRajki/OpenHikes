//
//  TrailDraftPhotoCopyTests.swift
//  OpenHikesTests
//
//  What a drawn trail's save does with the Commons photographs it could not
//  copy: holds them with their files, copies only those on *Try Again*, and
//  deletes the files once nothing is left to copy or the hiker skips them.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import SwiftUI
import Testing

@MainActor
@Suite("Trail draft photo copy")
struct TrailDraftPhotoCopyTests {
    private struct Refusal: Error {}

    /// A save that refuses the attempts it is told to, counted from one, and
    /// passes the rest through to the store.
    nonisolated private final class Saves {
        var refused: Set<Int> = []
        private(set) var count = 0

        func save(_ context: ModelContext) throws {
            count += 1
            if refused.contains(count) { throw Refusal() }
            try context.save()
        }
    }

    /// A hand-off of `count` photographs along the fixture's line, each with
    /// a real image on disk in a directory of its own.
    static func handOff(of count: Int) throws -> TrailDraftPhotoHandOff {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrailDraftPhotoCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photos = try (0..<count).map { index in
            let photo = CommonsPhoto(
                pin: CommunityPhotoPin(
                    capturedAt: Date(timeIntervalSince1970: 1_600_000_000),
                    coordinate: Fixture.ridgeRoute[index + 1].clCoordinate
                ),
                fileURL: directory.appendingPathComponent("commons-\(index).jpeg"),
                credit: CommonsPhotoCredit(
                    author: "Hiker \(index)",
                    license: HikePhotoLicense(
                        name: "CC BY-SA 4.0",
                        url: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/"),
                        sourceURL: URL(string: "https://commons.wikimedia.org/wiki/File:\(index).jpg")
                            ?? URL(filePath: "/")
                    )
                )
            )
            try PhotoDiscoveryFixture.sampleImageData().write(to: photo.fileURL)
            return photo
        }
        return TrailDraftPhotoHandOff(photos: photos, directory: directory)
    }

    private static func gone(_ url: URL) async {
        await settleDelegateHop(until: "the hand-off directory was deleted") {
            !FileManager.default.fileExists(atPath: url.path)
        }
    }

    @Test("a copy that misses nothing holds nothing and deletes the files")
    func nothingMissed() async throws {
        let sandbox = PhotoStoreSandbox()
        let copy = TrailDraftPhotoCopy(store: sandbox.store, libraryWriter: StubPhotoLibraryWriter())
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let handOff = try Self.handOff(of: 2)

        await copy.attach(handOff, to: hike).value

        #expect(hike.photos.count == 2)
        #expect(copy.missed == nil)
        await Self.gone(handOff.directory)
    }

    @Test("a refused save is held for the alert, with the file a retry needs")
    func missedIsHeld() async throws {
        let sandbox = PhotoStoreSandbox()
        let saves = Saves()
        saves.refused = [2]
        let copy = TrailDraftPhotoCopy(store: sandbox.store, libraryWriter: StubPhotoLibraryWriter(), save: saves.save)
        defer { copy.skip() }
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "Ridge Loop")
        let handOff = try Self.handOff(of: 2)

        await copy.attach(handOff, to: hike).value

        #expect(hike.photos.map(\.importedAuthorName) == ["Hiker 0"])
        let missed = try #require(copy.missed)
        #expect(missed.hikeTitle == "Ridge Loop")
        #expect(missed.photos.photos.map(\.credit.author) == ["Hiker 1"])
        #expect(copy.isShowing)
        let file = try #require(missed.photos.photos.first?.fileURL)
        #expect(FileManager.default.fileExists(atPath: file.path), "kept for Try Again")
    }

    @Test("Try Again copies only what was missed, then deletes the files")
    func retryCopiesTheMissed() async throws {
        let sandbox = PhotoStoreSandbox()
        let saves = Saves()
        saves.refused = [2]
        let copy = TrailDraftPhotoCopy(store: sandbox.store, libraryWriter: StubPhotoLibraryWriter(), save: saves.save)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let handOff = try Self.handOff(of: 2)
        await copy.attach(handOff, to: hike).value
        let savesBeforeRetry = saves.count

        await copy.retry()?.value

        #expect(saves.count == savesBeforeRetry + 1, "one save, for the one photograph missing")
        #expect(Set(hike.photos.compactMap(\.importedAuthorName)) == ["Hiker 0", "Hiker 1"])
        #expect(copy.missed == nil)
        #expect(!copy.isShowing)
        await Self.gone(handOff.directory)
    }

    @Test("a retry the save refuses again comes back as a new alert")
    func retryRefusedAgain() async throws {
        let sandbox = PhotoStoreSandbox()
        let saves = Saves()
        saves.refused = [1, 2]
        let copy = TrailDraftPhotoCopy(store: sandbox.store, libraryWriter: StubPhotoLibraryWriter(), save: saves.save)
        defer { copy.skip() }
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        await copy.attach(try Self.handOff(of: 1), to: hike).value

        await copy.retry()?.value

        #expect(hike.photos.isEmpty)
        #expect(copy.missed?.photos.photos.count == 1)
    }

    @Test("Skip lets the missed photographs go, and their files")
    func skipDeletesTheFiles() async throws {
        let sandbox = PhotoStoreSandbox()
        let saves = Saves()
        saves.refused = [1]
        let copy = TrailDraftPhotoCopy(store: sandbox.store, libraryWriter: StubPhotoLibraryWriter(), save: saves.save)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let handOff = try Self.handOff(of: 1)
        await copy.attach(handOff, to: hike).value
        #expect(copy.missed != nil)

        copy.skip()

        #expect(copy.missed == nil)
        #expect(copy.retry() == nil, "nothing left to try again")
        await Self.gone(handOff.directory)
    }

    @Test("a hike deleted before Try Again takes nothing, and the files go")
    func deletedHikeKeepsNothing() async throws {
        let sandbox = PhotoStoreSandbox()
        let saves = Saves()
        saves.refused = [1]
        let copy = TrailDraftPhotoCopy(store: sandbox.store, libraryWriter: StubPhotoLibraryWriter(), save: saves.save)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let handOff = try Self.handOff(of: 1)
        await copy.attach(handOff, to: hike).value

        context.delete(hike)
        try context.save()
        await copy.retry()?.value

        #expect(copy.missed == nil)
        await Self.gone(handOff.directory)
    }

    @Test("a later save keeps both trails' missed photographs until each is answered")
    func laterMissesWait() async throws {
        let sandbox = PhotoStoreSandbox()
        let saves = Saves()
        saves.refused = [1, 2]
        let copy = TrailDraftPhotoCopy(store: sandbox.store, libraryWriter: StubPhotoLibraryWriter(), save: saves.save)
        let context = try Fixture.modelContext()
        let first = try Self.handOff(of: 1)
        await copy.attach(first, to: Fixture.hike(in: context, title: "First")).value

        let second = try Self.handOff(of: 1)
        await copy.attach(second, to: Fixture.hike(in: context, title: "Second")).value

        #expect(copy.missed?.hikeTitle == "First")
        #expect(FileManager.default.fileExists(atPath: first.directory.path))
        #expect(FileManager.default.fileExists(atPath: second.directory.path))
        copy.skip()
        #expect(copy.missed?.hikeTitle == "Second")
        await Self.gone(first.directory)
        #expect(FileManager.default.fileExists(atPath: second.directory.path))
        copy.skip()
        #expect(copy.missed == nil)
        await Self.gone(second.directory)
    }

    @Test("a source that cannot be read is reported and can be restored for a retry")
    func unreadableSourceIsReported() async throws {
        let sandbox = PhotoStoreSandbox()
        let copy = TrailDraftPhotoCopy(store: sandbox.store, libraryWriter: StubPhotoLibraryWriter())
        defer { copy.skip() }
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let handOff = try Self.handOff(of: 2)
        let file = try #require(handOff.photos.first?.fileURL)
        try FileManager.default.removeItem(at: file)

        await copy.attach(handOff, to: hike).value

        #expect(hike.photos.count == 1)
        let missed = try #require(copy.missed)
        #expect(missed.photos.photos.map(\.fileURL) == [file])
        try PhotoDiscoveryFixture.sampleImageData().write(to: file)
        await copy.retry()?.value

        #expect(hike.photos.count == 2)
        #expect(copy.missed == nil)
        await Self.gone(handOff.directory)
    }

    @Test("a retry and a later save cannot attach the same Commons page twice")
    func overlappingRetryAndSave() async throws {
        let sandbox = PhotoStoreSandbox()
        let saves = Saves()
        saves.refused = [1]
        let copy = TrailDraftPhotoCopy(store: sandbox.store, libraryWriter: StubPhotoLibraryWriter(), save: saves.save)
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let first = try Self.handOff(of: 1)
        await copy.attach(first, to: hike).value
        let second = try Self.handOff(of: 1)

        let retry = try #require(copy.retry())
        let later = copy.attach(second, to: hike)
        await retry.value
        await later.value

        #expect(hike.photos.count == 1)
        #expect(copy.missed == nil)
        await Self.gone(first.directory)
        await Self.gone(second.directory)
    }
}
