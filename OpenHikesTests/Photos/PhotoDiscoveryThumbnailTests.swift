//
//  PhotoDiscoveryThumbnailTests.swift
//  OpenHikesTests
//
//  What a review-grid cell's thumbnail read may do once its task has been
//  cancelled, which is nothing (#1351).
//
//  PhotoKit finishes a request whatever happens to the task that made it,
//  and SwiftUI cancels a `.task(id:)` it replaces and starts the next one at
//  once, without waiting. So a cell scrolled away and back has two reads in
//  flight, and the older one's answer — the same picture, or the `nil` of a
//  request that failed — can land after the newer one has been drawn, and
//  stays, because the newer task has finished.
//
//  The read is held by a library that answers from memory and waits at one
//  asset until the test opens it: the only way to be sure the cancellation
//  arrives *during* a read rather than before it.
//

@testable import OpenHikes
import OpenHikesData
import Testing

#if canImport(UIKit)
import UIKit
#endif

@Suite("Photo discovery thumbnails after cancellation", .timeLimit(.minutes(1)))
struct PhotoDiscoveryThumbnailTests {
    /// A library whose thumbnails answer from memory, with one asset's held,
    /// once it has been asked for, until its gate opens.
    nonisolated final class HeldThumbnails: PhotoLibraryReading {
        let gate = TestGate()
        private let held: String
        private let pictures: [String: LoadedPhotoImage]

        init(pictures: [String: LoadedPhotoImage], holding held: String) {
            self.pictures = pictures
            self.held = held
        }

        func thumbnail(for localIdentifier: String, maxPixelSize: Int) async -> LoadedPhotoImage? {
            if localIdentifier == held { await gate.wait() }
            return pictures[localIdentifier]
        }

        // swiftlint:disable async_without_await
        func requestAccess() async -> PhotoLibraryAccess { .granted }
        func currentAccess() -> PhotoLibraryAccess { .granted }
        func assets(takenIn window: ClosedRange<Date>) async -> [PhotoLibraryAsset] { [] }
        @MainActor
        func presentLimitedLibraryPicker(from _: LimitedLibraryPresenter) async { /* no screen to present on */ }
        func imageData(for localIdentifier: String) async -> Data? { nil }
        // swiftlint:enable async_without_await
    }

    /// Everything a cell was handed, in order.
    final class Shown {
        private(set) var answers: [LoadedPhotoImage?] = []

        func record(_ answer: LoadedPhotoImage?) { answers.append(answer) }
    }

    /// A picture of its own, so an assertion can say whose it is.
    private static func picture() -> LoadedPhotoImage {
        #if canImport(UIKit)
        LoadedPhotoImage(image: UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        })
        #else
        LoadedPhotoImage(image: PhotoImage())
        #endif
    }

    private static func match(_ identifier: String) -> LibraryPhotoMatch {
        LibraryPhotoMatch(
            asset: PhotoDiscoveryFixture.asset(identifier, atStep: 0),
            latitude: PhotoDiscoveryFixture.latitude,
            longitude: PhotoDiscoveryFixture.longitude,
            evidence: .time,
            secondsFromFix: 0
        )
    }

    /// An older read held in PhotoKit, a replacement that finishes first, and
    /// then the older one let go. The replacement's picture is what stays,
    /// and the older read hands over nothing at all.
    @Test("a replacement's thumbnail outlasts the cancelled read it replaced")
    func replacementOutlastsTheReadItReplaced() async {
        let newerPicture = Self.picture()
        let library = HeldThumbnails(
            pictures: ["older": Self.picture(), "newer": newerPicture],
            holding: "older"
        )
        defer { library.gate.open() }
        let controller = PhotoDiscoveryController(reader: library)
        let shown = Shown()

        let replaced = Task { await controller.thumbnail(for: Self.match("older")) { shown.record($0) } }
        await settleDelegateHop(until: "the older read to be under way") { library.gate.isHolding }
        // What `.task(id:)` does when the cell goes and comes back: cancel,
        // and start the next without waiting for the last.
        replaced.cancel()
        await controller.thumbnail(for: Self.match("newer")) { shown.record($0) }
        library.gate.open()
        await replaced.value

        #expect(shown.answers.count == 1, "only the replacement hands over a picture")
        #expect(shown.answers.last??.image === newerPicture.image)
    }
}
