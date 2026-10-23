//
//  CommonsAreaPhotosTests.swift
//  OpenHikesTests
//
//  Which Commons photographs the trail maker shows for an area: spread over
//  the map rather than piled on its middle, and not twelve from one person.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Commons area photos")
struct CommonsAreaPhotosTests {
    private static let middle = CLLocationCoordinate2D(latitude: 47.6, longitude: 13.0)
    /// A two-kilometre circle, so a four-by-four grid's cells are a kilometre
    /// across.
    private static let area = CommunitySearchArea(coordinate: middle, radiusMeters: 2000)
    private static let metersPerDegree = 111_320.0

    /// A candidate `north` and `east` metres from the middle of the area.
    private static func candidate(_ pageID: Int, north: Double, east: Double = 0) -> CommonsPhotoCandidate {
        CommonsPhotoCandidate(
            pageID: pageID,
            latitude: middle.latitude + north / metersPerDegree,
            longitude: middle.longitude + east / (metersPerDegree * cos(middle.latitude * .pi / 180))
        )
    }

    @Test("a short answer comes back whole, nearest the middle first")
    func aShortAnswerIsKept() {
        let far = Self.candidate(1, north: 1500)
        let near = Self.candidate(2, north: 100)

        #expect(CommonsAreaPhotos.spread([far, near], in: Self.area, limit: 16).map(\.pageID) == [2, 1])
    }

    @Test("a file outside the circle, or a second answer for one file, is dropped")
    func outsideAndRepeatsAreDropped() {
        let inside = Self.candidate(1, north: 500)
        let outside = Self.candidate(2, north: 2500)

        let kept = CommonsAreaPhotos.spread([inside, outside, inside], in: Self.area, limit: 16)

        #expect(kept.map(\.pageID) == [1])
    }

    /// Commons gives a file one primary coordinate, so its repeats agree on
    /// where it is; this pins that a file is judged once, by its first
    /// answer, before anything is measured.
    @Test("a file's first answer is the one judged, wherever a later one puts it")
    func theFirstAnswerIsJudged() {
        let kept = CommonsAreaPhotos.spread(
            [Self.candidate(1, north: 500), Self.candidate(1, north: 1500)],
            in: Self.area,
            limit: 16
        )
        #expect(kept == [Self.candidate(1, north: 500)], "the file comes back as its first answer, untouched")

        let outsideFirst = CommonsAreaPhotos.spread(
            [Self.candidate(2, north: 2500), Self.candidate(2, north: 500)],
            in: Self.area,
            limit: 16
        )
        #expect(outsideFirst.isEmpty)
    }

    /// The reason the grid exists: a geosearch answers nearest its centre
    /// first, so forty pictures of the village at the middle of the screen
    /// used to be the whole answer.
    @Test("a crowd at the middle does not crowd out the corners")
    func theCornersGetTheirTurn() {
        let crowd = (0..<40).map { Self.candidate($0, north: Double($0), east: 10) }
        let corners = [
            Self.candidate(100, north: 1200, east: 1200),
            Self.candidate(101, north: -1200, east: -1200),
            Self.candidate(102, north: 1200, east: -1200),
            Self.candidate(103, north: -1200, east: 1200),
        ]

        let kept = CommonsAreaPhotos.spread(crowd + corners, in: Self.area, limit: 8)

        #expect(kept.count == 8)
        #expect(Set(kept.map(\.pageID)).isSuperset(of: [100, 101, 102, 103]))
    }

    @Test("a fourth photograph from one person only fills a cell nothing else covers")
    func onePhotographerDoesNotTakeOver() {
        // Five of one person's in the same cell near the middle, and one of
        // somebody else's far out on its own.
        let run = (0..<5).map { Self.candidate($0, north: Double($0) * 20) }
        let alone = Self.candidate(9, north: -1200, east: 1200)
        let authors = Dictionary(uniqueKeysWithValues: run.map { ($0.pageID, "Uploader") })
            .merging([9: "Someone Else"]) { first, _ in first }

        let chosen = CommonsAreaPhotos.chosen(run + [alone], authors: authors, limit: 16, in: Self.area)

        #expect(chosen.contains { $0.pageID == 9 })
        #expect(chosen.filter { authors[$0.pageID] == "Uploader" }.count == CommonsTrailPhotos.perAuthorLimit)
    }

    @Test("an area wider than a geosearch may ask about is asked at the ceiling")
    func aWideAreaIsClamped() {
        let wide = CommunitySearchArea(coordinate: Self.middle, radiusMeters: 25_000)

        #expect(CommonsAreaPhotos.asked(wide).radiusMeters == CommonsTrailPhotos.maximumRadiusMeters)
        #expect(CommonsAreaPhotos.asked(Self.area) == Self.area)
    }
}
