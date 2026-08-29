//
//  HikePhotoDisplayTests.swift
//  OpenHikesTests
//
//  The distinction the viewer hangs on: a photo whose pixels have not been
//  decoded *yet* and one whose pixels are not there at all.
//
//  ``HikePhotoStore/displayImage(for:)`` answers both with `nil`, and the page
//  that reads it used to draw a spinner either way — so a hike listing a photo
//  whose file had gone showed a viewer that never resolved, with no message
//  and nothing to press. ``HikePhotoLoader/display(for:in:)`` is what turns
//  those two into different values, and this suite is what holds them apart.
//
//  Every store here is rooted in a temporary directory, never
//  `HikePhotoStore.shared`: these suites run in parallel with the host app,
//  which writes into the real one.
//

import Foundation
@testable import OpenHikes
import Testing

#if canImport(UIKit)
import UIKit
#endif

@Suite("Hike photo display")
struct HikePhotoDisplayTests {
    nonisolated private static let sampleSide = 8

    /// A store with its own directory, removed when the test ends.
    nonisolated private final class Sandbox: Sendable {
        let root: URL
        let store: HikePhotoStore

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "photo-display-\(UUID().uuidString)",
                    isDirectory: true
                )
            store = HikePhotoStore(storageRoot: root)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// A genuinely decodable PNG — the store asks ImageIO what the bytes are,
    /// so filler wouldn't get past it.
    nonisolated private static func sampleImageData() -> Data {
        #if canImport(UIKit)
        let size = CGSize(width: sampleSide, height: sampleSide)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
        #else
        return Data()
        #endif
    }

    private static func isUnavailable(_ display: PhotoDisplay) -> Bool {
        if case .unavailable = display { return true }
        return false
    }

    private static func isReady(_ display: PhotoDisplay) -> Bool {
        if case .ready = display { return true }
        return false
    }

    @Test("a photo whose file was never written is unavailable, not loading")
    func displayReportsMissingFile() async throws {
        let sandbox = Sandbox()
        // The row a hike keeps after its pixels have gone: valid metadata,
        // nothing on disk under the name it claims.
        let photo = HikePhoto()
        try #require(
            !FileManager.default.fileExists(
                atPath: sandbox.store.url(for: photo).path
            )
        )

        let display = await HikePhotoLoader.display(for: photo, in: sandbox.store)

        #expect(Self.isUnavailable(display))
    }

    @Test("a file that is there but cannot be decoded is unavailable too")
    func displayReportsUnreadableFile() async throws {
        let sandbox = Sandbox()
        let photo = HikePhoto()
        // `install` writes bytes under the name the record already carries and
        // deliberately doesn't sniff them, which is the only way to put a file
        // the decoder will refuse where a photo says its picture is.
        try #require(
            await offMain {
                sandbox.store.install(Data("not a picture".utf8), as: photo)
            }
        )

        let display = await HikePhotoLoader.display(for: photo, in: sandbox.store)

        #expect(Self.isUnavailable(display))
    }

    @Test("a photo whose file is there decodes to an image")
    func displayReturnsTheImage() async throws {
        let sandbox = Sandbox()
        let data = Self.sampleImageData()
        try #require(!data.isEmpty)
        let photo = try #require(
            await offMain { sandbox.store.store(data, capturedAt: .now, coordinate: nil) }
        )

        let display = await HikePhotoLoader.display(for: photo, in: sandbox.store)

        #expect(Self.isReady(display))
    }

    /// The one case that must *not* report a failure: a cancelled load has
    /// observed nothing about the file, and a page that recorded
    /// ``PhotoDisplay/unavailable`` for it would offer to delete a photo it
    /// never looked for.
    @Test("a cancelled load reports loading rather than failure")
    func cancelledDisplayReportsLoading() async throws {
        let sandbox = Sandbox()
        let photo = try #require(
            await offMain {
                sandbox.store.store(Self.sampleImageData(), capturedAt: .now, coordinate: nil)
            }
        )

        let task = Task {
            await HikePhotoLoader.display(for: photo, in: sandbox.store)
        }
        task.cancel()

        let display = await task.value
        if case .unavailable = display {
            Issue.record("a cancelled load must not be reported as a missing file")
        }
    }
}
