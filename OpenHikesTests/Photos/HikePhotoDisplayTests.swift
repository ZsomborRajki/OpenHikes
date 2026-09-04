//
//  HikePhotoDisplayTests.swift
//  OpenHikesTests
//
//  The distinctions the gallery hangs on: a photo whose pixels have not been
//  decoded *yet*, one this device has no file for, and one whose file is here
//  and will not decode.
//
//  ``HikePhotoStore/displayImage(for:)`` answers all three with `nil`, and the
//  page that reads it used to draw a spinner for every one — so a hike listing
//  a photo whose file had gone showed a viewer that never resolved, with no
//  message and nothing to press. ``HikePhotoLoader`` is what turns them into
//  different values, and this suite is what holds them apart.
//
//  The middle one is not an edge case: photo files stay on the device that
//  took them, so every photo of a hike walked with another phone is in that
//  state on this one, and it is the state the strip, the map callout and the
//  viewer all have to be able to name.
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

    /// `nil` for anything that is not a failure, so an assertion can name the
    /// reason it expects rather than only that something went wrong.
    private static func unavailability(_ display: PhotoDisplay) -> PhotoUnavailability? {
        guard case .unavailable(let reason) = display else { return nil }
        return reason
    }

    private static func isReady(_ display: PhotoDisplay) -> Bool {
        if case .ready = display { return true }
        return false
    }

    /// Bytes under the name a photo claims, without asking the store to write
    /// them: the only way to put a file the decoder will refuse where a photo
    /// says its picture is. ``HikePhotoStore/store(_:capturedAt:coordinate:)``
    /// sniffs the format and would refuse these outright.
    private static func writeUndecodableFile(
        for photo: HikePhoto,
        in store: HikePhotoStore
    ) throws {
        try FileManager.default.createDirectory(
            at: store.directory,
            withIntermediateDirectories: true
        )
        try Data("not a picture".utf8).write(to: store.url(for: photo), options: .atomic)
    }

    @Test("a photo whose file was never written is missing, not loading")
    func displayReportsMissingFile() async throws {
        let sandbox = Sandbox()
        // What a mirrored row looks like on a second device, and what a hike
        // keeps after its pixels have gone: valid metadata, nothing on disk
        // under the name it claims.
        let photo = HikePhoto()
        try #require(
            !FileManager.default.fileExists(
                atPath: sandbox.store.url(for: photo).path
            )
        )

        let display = await HikePhotoLoader.display(for: photo, in: sandbox.store)

        #expect(Self.unavailability(display) == .notOnThisDevice)
    }

    /// The two failures have to stay apart: only this one is worth a "Try
    /// Again", and only the other one is worth explaining that photo files
    /// don't travel.
    @Test("a file that is there but cannot be decoded is unreadable, not missing")
    func displayReportsUnreadableFile() async throws {
        let sandbox = Sandbox()
        let photo = HikePhoto()
        try Self.writeUndecodableFile(for: photo, in: sandbox.store)

        let display = await HikePhotoLoader.display(for: photo, in: sandbox.store)

        #expect(Self.unavailability(display) == .unreadable)
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

    // MARK: - The strip's read

    /// The tile answers the same three ways the page does, because it draws a
    /// different placeholder for each: a photo whose file is on another device
    /// used to be indistinguishable from one still decoding, which is a tile
    /// that stays broken with nothing said about it.
    @Test("a thumbnail with no file behind it reports the same missing state")
    func thumbnailReportsMissingFile() async {
        let sandbox = Sandbox()

        let display = await HikePhotoLoader.thumbnail(for: HikePhoto(), in: sandbox.store)

        #expect(Self.unavailability(display) == .notOnThisDevice)
    }

    @Test("a thumbnail whose file cannot be decoded is unreadable, not missing")
    func thumbnailReportsUnreadableFile() async throws {
        let sandbox = Sandbox()
        let photo = HikePhoto()
        try Self.writeUndecodableFile(for: photo, in: sandbox.store)

        let display = await HikePhotoLoader.thumbnail(for: photo, in: sandbox.store)

        #expect(Self.unavailability(display) == .unreadable)
    }

    @Test("a thumbnail is rendered from the stored photo")
    func thumbnailReturnsTheImage() async throws {
        let sandbox = Sandbox()
        let photo = try #require(
            await offMain {
                sandbox.store.store(Self.sampleImageData(), capturedAt: .now, coordinate: nil)
            }
        )

        let display = await HikePhotoLoader.thumbnail(for: photo, in: sandbox.store)

        #expect(Self.isReady(display))
    }

    /// Same rule as the page's: a cancelled tile has observed nothing, and a
    /// tile that drew the "not on this device" glyph because it was scrolled
    /// past would be inventing news.
    @Test("a cancelled thumbnail reports loading rather than failure")
    func cancelledThumbnailReportsLoading() async {
        let sandbox = Sandbox()

        let task = Task {
            await HikePhotoLoader.thumbnail(for: HikePhoto(), in: sandbox.store)
        }
        task.cancel()

        if case .unavailable = await task.value {
            Issue.record("a cancelled load must not be reported as a missing file")
        }
    }
}
