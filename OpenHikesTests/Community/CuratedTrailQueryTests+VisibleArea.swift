//
//  CuratedTrailQueryTests+VisibleArea.swift
//  OpenHikesTests
//
//  The rectangle the map hands over, and the request a search of it makes.
//
//  Beside the suite rather than in it for length, and because the three things
//  here arrived together and are about one question — what a search costs
//  Overpass: the box being the map the hiker can see rather than a square
//  around a circle that was never on screen, the continental paths left out by
//  their member count, and a small box asking for its lines with its list.
//  Every one of them is invisible in a list of plausible-looking rows, which
//  is why they are asserted on the query.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

extension CuratedTrailQueryTests {
    /// The figures the fixtures below are built from, named so the rectangles
    /// read as what they are.
    private enum Figures {
        /// Berchtesgaden, where every figure in ``CuratedTrailQuery`` was
        /// measured.
        static let latitude = 47.63
        static let longitude = 12.86
        /// The map above a half-height sheet at a five-kilometre view: 4.9 km
        /// of latitude by 5 km of longitude at this latitude.
        static let valleyLatitudeDelta = 0.044
        static let valleyLongitudeDelta = 0.0665
        /// About forty by thirty kilometres.
        static let countyLatitudeDelta = 0.36
        static let countyLongitudeDelta = 0.4
    }

    private static let visibleCenter = CLLocationCoordinate2D(latitude: Figures.latitude, longitude: Figures.longitude)

    /// The case the rectangle was introduced for.
    private static let valleySpan = CommunitySearchArea.Span(
        latitudeDelta: Figures.valleyLatitudeDelta,
        longitudeDelta: Figures.valleyLongitudeDelta
    )

    /// Wider than one request may carry lines for, and still inside the
    /// ceiling.
    private static let countySpan = CommunitySearchArea.Span(
        latitudeDelta: Figures.countyLatitudeDelta,
        longitudeDelta: Figures.countyLongitudeDelta
    )

    /// A few millimetres, in degrees — the slack for a midpoint of two binary
    /// fractions.
    private static let degreeTolerance = 1e-9

    private static func visibleArea(
        _ span: CommunitySearchArea.Span = valleySpan,
        center: CLLocationCoordinate2D = visibleCenter
    ) -> CommunitySearchArea {
        CommunitySearchArea(
            coordinate: center,
            radiusMeters: CommunityQueryPolicy.minimumRadiusMeters,
            visibleSpan: span
        )
    }

    // MARK: - The rectangle

