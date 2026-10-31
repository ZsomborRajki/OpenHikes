//
//  LibraryLineOutlineTests.swift
//  OpenHikesTests
//
//  What the map keeps of a hike that is not selected: its line thinned to a
//  budget the whole library can afford, cut where it was paused. See
//  `LibraryLineOutline.swift` for why those two rules and the order they run
//  in.
//
//  The routes are made here, in metres north and east of one point, so each
//  test can say exactly how far apart its points are and what the thinning
//  should have left.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Library line outlines")
struct LibraryLineOutlineTests {
    private static let origin = CLLocationCoordinate2D(latitude: 47.6, longitude: 12.86)
    /// A degree on the sphere ``RouteGeometry`` measures on, so a metre here
    /// is a metre to the thinning.
    private static let metersPerDegree = 6_371_008.8 * .pi / 180

    /// A point `north` and `east` metres from ``origin``.
    private static func point(
        north: Double,
        east: Double = 0,
        boundary: RouteBoundary? = nil
    ) -> RouteCoordinate {
        let longitudeScale = cos(origin.latitude * .pi / 180)
        return RouteCoordinate(
            latitude: origin.latitude + north / metersPerDegree,
            longitude: origin.longitude + east / (metersPerDegree * longitudeScale),
            boundary: boundary
        )
    }

    /// A straight line north, a point every `spacing` metres.
    private static func straight(points: Int, spacing: Double) -> [RouteCoordinate] {
        (0..<points).map { point(north: Double($0) * spacing) }
    }

    /// A line north that zig-zags `swing` metres either side, a point every
    /// `spacing` metres: every point is shape, so only the budget thins it.
    private static func zigzag(points: Int, spacing: Double, swing: Double) -> [RouteCoordinate] {
        (0..<points).map { index in
            point(north: Double(index) * spacing, east: index.isMultiple(of: 2) ? -swing : swing)
        }
    }

    private static func count(_ runs: [[CLLocationCoordinate2D]]) -> Int {
        runs.reduce(0) { $0 + $1.count }
    }

    private static func isSame(_ lhs: CLLocationCoordinate2D, _ rhs: RouteCoordinate) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }

    @Test("a route sparser than the spacing and inside the budget is kept whole")
    func aSparseRouteIsKeptWhole() {
        let route = Self.straight(points: 50, spacing: 10)
        let runs = LibraryLineOutline.runs(of: route)
        #expect(runs.count == 1)
        #expect(runs.first?.count == 50)
    }

    /// A fix a second is a metre or two apart, and none of that is shape.
    /// A point a metre and a half on is three short of the spacing and the
    /// third is half a metre past it, so every third point stays.
    @Test("points closer than the spacing go, and the line still ends where the walk did")
    func denseFixesAreSpacedOut() throws {
        let route = Self.straight(points: 101, spacing: 1.5)
        let run = try #require(LibraryLineOutline.runs(of: route).first)
        #expect(run.count == 35, "34 every third point, and the last")
        #expect(Self.isSame(try #require(run.first), route[0]))
        #expect(Self.isSame(try #require(run.last), route[100]), "the last point is kept whatever")
    }

    @Test("a route of more shape than the budget is cut to the budget, ends kept")
    func aLongRouteMeetsTheBudget() throws {
        let route = Self.zigzag(points: 2000, spacing: 20, swing: 30)
        let runs = LibraryLineOutline.runs(of: route)
        let run = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(Self.count(runs) == LibraryLineOutline.maximumPoints, "spent exactly, since every point is shape")
        #expect(Self.isSame(try #require(run.first), route[0]))
        #expect(Self.isSame(try #require(run.last), route[1999]))
    }

    /// The perpendicular to the line through a span's ends calls an
    /// out-and-back's turnaround no distance at all when the walk stopped
    /// short on the way home (#964). Measured against the segment it is the
    /// farthest point there is, and the first one a budget keeps.
    @Test("an out-and-back that stops short keeps its turnaround")
    func theTurnaroundSurvives() throws {
        let out = (0...100).map { Self.point(north: Double($0) * 10) }
        let back = (1...60).map { Self.point(north: Double(100 - $0) * 10, east: 5) }
        let route = out + back
        let run = try #require(LibraryLineOutline.runs(of: route, maximumPoints: 3).first)
        #expect(run.count == 3)
        #expect(Self.isSame(run[1], route[100]), "the far end of the walk")
    }

    /// A paused leg is not trail (#962): a drive between two walks is a gap
    /// on the map, not a line.
    @Test("a pause cuts the line, and the paused leg is in no run")
    func aPauseCutsTheLine() throws {
        let morning = (0..<20).map { Self.point(north: Double($0) * 10) }
        let afternoon = (0..<20).map { index in
            Self.point(north: 5000 + Double(index) * 10, boundary: index == 0 ? .paused : nil)
        }
        let runs = LibraryLineOutline.runs(of: morning + afternoon)
        #expect(runs.count == 2)
        #expect(Self.isSame(try #require(runs.first?.last), morning[19]))
        #expect(Self.isSame(try #require(runs.last?.first), afternoon[0]))
    }

    /// A GPX file opens a pause at every `<trkseg>`, and nothing bounds how
    /// many it has (#1023): past the budget, the longest breaks stay breaks
    /// and the rest are drawn as the trail they nearly are.
    @Test("past the pause budget only the longest breaks stay breaks")
    func onlyTheLongestBreaksStay() {
        // Ten segments of three points, each break a little longer than the
        // one before, so the longest are the last.
        var route: [RouteCoordinate] = []
        var north = 0.0
        for segment in 0..<10 {
            north += Double(segment + 1) * 20
            for index in 0..<3 {
                route.append(Self.point(north: north, boundary: segment > 0 && index == 0 ? .paused : nil))
                north += 10
            }
        }
        let runs = LibraryLineOutline.runs(of: route, pauseBudget: 3)
        #expect(runs.count == 4, "three breaks kept, so four runs")
        #expect(Self.count(runs) == route.count, "folding a break drops no point")
        // The three kept breaks are the three longest: those before the last
        // three segments.
        #expect(runs.dropFirst().map(\.count) == [3, 3, 3])
    }

    @Test("a point that is not a place on Earth is left out")
    func invalidPointsAreDropped() throws {
        var route = Self.straight(points: 10, spacing: 10)
        route.insert(RouteCoordinate(latitude: 120, longitude: 0), at: 5)
        let run = try #require(LibraryLineOutline.runs(of: route).first)
        #expect(run.count == 10)
        #expect(run.allSatisfy(CLLocationCoordinate2DIsValid))
    }

    @Test("a route with no line in it has no runs", arguments: [0, 1])
    func noLineNoRuns(points: Int) {
        #expect(LibraryLineOutline.runs(of: Self.straight(points: points, spacing: 10)).isEmpty)
    }

    /// A line that never moves further than the spacing is a place, not a
    /// line: its first and last points are all there is of it.
    @Test("a route that stood still is two points")
    func aRouteThatStoodStill() throws {
        let route = Self.straight(points: 30, spacing: 0.1)
        let run = try #require(LibraryLineOutline.runs(of: route).first)
        #expect(run.count == 2)
    }
}
