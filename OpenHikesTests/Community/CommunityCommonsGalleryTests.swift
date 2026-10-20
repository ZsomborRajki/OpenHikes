//
//  CommunityCommonsGalleryTests.swift
//  OpenHikesTests
//
//  Where a curated route's Wikimedia Commons photographs land in the merged
//  gallery, and what each carries there.
//
//  The index is the contract — a map pin, a strip tile and a gallery page name
//  a photograph by its position in one merged list — so the arithmetic is
//  asserted on a detail holding all three sets at once, and again after a
//  block has taken one out of the middle.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Community Commons gallery")
struct CommunityCommonsGalleryTests {
    private static let takenOn = Date(timeIntervalSince1970: 1_700_000_000)

    private static func file(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name).jpeg", isDirectory: false)
    }

    private static func pin(_ index: Int) -> CommunityPhotoPin {
        CommunityPhotoPin(
            capturedAt: takenOn,
            coordinate: CLLocationCoordinate2D(latitude: 47.6 + Double(index) / 1000, longitude: 13)
        )
    }

    private static func license(_ name: String) -> HikePhotoLicense {
        HikePhotoLicense(
            name: "CC BY-SA 4.0",
            url: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/"),
            sourceURL: URL(fileURLWithPath: "/\(name)")
        )
    }

    private static func commons(_ name: String, author: String?) -> CommonsPhoto {
        CommonsPhoto(
            pin: pin(9),
            fileURL: file(name),
            credit: CommonsPhotoCredit(author: author, license: license(name))
        )
    }

    private static func contribution(id: String, author: String, count: Int) -> CommunityPhotoContribution {
        CommunityPhotoContribution(
            id: id,
            photoSubmissionID: "\(id)-submission",
            authorName: author,
            authorID: "\(id)-author",
            publishedAt: takenOn,
            photoPins: (0..<count).map(pin),
            photoFileURLs: (0..<count).map { file("\(id)-\($0)") },
            photosOnRecord: count
        )
    }

    /// Two of the author's, three contributed by Bence, and two from Commons.
    private static var detail: CommunityHikeDetail {
        var built = CommunityHikeDetail(
            listing: .stub(),
            route: Fixture.ridgeRoute,
            trackDescription: nil,
            photoPins: [pin(0), pin(1)],
            photoFileURLs: [file("own-0"), file("own-1")],
            photosOnRecord: 2,
            contributions: [contribution(id: "c1", author: "Bence", count: 3)]
        )
        built.commonsPhotos = [commons("commons-a", author: "Anna"), commons("commons-b", author: nil)]
        return built
    }

    @Test("Commons photographs come last in the gallery, numbered on from everybody else's")
    func commonsComeLast() {
        let gallery = Self.detail.galleryPhotos

        #expect(gallery.map(\.index) == Array(0..<7))
        #expect(gallery.suffix(2).map(\.fileURL) == [Self.file("commons-a"), Self.file("commons-b")])
        #expect(gallery.prefix(5).allSatisfy { $0.commons == nil })
    }

    @Test("a Commons page carries its credit and licence, and no contribution to report")
    func commonsPagesAreCredited() throws {
        let page = try #require(Self.detail.galleryPhotos.last { $0.commons != nil && $0.credit != nil })

        #expect(page.credit == "Anna")
        #expect(page.commons?.license.name == "CC BY-SA 4.0")
        #expect(page.contribution == nil, "nothing on this app to report, block or take down")
        #expect(Self.detail.galleryPhotos.last?.credit == nil, "a file page that names nobody credits nobody")
    }

    @Test("a pin on the map opens the page the strip would")
    func pinsAgreeWithPages() {
        let merged = Self.detail
        let pins = merged.previewPhotos.filter { $0.index >= merged.commonsOffset }
        #expect(pins.map(\.index) == [5, 6])
        #expect(pins.map(\.fileURL) == [Self.file("commons-a"), Self.file("commons-b")])
    }

    @Test("blocking a contributor moves the Commons photographs up, in the strip and on the map alike")
    func blockingRenumbersTogether() {
        let visible = Self.detail.excluding(authors: ["c1-author"], contributions: [])

        #expect(visible.commonsOffset == 2)
        #expect(visible.galleryPhotos.map(\.index) == Array(0..<4))
        #expect(visible.previewPhotos.suffix(2).map(\.index) == [2, 3])
    }
}
