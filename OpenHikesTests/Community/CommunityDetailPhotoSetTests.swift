//
//  CommunityDetailPhotoSetTests.swift
//  OpenHikesTests
//
//  What a downloaded hike can say about its own photographs: where each one
//  was taken, which of them a reviewer is keeping, and whether it is safe to
//  be asked the second question at all.
//
//  The third is the one worth having a suite for. Taking a photograph off a
//  submission rewrites the record's whole photo field out of the copies on
//  this device, so doing it after a partial download would delete a picture
//  nobody decided anything about — permanently, with nothing anywhere
//  reporting it, and with the pins of everything after it renumbered on the
//  way past. ``CommunityHikeDetail/hasEveryPhoto`` is the guard, and these are
//  the cases it has to be right about.
//
//  `CKRecord`-free, like `CommunityPhotoPairingTests` beside it and for the
//  same reason: what is worth pinning down is the arithmetic on the values,
//  and the fetch around it needs the public database — see *the tests that
//  never reach the real transport* in the instructions.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Community detail photo set")
struct CommunityDetailPhotoSetTests {
    private static let hikeDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// A pin per photograph, each at its own place and its own minute, so a
    /// pairing that slipped by one is visible in the assertion rather than
    /// merely possible.
    private static func pin(_ index: Int, anchored: Bool = true) -> CommunityPhotoPin {
        CommunityPhotoPin(
            capturedAt: hikeDate.addingTimeInterval(Double(index) * 60),
            coordinate: anchored
                ? CLLocationCoordinate2D(latitude: latitude(index), longitude: longitude(index))
                : nil
        )
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

    /// A detail whose pins and files agree, which is what the transport
    /// guarantees and what everything below varies from.
    private static func detail(
        pins: [CommunityPhotoPin],
        urls: [URL],
        onRecord: Int? = nil
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
            photosOnRecord: onRecord ?? urls.count
        )
    }

    private static func whole(_ count: Int) -> CommunityHikeDetail {
        detail(
            pins: (0..<count).map { pin($0) },
            urls: (0..<count).map { url($0) }
        )
    }

    // MARK: - Where each photograph was taken

    /// The pairing the map draws from, made out of the two arrays that hold
    /// it — each picture with its own coordinate and its own minute.
    @Test("every anchored photograph keeps its own place and time")
    func anchoredPhotographsKeepTheirOwnPins() {
        let photos = Self.whole(3).previewPhotos

        #expect(photos.map(\.index) == [0, 1, 2])
        #expect(photos.map(\.fileURL) == (0..<3).map(Self.url))
        let taken: [Date] = (0..<3).map { Self.hikeDate.addingTimeInterval(Double($0) * 60) }
        #expect(photos.map(\.capturedAt) == taken)
        #expect(photos.map(\.latitude) == (0..<3).map(Self.latitude))
    }

    /// A photograph with nowhere to stand gets no pin, and — the part that
    /// matters — takes nothing with it. The ones after it keep their own
    /// index, because that index is what pairs them with their file.
    @Test("an unanchored photograph is left off the map without renumbering the rest")
    func unanchoredPhotographsAreLeftOff() {
        let detail = Self.detail(
            pins: [Self.pin(0), Self.pin(1, anchored: false), Self.pin(2)],
            urls: (0..<3).map(Self.url)
        )

        let photos = detail.previewPhotos

        #expect(photos.map(\.index) == [0, 2])
        #expect(photos.map(\.fileURL) == [Self.url(0), Self.url(2)])
        #expect(photos.map(\.latitude) == [0, 2].map(Self.latitude))
    }

    /// The one failure nothing downstream could notice: a pin drawn where a
    /// *different* photograph was taken. Two arrays that disagree in length
    /// cannot be paired by index at all, so nothing is drawn rather than
    /// something that might be right.
    @Test("pins and files that disagree draw no pins at all")
    func inconsistentArraysDrawNothing() {
        let detail = Self.detail(
            pins: [Self.pin(0), Self.pin(1)],
            urls: (0..<3).map(Self.url)
        )

        #expect(detail.previewPhotos.isEmpty)
        #expect(!detail.isConsistent)
    }

    // MARK: - Which ones a reviewer is keeping

    /// What gets written back onto the submission, in the order it is written.
    ///
    /// Sorted rather than in set order, and that is the whole of this test:
    /// the two record fields pair by position, so an unordered answer would
    /// publish each remaining photograph under somebody else's coordinate.
    @Test("kept photographs come back in index order, each with its own pin")
    func keptPhotographsKeepTheirOrder() {
        let detail = Self.whole(4)

        let kept = detail.keptPhotos(at: [3, 0, 2])

        #expect(kept.map(\.fileURL) == [Self.url(0), Self.url(2), Self.url(3)])
        #expect(kept.map(\.pin) == [Self.pin(0), Self.pin(2), Self.pin(3)])
    }

    /// Emptying the strip is a thing a reviewer may legitimately do — a walk
    /// worth publishing whose every photograph is not — and it has to reach
    /// the transport as an empty list rather than as nothing to do.
    @Test("keeping none comes back empty")
    func keepingNoneComesBackEmpty() {
        #expect(Self.whole(2).keptPhotos(at: []).isEmpty)
    }

    /// An index that is not a photograph is dropped rather than trusted. It
    /// cannot arise from the screen, and what it would cost if it did is an
    /// out-of-bounds crash in the middle of a decision.
    @Test("an index past the end is ignored")
    func indexesPastTheEndAreIgnored() {
        #expect(Self.whole(2).keptPhotos(at: [0, 9]).map(\.fileURL) == [Self.url(0)])
    }

    /// The same refusal the map makes, and a sharper one: this answer is
    /// uploaded, so pairing it wrongly would publish the mistake.
    @Test("a detail whose arrays disagree keeps nothing")
    func inconsistentArraysKeepNothing() {
        let detail = Self.detail(pins: [Self.pin(0)], urls: (0..<2).map(Self.url))

        #expect(detail.keptPhotos(at: [0, 1]).isEmpty)
    }

    // MARK: - Whether removal may be offered at all

    @Test("a complete download may have photographs taken off it")
    func aCompleteDownloadIsEditable() {
        #expect(Self.whole(3).hasEveryPhoto)
    }

    /// The case the guard exists for. One asset CloudKit could not hand back
    /// leaves a strip of two describing a record of three — and a rewrite
    /// built from that strip would delete the third.
    @Test("a download that lost a photograph may not")
    func aPartialDownloadIsNotEditable() {
        let detail = Self.detail(
            pins: (0..<2).map { Self.pin($0) },
            urls: (0..<2).map(Self.url),
            onRecord: 3
        )

        #expect(!detail.hasEveryPhoto)
        // Still a perfectly good hike to look at and publish: what is withheld
        // is the editing, not the decision.
        #expect(detail.previewPhotos.count == 2)
    }

    /// A hike with no photographs at all is complete, not partial. The
    /// distinction is what keeps the strip's explanation off a screen with no
    /// strip.
    @Test("a hike with no photographs is complete")
    func noPhotographsIsComplete() {
        #expect(Self.whole(0).hasEveryPhoto)
    }
}
