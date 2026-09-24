//
//  CommunityGalleryPhotosTests.swift
//  OpenHikesTests
//
//  What a downloaded hike hands its gallery, and how that differs from what it
//  hands the map.
//
//  The two are drawn from the same two arrays and are deliberately not the
//  same list. ``CommunityHikeDetail/previewPhotos`` is what the map pins are
//  built from, so a photograph with no coordinate has nowhere to stand and is
//  left out of it. ``CommunityHikeDetail/galleryPhotos`` is what the strip
//  draws and what the viewer pages through, where a photograph with no
//  coordinate is still a photograph — and where dropping one would be a
//  silent off-by-one, because the strip's fourth tile would open the fifth
//  picture.
//
//  The second claim here is about the pins rather than the pictures. Pairing
//  by index is the entirety of what backs "this photograph was taken there",
//  so a detail whose two arrays disagree may not make that claim — and the
//  right answer is the pictures without their places, not no pictures.
//
//  `CKRecord`-free, like the suites beside it: what is worth pinning down is
//  the arithmetic on the values, and a fetch around it would need the public
//  database — see *A suite must never reach the real transport* in the
//  repository instructions.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Community gallery photos")
struct CommunityGalleryPhotosTests {
    private static let hikeDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// A pin per photograph, each at its own place and its own minute, so a
    /// pairing that slipped by one is visible in the assertion rather than
    /// merely possible.
    private static func pin(_ index: Int, anchored: Bool = true) -> CommunityPhotoPin {
        CommunityPhotoPin(
            capturedAt: takenAt(index),
            coordinate: anchored
                ? CLLocationCoordinate2D(latitude: latitude(index), longitude: longitude(index))
                : nil
        )
    }

    private static func takenAt(_ index: Int) -> Date {
        hikeDate.addingTimeInterval(Double(index) * 60)
    }

    /// Where the fixture puts photograph `index`, spelled once.
    ///
    /// Read back through this rather than compared against a written-out
    /// decimal: 47.6 + 2/100 is not 47.62 in binary floating point, and a
    /// literal in an assertion would be claiming that it is.
    private static func latitude(_ index: Int) -> Double {
        47.6 + Double(index) / 100
    }

    private static func longitude(_ index: Int) -> Double {
        12.8 + Double(index) / 100
    }

    private static func url(_ index: Int) -> URL {
        URL(fileURLWithPath: "/tmp/community-preview/photo-\(index).jpeg")
    }

    private static func detail(
        pins: [CommunityPhotoPin],
        urls: [URL]
    ) -> CommunityHikeDetail {
        CommunityHikeDetail(
            listing: .stub(),
            route: [
                RouteCoordinate(latitude: 47.63, longitude: 12.86),
                RouteCoordinate(latitude: 47.64, longitude: 12.87),
            ],
            trackDescription: "A ridge walk",
            photoPins: pins,
            photoFileURLs: urls,
            photosOnRecord: urls.count
        )
    }

    // MARK: - Every picture, in order

    @Test("every downloaded photograph is in the gallery, with its own pin")
    func galleryCarriesEveryPhotographAndItsPin() {
        let detail = Self.detail(
            pins: (0..<3).map { Self.pin($0) },
            urls: (0..<3).map(Self.url)
        )

        let photos = detail.galleryPhotos

        #expect(photos.map(\.index) == [0, 1, 2])
        #expect(photos.map(\.fileURL) == (0..<3).map(Self.url))
        #expect(photos.map(\.pin?.capturedAt) == (0..<3).map(Self.takenAt))
        #expect(photos.map(\.coordinate?.latitude) == (0..<3).map(Self.latitude))
        #expect(photos.map(\.coordinate?.longitude) == (0..<3).map(Self.longitude))
    }

    /// The whole reason this is not ``CommunityHikeDetail/previewPhotos``. An
    /// unanchored picture is left off the map because it has nowhere to stand;
    /// leaving it out of the gallery would make the tile after it open the
    /// wrong page.
    @Test("a photograph with nowhere to stand is still a photograph")
    func unanchoredPhotographsKeepTheirPlaceInTheGallery() {
        let detail = Self.detail(
            pins: [Self.pin(0), Self.pin(1, anchored: false), Self.pin(2)],
            urls: (0..<3).map(Self.url)
        )

        let photos = detail.galleryPhotos

        #expect(photos.map(\.index) == [0, 1, 2])
        #expect(photos.map(\.fileURL) == (0..<3).map(Self.url))
        #expect(photos[1].coordinate == nil)
        // It is dropped from the map's list, which is the contrast this test
        // exists to draw rather than an incidental fact.
        #expect(detail.previewPhotos.map(\.index) == [0, 2])
        // And it keeps the one thing the hike does know about it.
        #expect(photos[1].pin?.capturedAt == Self.takenAt(1))
    }

    @Test("the gallery photograph's identity is its place in the submission")
    func galleryPhotoIdentityIsItsIndex() {
        let photos = Self.detail(
            pins: (0..<2).map { Self.pin($0) },
            urls: (0..<2).map(Self.url)
        ).galleryPhotos

        #expect(photos.map(\.id) == photos.map(\.index))
    }

    // MARK: - When the two arrays disagree

    /// Pairing by index is the whole of what backs a pin, so a detail that
    /// cannot support it makes no claim at all about where anything was
    /// taken — and still shows every picture, because the pictures were never
    /// in doubt.
    @Test("an inconsistent detail loses the places and keeps the pictures")
    func inconsistentDetailKeepsPicturesAndDropsPins() {
        let detail = Self.detail(
            pins: [Self.pin(0)],
            urls: (0..<3).map(Self.url)
        )

        let photos = detail.galleryPhotos

        #expect(!detail.isConsistent)
        #expect(photos.map(\.index) == [0, 1, 2])
        #expect(photos.map(\.fileURL) == (0..<3).map(Self.url))
        #expect(photos.allSatisfy { $0.pin == nil })
        #expect(photos.allSatisfy { $0.coordinate == nil })
        // The map draws nothing at all from a detail like this, which is the
        // stricter half of the same rule.
        #expect(detail.previewPhotos.isEmpty)
    }

    @Test("a hike with no photographs has an empty gallery")
    func noPhotographsIsAnEmptyGallery() {
        #expect(Self.detail(pins: [], urls: []).galleryPhotos.isEmpty)
    }
}
