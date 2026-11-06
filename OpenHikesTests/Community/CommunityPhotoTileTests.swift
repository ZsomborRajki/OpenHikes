//
//  CommunityPhotoTileTests.swift
//  OpenHikesTests
//
//  What a downloaded photograph's tile draws once it is handed another file,
//  and what a decode its task has moved on from may do afterwards, which is
//  nothing (#1351).
//
//  Both strips key their tiles by position, so a set going from the preview's
//  strip, or one landing late, hands the tile at a position another file and
//  leaves it its state. The tile decoded only while it had no picture, so it
//  went on drawing the last file's. And ImageIO's decode cannot be cut short,
//  so every `.task(id:)` over these files — the tile, the gallery's page and
//  the maker card's photograph — reads through the form that drops an answer
//  its task no longer owns.
//

import Foundation
@testable import OpenHikes
import SwiftUI
import Testing

@Suite("Community photo tile", .timeLimit(.minutes(1)))
struct CommunityPhotoTileTests {
    /// Two photographs and a file that is not one, in a directory removed when
    /// the test ends.
    nonisolated final class Files: Sendable {
        let root: URL
        let first: URL
        let second: URL
        let unreadable: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("community-photo-tile-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            first = root.appendingPathComponent("0.png")
            second = root.appendingPathComponent("1.png")
            unreadable = root.appendingPathComponent("2.png")
            try PhotoDiscoveryFixture.sampleImageData().write(to: first)
            try PhotoDiscoveryFixture.sampleImageData().write(to: second)
            try Data("<html>Not found</html>".utf8).write(to: unreadable)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static let pixels = 64

    /// A picture the tile already has, of `url`'s file.
    private static func picture(of url: URL) -> CommunityPhotoTile.Picture {
        CommunityPhotoTile.Picture(url: url, image: Image(systemName: "photo"))
    }

    /// The decode a page or a card has moved on from runs to the end
    /// regardless, and must then draw nothing, or the last file's picture
    /// lands over the one the view is on now.
    @Test("a picture decoded for a view that has moved on is not drawn")
    func aPictureForAViewThatMovedOnIsNotDrawn() async throws {
        let files = try Files()
        // Cancelled before it starts: the task is the main actor's, and
        // cannot run until this test suspends.
        let movedOn = Task {
            var drawn = false
            await CommunityPhotoTile.decode(files.first, maxPixelSize: Self.pixels) { _ in drawn = true }
            return drawn
        }
        movedOn.cancel()

        #expect(await movedOn.value == false)
    }

    /// The case a block in the gallery makes: the tile at a position is handed
    /// the next set's file, and has a picture already — the blocked
    /// contributor's.
    @Test("a tile handed another file draws that one, not the last one's picture")
    func aTileHandedAnotherFileDrawsThatOne() async throws {
        let files = try Files()
        let last = Self.picture(of: files.first)
        #expect(last.image(of: files.second) == nil, "the last picture, drawn while the new file decodes")

        var shown: [CommunityPhotoTile.Picture?] = []
        await CommunityPhotoTile.load(files.second, over: last, maxPixelSize: Self.pixels) { shown.append($0) }

        #expect(shown.map { $0?.url } == [files.second])
        #expect(shown.first??.image(of: files.second) != nil)
    }

    /// Nothing to draw is the placeholder, which is the honest answer for a
    /// file that would not decode; the last file's picture is not.
    @Test("a tile handed a file that cannot be read draws its placeholder, not the last picture")
    func aTileHandedAnUnreadableFileDrawsItsPlaceholder() async throws {
        let files = try Files()

        var shown: [CommunityPhotoTile.Picture?] = []
        await CommunityPhotoTile.load(
            files.unreadable,
            over: Self.picture(of: files.first),
            maxPixelSize: Self.pixels
        ) { shown.append($0) }

        #expect(shown.map { $0?.url } == [nil])
    }

    /// What the old guard was for, and still holds: a tile's task runs again
    /// each time the lazy strip brings it back into view.
    @Test("a tile back in view keeps its picture rather than decoding it again")
    func aTileBackInViewKeepsItsPicture() async throws {
        let files = try Files()
        let current = Self.picture(of: files.first)

        var shown: [CommunityPhotoTile.Picture?] = []
        await CommunityPhotoTile.load(files.first, over: current, maxPixelSize: Self.pixels) { shown.append($0) }

        #expect(shown.isEmpty)
        #expect(current.image(of: files.first) != nil)
    }
}
