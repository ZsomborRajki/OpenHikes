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
import OpenHikesData
import RealModule
import Testing

@Suite("Commons area photos")
struct CommonsAreaPhotosTests {
    private static let middle = CLLocationCoordinate2D(latitude: 47.6, longitude: 13.0)
    /// A two-kilometre circle, so a four-by-four grid's cells are a kilometre
    /// across.
    private static let area = CommunitySearchArea(coordinate: middle, radiusMeters: 2000)
    private static let metersPerDegree = 111_320.0

    /// The map above a lowered sheet, as a pill hands it over: two kilometres
    /// across and four from top to bottom, with a circle half its longer side.
    private static let tallMap = CommunitySearchArea(
        coordinate: middle,
        radiusMeters: 2000,
        visibleSpan: span(northToSouth: 4000, eastToWest: 2000)
    )

    /// A candidate `north` and `east` metres from the middle of the area.
    private static func candidate(_ pageID: Int, north: Double, east: Double = 0) -> CommonsPhotoCandidate {
        CommonsPhotoCandidate(
            pageID: pageID,
            latitude: middle.latitude + north / metersPerDegree,
            longitude: middle.longitude + east / (metersPerDegree * cos(middle.latitude * .pi / 180))
        )
    }

    /// A rectangle around the middle, `northToSouth` and `eastToWest` metres
    /// edge to edge.
    private static func span(northToSouth: Double, eastToWest: Double) -> CommunitySearchArea.Span {
        CommunitySearchArea.Span(
            latitudeDelta: northToSouth / metersPerDegree,
            longitudeDelta: eastToWest / (metersPerDegree * cos(middle.latitude * .pi / 180))
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

    /// Four cells, three of one person's photographs in one of them, and a
    /// held-back picture in each of the other three: room is left for one,
    /// and it is the one nearest the middle.
    @Test("held-back photographs fill the open cells nearest the middle first, when there is room for fewer")
    func heldBackFillsTheNearestOpenCells() {
        let run = [
            Self.candidate(0, north: 100, east: 100),
            Self.candidate(1, north: 200, east: 100),
            Self.candidate(2, north: 300, east: 100),
        ]
        let heldBack = [
            Self.candidate(3, north: 900, east: -900),
            Self.candidate(4, north: -400, east: -300),
            Self.candidate(5, north: -1000, east: 1000),
        ]
        let authors = Dictionary(uniqueKeysWithValues: (run + heldBack).map { ($0.pageID, "Uploader") })

        let chosen = CommonsAreaPhotos.chosen(heldBack + run, authors: authors, limit: 4, in: Self.area)

        #expect(chosen.map(\.pageID) == [0, 1, 2, 4])
    }

    @Test("an area wider than a geosearch may ask about is asked at the ceiling")
    func aWideAreaIsClamped() {
        let wide = CommunitySearchArea(coordinate: Self.middle, radiusMeters: 25_000)

        #expect(CommonsAreaPhotos.asked(wide).radiusMeters == CommonsTrailPhotos.maximumRadiusMeters)
        #expect(CommonsAreaPhotos.asked(Self.area) == Self.area)
    }

    // MARK: - The map on screen

    /// The circle a pill hands over is half the map's longer side, which
    /// stops short of every corner of the screen.
    @Test("a map on screen is asked about through its corners, and keeps its rectangle")
    func theCornersAreAsked() {
        let northEast = Self.candidate(0, north: 2000, east: 1000).coordinate
        let toTheCorner = RouteGeometry.distanceMeters(from: Self.middle, to: northEast)

        let asked = CommonsAreaPhotos.asked(Self.tallMap)

        #expect(Self.tallMap.radiusMeters < toTheCorner, "the pill's own circle misses the corner")
        #expect(asked.radiusMeters.isApproximatelyEqual(to: toTheCorner, absoluteTolerance: 1))
        #expect(asked.visibleSpan == Self.tallMap.visibleSpan)
        #expect(asked.latitude == Self.tallMap.latitude)
        #expect(asked.longitude == Self.tallMap.longitude)
    }

    @Test("a map whose corners are past a geosearch's reach is asked at the ceiling, and keeps its rectangle")
    func aWideMapIsAskedAtTheCeiling() {
        // Sixteen kilometres a side, so its corners are over eleven out.
        let wide = CommunitySearchArea(
            coordinate: Self.middle,
            radiusMeters: 8000,
            visibleSpan: Self.span(northToSouth: 16_000, eastToWest: 16_000)
        )

        let asked = CommonsAreaPhotos.asked(wide)

        #expect(asked.radiusMeters == CommonsTrailPhotos.maximumRadiusMeters)
        #expect(asked.visibleSpan == wide.visibleSpan)
    }

    @Test("a photograph in a corner of the map is kept, and one off its side is not")
    func theRectangleIsWhatIsKept() {
        // Past the pill's own circle, and inside it.
        let inTheCorner = Self.candidate(1, north: 1900, east: -950)
        let offTheSide = Self.candidate(2, north: 0, east: 1500)
        let nearTheMiddle = Self.candidate(3, north: -100)

        let kept = CommonsAreaPhotos.spread(
            [inTheCorner, offTheSide, nearTheMiddle],
            in: CommonsAreaPhotos.asked(Self.tallMap),
            limit: 16
        )

        #expect(kept.map(\.pageID) == [3, 1])
    }

    /// A grid over the circle's square put half its columns off both sides of
    /// a tall map, so the crowd at the middle took the places of photographs
    /// in the cells it left.
    @Test("a tall map is gridded over what is on screen, one cell per photograph")
    func theGridIsTheMapOnScreen() {
        // One photograph in the middle of each cell of a four-by-four grid
        // over the map, which are half a kilometre across and one tall.
        let loners = (0..<16).map { index in
            Self.candidate(
                100 + index,
                north: -2000 + (Double(index / 4) + 0.5) * 1000,
                east: -1000 + (Double(index % 4) + 0.5) * 500
            )
        }
        let crowd = (0..<40).map { Self.candidate($0, north: 20 + Double($0), east: 20) }

        let kept = CommonsAreaPhotos.spread(crowd + loners, in: CommonsAreaPhotos.asked(Self.tallMap), limit: 16)

        #expect(Set(kept.map(\.pageID)) == Set(loners.map(\.pageID)))
    }

    /// A geosearch answers no further out than its ceiling, so a grid over the
    /// whole of a wider map would leave all but its middle cells empty.
    @Test("a map wider than a geosearch reaches is gridded only as far as the circle goes")
    func aWideMapIsGriddedWithinTheCircle() {
        let wide = CommonsAreaPhotos.asked(
            CommunitySearchArea(
                coordinate: Self.middle,
                radiusMeters: 30_000,
                visibleSpan: Self.span(northToSouth: 60_000, eastToWest: 60_000)
            )
        )
        // One photograph in each cell of a four-by-four grid over the circle's
        // square, five kilometres a side, those in its corners still inside
        // the circle.
        let steps = [-6000.0, -2500, 2500, 6000]
        let loners = (0..<16).map { index in
            Self.candidate(100 + index, north: steps[index / 4], east: steps[index % 4])
        }
        let crowd = (0..<40).map { Self.candidate($0, north: 20 + Double($0), east: 20) }

        let kept = CommonsAreaPhotos.spread(crowd + loners, in: wide, limit: 16)

        #expect(Set(kept.map(\.pageID)) == Set(loners.map(\.pageID)))
    }
}
