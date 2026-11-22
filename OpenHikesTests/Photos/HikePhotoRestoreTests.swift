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
import Synchronization
import Testing

#if canImport(UIKit)
import UIKit
#endif

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
    /// the licence, the page it came from and the revision it was made from —
    /// and here, no file.
    private static func commonsCopy() -> HikePhoto {
        CommonsRefetchStub.copy(of: "Lac_glacier.jpg")
    }

    /// Reads that find no file the first time and the picture after it, as a
    /// viewer does when the strip's download lands between its read and its
    /// look at the disk.
    nonisolated private final class ArrivingReads: HikePhotoReading {
        private let reads = Mutex(0)
        private let image: PhotoImage?

        init() {
            #if canImport(UIKit)
            image = UIImage(data: CommonsRefetchStub.thumbnail)
            #else
            image = nil
            #endif
        }

        func thumbnail(for photo: HikePhoto) -> PhotoImage? { read() }
        func displayImage(for photo: HikePhoto) -> PhotoImage? { read() }
        func hasImage(for photo: HikePhoto) -> Bool { true }

        private func read() -> PhotoImage? {
            reads.withLock { count in
                count += 1
                return count == 1 ? nil : image
            }
        }
    }

    /// What deleting a photograph does to its files, off the main actor as
    /// the store requires.
    @concurrent
    private static func remove(_ photo: HikePhoto, from store: HikePhotoStore) async {
        store.remove([HikePhotoStore.PhotoFiles(photo)])
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
        var photo = Self.commonsCopy()
        photo.license?.sourceURL = URL(string: "https://commons.wikimedia.org/wiki/Category:Glaciers")
            ?? URL(filePath: "/")

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

    @Test("a photograph removed while its download was on its way is not written back")
    func removalWinsOverALateDownload() async {
        let sandbox = Sandbox()
        let commons = CommonsRefetchStub(holdingFirstQuestion: true)
        let store = sandbox.store(asking: commons)
        let photo = Self.commonsCopy()

        let load = Task { await HikePhotoLoader.display(for: photo, in: store) }
        await settleDelegateHop(until: "the question is out") { commons.isHoldingQuestion }
        // The viewer's trash: the page goes away, and the files with it.
        load.cancel()
        await Self.remove(photo, from: store)
        commons.answerHeldQuestion()
        _ = await load.value

        #expect(commons.downloads.count == 1)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: photo).path))
    }

    @Test("a file that arrived after the read failed is read again rather than called unreadable")
    func arrivingFileIsReadAgain() async {
        #expect(Self.isReady(await HikePhotoLoader.display(for: Self.commonsCopy(), in: ArrivingReads())))
    }

    @Test("a launch with nowhere to ask reads a missing copy as on another device")
    func launchWithoutCommonsAsksNothing() async {
        let sandbox = Sandbox()

        let display = await HikePhotoLoader.display(for: Self.commonsCopy(), in: sandbox.store(asking: nil))

        #expect(Self.unavailability(display) == .notOnThisDevice)
    }
}
