//
//  HikePhotoLoaderCancellationTests.swift
//  OpenHikesTests
//
//  What a photo load cancelled mid-decode is allowed to do afterwards, which
//  is nothing.
//
//  ImageIO's decode cannot be cut short, so a task cancelled while it runs
//  still gets a picture back from the store. ``HikePhotoLoader`` promises the
//  picture is dropped, and until #1335 it was handed back, and the strip's
//  tile and the viewer's page wrote it into their state whoever owned that
//  state by then. SwiftUI cancels a `.task(id:)` it replaces and starts the
//  next one at once, without waiting, so the older answer can land after the
//  newer one — and a picture, or a spinner, drawn over the newer answer stays
//  there, because the newer task has finished.
//
//  The decode is held by a store that answers from memory and waits, once
//  the held read has begun, until the test opens it: the only way to be sure
//  a cancellation arrives *during* a decode rather than before it.
//

import Dispatch
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

#if canImport(UIKit)
import UIKit
#endif

@Suite("Hike photo loads after cancellation", .timeLimit(.minutes(1)))
struct HikePhotoLoaderCancellationTests {
    /// Reads answered from memory, with one photo's read held, once it has
    /// begun, until ``open()``.
    nonisolated final class HeldReads: HikePhotoReading {
        private let images: [UUID: PhotoImage]
        private let held: UUID
        private let entered = Mutex(false)
        private let release = DispatchSemaphore(value: 0)

        init(images: [UUID: PhotoImage], holding held: UUID) {
            self.images = images
            self.held = held
        }

        /// Whether the held read has begun: its decode is under way.
        var isHolding: Bool { entered.withLock { $0 } }

        func open() { release.signal() }

        func thumbnail(for photo: HikePhoto) -> PhotoImage? { read(photo) }
        func displayImage(for photo: HikePhoto) -> PhotoImage? { read(photo) }
        func hasImage(for photo: HikePhoto) -> Bool { images[photo.id] != nil }

        private func read(_ photo: HikePhoto) -> PhotoImage? {
            if photo.id == held {
                entered.withLock { $0 = true }
                release.wait()
            }
            return images[photo.id]
        }
    }

    /// The strip's read and the viewer's, which keep the same promise.
    enum Read: String, CaseIterable, Sendable {
        case thumbnail = "the strip's thumbnail"
        case display = "the viewer's picture"

        func load(_ photo: HikePhoto, from reads: HeldReads) async -> PhotoDisplay {
            switch self {
            case .thumbnail: await HikePhotoLoader.thumbnail(for: photo, in: reads)
            case .display: await HikePhotoLoader.display(for: photo, in: reads)
            }
        }

        func load(_ photo: HikePhoto, from reads: HeldReads, show: (PhotoDisplay) -> Void) async {
            switch self {
            case .thumbnail: await HikePhotoLoader.thumbnail(for: photo, in: reads, show: show)
            case .display: await HikePhotoLoader.display(for: photo, in: reads, show: show)
            }
        }
    }

    /// Everything a view was handed, in order.
    final class Shown {
        private(set) var answers: [PhotoDisplay] = []

        func record(_ answer: PhotoDisplay) { answers.append(answer) }
    }

    /// A picture of its own, so an assertion can say whose it is.
    private static func picture() -> PhotoImage {
        #if canImport(UIKit)
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        #else
        PhotoImage()
        #endif
    }

    private static func picture(in answer: PhotoDisplay?) -> PhotoImage? {
        guard case .ready(let loaded) = answer else { return nil }
        return loaded.image
    }

    /// The loader's own half: what a cancelled task gets back is
    /// ``PhotoDisplay/loading``, the answer for a load that observed nothing
    /// worth showing, rather than the picture the store finished decoding.
    @Test("a decode cancelled while it ran hands back no picture", arguments: Read.allCases)
    func decodeCancelledInFlightHandsBackNothing(read: Read) async {
        let photo = HikePhoto()
        let reads = HeldReads(images: [photo.id: Self.picture()], holding: photo.id)
        defer { reads.open() }

        let load = Task { await read.load(photo, from: reads) }
        await settleDelegateHop(until: "the decode to be under way") { reads.isHolding }
        load.cancel()
        reads.open()
        let answer = await load.value

        if case .loading = answer { return }
        Issue.record("a load cancelled mid-decode handed back \(answer)")
    }

    /// The view's half, as a tile or a page sees it: an older load held in
    /// its decode, a replacement that finishes first, and then the older one
    /// let go. The replacement's picture is what stays — and the older load
    /// hands over nothing at all, not even ``PhotoDisplay/loading``, which
    /// drawn over a finished replacement is a spinner nothing will clear.
    @Test("a replacement's picture outlasts the cancelled load it replaced", arguments: Read.allCases)
    func replacementOutlastsTheLoadItReplaced(read: Read) async {
        let older = HikePhoto()
        let newer = HikePhoto()
        let newerPicture = Self.picture()
        let reads = HeldReads(
            images: [older.id: Self.picture(), newer.id: newerPicture],
            holding: older.id
        )
        defer { reads.open() }
        let shown = Shown()

        let replaced = Task { await read.load(older, from: reads) { shown.record($0) } }
        await settleDelegateHop(until: "the older decode to be under way") { reads.isHolding }
        // What `.task(id:)` does when its id moves on: cancel, and start the
        // next without waiting for the last.
        replaced.cancel()
        await read.load(newer, from: reads) { shown.record($0) }
        reads.open()
        await replaced.value

        #expect(shown.answers.count == 1, "only the replacement hands over an answer")
        #expect(Self.picture(in: shown.answers.last) === newerPicture)
    }
}