    /// The whole point of handing the rectangle over: the radius beside it is
    /// CloudKit's, floored at ten kilometres, and the square around that is
    /// twenty kilometres a side — seventeen times this rectangle.
    @Test("a search with a rectangle asks about the rectangle, not the square around its circle")
    func theRectangleIsTheBox() throws {
        let area = Self.visibleArea()

        let boxes = CuratedTrailQuery.searchBoxes(for: area)

        #expect(boxes.count == 1)
        let box = try #require(boxes.first)
        let halfHeight = Self.valleySpan.latitudeDelta / 2
        let halfWidth = Self.valleySpan.longitudeDelta / 2
        let tolerance = Self.degreeTolerance
        #expect(box.south.isApproximatelyEqual(to: area.latitude - halfHeight, absoluteTolerance: tolerance))
        #expect(box.north.isApproximatelyEqual(to: area.latitude + halfHeight, absoluteTolerance: tolerance))
        #expect(box.west.isApproximatelyEqual(to: area.longitude - halfWidth, absoluteTolerance: tolerance))
        #expect(box.east.isApproximatelyEqual(to: area.longitude + halfWidth, absoluteTolerance: tolerance))

        let circle = CommunitySearchArea(coordinate: area.coordinate, radiusMeters: area.radiusMeters)
        let square = try #require(CuratedTrailQuery.searchBoxes(for: circle).first)
        #expect(
            CuratedTrailQuery.areaSquareMeters(of: square) > 10 * CuratedTrailQuery.areaSquareMeters(of: box),
            "the circle's square is what this used to ask about, and it is many times the map on screen"
        )
    }

    /// The seam is the circle's seam too, and the rectangle crosses it the
    /// same way: two boxes in one request rather than half a view lost.
    @Test("a rectangle across the date line asks about both sides")
    func aRectangleAcrossTheDateLineSplits() throws {
        let area = Self.visibleArea(center: CLLocationCoordinate2D(latitude: -17.0, longitude: 179.99))

        let boxes = CuratedTrailQuery.searchBoxes(for: area)

        #expect(boxes.count == 2)
        let east = try #require(boxes.first { $0.west > 0 })
        let west = try #require(boxes.first { $0.west < 0 })
        #expect(east.east == 180)
        #expect(west.west == -180)
        #expect(west.east.isApproximatelyEqual(
            to: 179.99 + Self.valleySpan.longitudeDelta / 2 - 360,
            absoluteTolerance: Self.degreeTolerance
        ))
    }

    /// Measured the way the policy measures the region it came from, so the
    /// two agree about where *zoom in* begins.
    @Test("a rectangle wider than the ceiling is not asked about")
    func aRectanglePastTheCeilingIsNotAsked() {
        let ceilingInDegrees = 2 * CuratedTrailQuery.maximumRadiusMeters
            / RouteGeometry.metersPerDegreeLatitude
        let tooTall = CommunitySearchArea.Span(latitudeDelta: ceilingInDegrees * 1.01, longitudeDelta: 0.1)
        let boxes = CuratedTrailQuery.searchBoxes(for: Self.visibleArea(tooTall))

        #expect(boxes.isEmpty)
        #expect(CuratedTrailQuery.areaRequest(in: boxes) == nil)
    }

    @Test("a rectangle with nothing in it is not a question")
    func anEmptyRectangleIsNotAsked() {
        let flat = CommunitySearchArea.Span(latitudeDelta: 0, longitudeDelta: 0.1)

        #expect(CuratedTrailQuery.searchBoxes(for: Self.visibleArea(flat)).isEmpty)
    }

    // MARK: - The continental paths

    /// In both shapes of search and in every box of one, because a filter that
    /// one shape forgot would be a search whose cost depended on which side of
    /// the area threshold the hiker happened to be zoomed.
    @Test("both shapes of search leave out relations with more members than a day hike has")
    func bothQueriesFilterOnMemberCount() throws {
        let boxes = CuratedTrailQuery.searchBoxes(
            for: Self.visibleArea(center: CLLocationCoordinate2D(latitude: -17.0, longitude: 179.99))
        )
        let filter = "(if: count_members() < \(CuratedTrailQuery.maximumMemberCount))"
        let queries = [
            CuratedTrailQuery.listingQuery(in: boxes),
            CuratedTrailQuery.listingWithLinesQuery(in: boxes),
        ]

        for query in queries {
            let text = try #require(query)
            #expect(text.components(separatedBy: filter).count - 1 == boxes.count)
            for box in boxes {
                #expect(text.contains("(\(box.overpassLiteral))\(filter);"))
            }
        }
    }

    /// The figure sits between the two populations it separates — see
    /// ``CuratedTrailQuery/maximumMemberCount`` for the measurement.
    @Test("the member ceiling is above the largest day hike measured and below the smallest continental path")
    func theMemberCeilingSeparatesThePopulations() {
        let largestDayHike = 209
        let smallestContinentalPath = 609

        #expect(CuratedTrailQuery.maximumMemberCount > largestDayHike)
        #expect(CuratedTrailQuery.maximumMemberCount < smallestContinentalPath)
    }

    // MARK: - One request or two

    @Test("a small area asks for its routes and their lines in one request")
    func aSmallAreaIsOneRequest() throws {
        let request = try #require(
            CuratedTrailQuery.areaRequest(in: CuratedTrailQuery.searchBoxes(for: Self.visibleArea()))
        )

        #expect(request.drawsLines)
        #expect(request.query.contains("out geom;"))
        #expect(!request.query.contains("out tags bb"))
        #expect(request.timeoutSeconds == CuratedTrailQuery.geometryTimeoutSeconds)
        #expect(request.query.contains("[timeout:\(CuratedTrailQuery.geometryTimeoutSeconds)]"))
    }

    @Test("a wide area keeps the listing pass, and leaves the lines to a second")
    func aWideAreaIsTwoPasses() throws {
        let boxes = CuratedTrailQuery.searchBoxes(for: Self.visibleArea(Self.countySpan))
        #expect(
            boxes.reduce(0) { $0 + CuratedTrailQuery.areaSquareMeters(of: $1) }
                > CuratedTrailQuery.maximumOneRequestAreaSquareMeters,
            "precondition: the fixture is wider than one request carries lines for"
        )

        let request = try #require(CuratedTrailQuery.areaRequest(in: boxes))

        #expect(!request.drawsLines)
        #expect(request.query.contains("out tags bb;"))
        #expect(!request.query.contains("out geom"))
        #expect(request.timeoutSeconds == CuratedTrailQuery.listingTimeoutSeconds)
    }

    @Test("no box is no request")
    func noBoxesIsNoRequest() {
        #expect(CuratedTrailQuery.areaRequest(in: []) == nil)
        #expect(CuratedTrailQuery.listingWithLinesQuery(in: []) == nil)
    }

    /// The threshold is read off this, so it has to be the ground and not the
    /// degrees: a tenth of a degree square is 83 km² in the Alps and 124 km²
    /// on the equator.
    @Test("a box's area is measured on the ground")
    func areaIsMeasuredOnTheGround() {
        let alpine = CuratedTrailQuery.BoundingBox(south: 47.58, west: 12.81, north: 47.68, east: 12.91)
        let equatorial = CuratedTrailQuery.BoundingBox(south: -0.05, west: 10.0, north: 0.05, east: 10.1)
        let squareKilometer = 1_000_000.0
        let alpineArea = CuratedTrailQuery.areaSquareMeters(of: alpine) / squareKilometer
        let equatorialArea = CuratedTrailQuery.areaSquareMeters(of: equatorial) / squareKilometer

        #expect(alpineArea.isApproximatelyEqual(to: 83.5, absoluteTolerance: 0.5))
        #expect(equatorialArea.isApproximatelyEqual(to: 123.9, absoluteTolerance: 0.5))
    }
}
