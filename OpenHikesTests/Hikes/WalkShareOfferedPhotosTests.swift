//
//  WalkShareOfferedPhotosTests.swift
//  OpenHikesTests
//
//  Which of a hike's photographs the share card offers to be drawn on: the
//  walk's own first, then the rest — and never a place-only row or a copy of
//  a Wikimedia Commons photograph, whose licence asks for a credit the card
//  does not carry.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Walk share offered photos")
@MainActor
struct WalkShareOfferedPhotosTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let end = start.addingTimeInterval(3600)
    private static let licence = HikePhotoLicence(
        name: "CC BY-SA 4.0",
        url: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/"),
        sourceURL: URL(fileURLWithPath: "/File:Summit.jpg")
    )

    @Test("the walk's own photographs come before the hike's others")
    func walkFirst() {
        let earlier = HikePhoto(capturedAt: Self.start.addingTimeInterval(-86_400))
        let during = HikePhoto(capturedAt: Self.start.addingTimeInterval(600))

        let offered = WalkShareFlow.offered([earlier, during], walkedFrom: Self.start, to: Self.end)

        #expect(offered.map(\.id) == [during.id, earlier.id])
    }

    @Test("a place-only row and a Commons copy are not offered")
    func neitherPlacesNorLicensedCopies() {
        let own = HikePhoto(capturedAt: Self.start.addingTimeInterval(600))
        let place = HikePhoto(capturedAt: Self.start.addingTimeInterval(900), isPlaceOnly: true)
        let commons = HikePhoto(
            capturedAt: Self.start.addingTimeInterval(1200),
            importedFromListingID: "osm:r/1",
            importedAuthorName: "Anna",
            licence: Self.licence
        )

        let offered = WalkShareFlow.offered([own, place, commons], walkedFrom: Self.start, to: Self.end)

        #expect(offered.map(\.id) == [own.id])
    }
}
