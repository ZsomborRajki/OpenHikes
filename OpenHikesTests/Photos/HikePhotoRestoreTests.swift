//
//  HikePhotoRestoreTests.swift
//  OpenHikesTests
//
//  A saved copy of a Wikimedia Commons photograph whose file is not on this
//  device — after a reinstall, or on the hiker's other device — is downloaded
//  again where it is shown, and kept. Everything else whose file is missing
//  reads as it did: the hiker's own photographs are on the device they were
//  added on, and nothing asks for them.
//
//  Driven through ``HikePhotoLoader`` with a store of its own, rooted in a
//  temporary directory, and Commons answering from ``CommonsRefetchStub``.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Hike photo restore", .timeLimit(.minutes(1)))
struct HikePhotoRestoreTests {
    nonisolated private final class Sandbox: Sendable {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-restore-\(UUID().uuidString)", isDirectory: true)

        func store(asking commons: CommonsRefetchStub?) -> HikePhotoStore {
            HikePhotoStore(
                storageRoot: root,
                commons: commons.map { CommonsPhotoRefetch(transport: $0.transport) }
            )
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// A Commons copy as ``CommunityImport`` saves one: a JPEG row carrying
    /// the licence and the page it came from — and here, no file.
    private static func commonsCopy(page: String = "https://commons.wikimedia.org/wiki/File:Lac_glacier.jpg")
        -> HikePhoto {
        HikePhoto(
            importedAuthorName: "A hiker",
            license: HikePhotoLicense(
                name: "CC BY-SA 4.0",
                url: URL(string: "https://creativecommons.org/licenses/by-sa/4.0"),
                sourceURL: URL(string: page) ?? URL(filePath: "/")
            )
        )
    }

    private static func unavailability(_ display: PhotoDisplay) -> PhotoUnavailability? {
        guard case .unavailable(let reason) = display else { return nil }
        return reason
    }

    private static func isReady(_ display: PhotoDisplay) -> Bool {
        if case .ready = display { return true }
        return false
    }

    @Test("a Commons copy whose file has gone is downloaded again, drawn and kept")
    func goneCopyIsDownloadedAgain() async {
        let sandbox = Sandbox()
        let commons = CommonsRefetchStub()
        let store = sandbox.store(asking: commons)
        let photo = Self.commonsCopy()

        let thumbnail = await HikePhotoLoader.thumbnail(for: photo, in: store)

        #expect(Self.isReady(thumbnail))
        #expect(commons.questions == [["Lac_glacier.jpg"]])
        #expect(FileManager.default.fileExists(atPath: store.url(for: photo).path))
        // Kept: the viewer reads the file now on disk and asks nothing more.
        #expect(Self.isReady(await HikePhotoLoader.display(for: photo, in: store)))
        #expect(commons.requests.count == 2)
    }

    @Test("a copy Commons no longer offers says so")
    func copyCommonsNoLongerOffers() async {
        let sandbox = Sandbox()
        let commons = CommonsRefetchStub()
        commons.gone("Lac_glacier.jpg")

        let display = await HikePhotoLoader.display(for: Self.commonsCopy(), in: sandbox.store(asking: commons))

        #expect(Self.unavailability(display) == .goneFromCommons)
    }

    @Test("a copy that could not be downloaded just now says so, and comes when asked again")
    func copyNotDownloadedYet() async {
        let sandbox = Sandbox()
        let commons = CommonsRefetchStub()
        commons.refuseQuestions(true)
        let store = sandbox.store(asking: commons)
        let photo = Self.commonsCopy()

        #expect(Self.unavailability(await HikePhotoLoader.display(for: photo, in: store)) == .notDownloaded)
        commons.refuseQuestions(false)
        #expect(Self.isReady(await HikePhotoLoader.display(for: photo, in: store)))
    }

    @Test("a copy whose page names no file on Commons is gone, and nothing is asked")
    func copyWithoutAFilePageIsGone() async {
        let sandbox = Sandbox()
        let commons = CommonsRefetchStub()
        let photo = Self.commonsCopy(page: "https://commons.wikimedia.org/wiki/Category:Glaciers")

        let display = await HikePhotoLoader.thumbnail(for: photo, in: sandbox.store(asking: commons))

        #expect(Self.unavailability(display) == .goneFromCommons)
        #expect(commons.requests.isEmpty)
    }

    @Test("the hiker's own photograph is never asked for")
    func ownPhotographIsNotAskedFor() async {
        let sandbox = Sandbox()
        let commons = CommonsRefetchStub()

        let display = await HikePhotoLoader.thumbnail(for: HikePhoto(), in: sandbox.store(asking: commons))

        #expect(Self.unavailability(display) == .notOnThisDevice)
        #expect(commons.requests.isEmpty)
    }

    @Test("a launch with nowhere to ask reads a missing copy as on another device")
    func launchWithoutCommonsAsksNothing() async {
        let sandbox = Sandbox()

        let display = await HikePhotoLoader.display(for: Self.commonsCopy(), in: sandbox.store(asking: nil))

        #expect(Self.unavailability(display) == .notOnThisDevice)
    }
}
