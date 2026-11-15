//
//  DrawnRouteSquareTests.swift
//  OpenHikesTests
//
//  A square as the layer strokes it: OpenStreetMap's short ways joined end to
//  end where the same routes run, whichever way each was drawn, each line
//  carrying its routes' networks and signs, and none kept that its zooms
//  never draw.
//

import Foundation
import MapKit
@testable import OpenHikes
import RealModule
import Testing

@Suite("Drawn route square")
struct DrawnRouteSquareTests {
    private static func point(_ latitude: Int32, _ longitude: Int32) -> RouteSquareFile.Point {
        RouteSquareFile.Point(latitude: latitude, longitude: longitude)
    }

    /// A file of three routes — international, regional and local — and
    /// `lines`, each along the routes it names.
    private static func square(_ lines: [([Int], [RouteSquareFile.Point])]) -> RouteSquareFile {
        RouteSquareFile(
            routes: [
                RouteSquareFile.Route(id: 1, tags: ["network": "iwn", "ref": "E4"]),
                RouteSquareFile.Route(id: 2, tags: ["network": "rwn", "osmc:symbol": "red:white:red_bar:412:black"]),
                RouteSquareFile.Route(id: 3, tags: ["network": "lwn", "osmc:symbol": "red:white:red_bar"]),
                RouteSquareFile.Route(id: 4, tags: ["osmc:symbol": "red:white:red_bar"]),
            ],
            lines: lines.map { RouteSquareFile.Line(network: .international, routes: $0.0, points: $0.1) },
            coordinateScale: 1_000_000
        )
    }

    private static let a = point(47_500_000, 12_900_000)
    private static let b = point(47_501_000, 12_901_000)
    private static let c = point(47_502_000, 12_902_000)
    private static let d = point(47_503_000, 12_903_000)

    @Test("ways that meet end to end are one line, whichever way each was drawn")
    func waysJoin() {
        let joined = DrawnRouteSquare.joined([[Self.b, Self.c], [Self.a, Self.b], [Self.d, Self.c]])
        #expect(joined.count == 1)
        let line = joined.first ?? []
        #expect(line == [Self.a, Self.b, Self.c, Self.d] || line == [Self.d, Self.c, Self.b, Self.a])
    }

    @Test("a junction of three keeps going along one way and starts a line for the third")
    func junctionOfThree() {
        let joined = DrawnRouteSquare.joined([[Self.a, Self.b], [Self.b, Self.c], [Self.b, Self.d]])
        #expect(joined.count == 2)
        #expect(joined.map(\.count).sorted() == [2, 3])
    }

    @Test("ways that do not meet stay apart")
    func separateWays() {
        #expect(DrawnRouteSquare.joined([[Self.a, Self.b], [Self.c, Self.d]]).count == 2)
    }

    @Test("ways are joined where the same routes run, and a line ends where a route leaves")
    func joinedAlongTheSameRoutes() {
        let drawn = DrawnRouteSquare(Self.square([
            ([0, 1], [Self.a, Self.b]),
            ([0, 1], [Self.b, Self.c]),
            ([0], [Self.c, Self.d]),
        ]))
        #expect(drawn.lines.count == 2)
        #expect(drawn.lines.map(\.points.count).sorted() == [2, 3])
        #expect(drawn.pointCount == 5)
    }

    @Test("a line carries every network among its routes, and an untagged route counts as a local one")
    func networks() {
        let drawn = DrawnRouteSquare(Self.square([([0, 1, 2], [Self.a, Self.b]), ([3], [Self.c, Self.d])]))
        #expect(Set(drawn.lines.map(\.networks)) == [[.international, .regional, .local], .local])
    }

    @Test("a line carries each different sign among its routes once, the most important network's first")
    func signs() throws {
        let drawn = DrawnRouteSquare(Self.square([([0, 1, 2, 3], [Self.a, Self.b])]))
        let line = try #require(drawn.lines.first)
        let signs = line.signs.map { drawn.signs[$0] }
        #expect(signs.map(\.network) == [.international, .regional, .local])
        #expect(signs.first?.content == .reference("E4"))
        #expect(drawn.signs.count == 3, "the local and the untagged route show the same waymark")
        #expect(drawn.signSizes.count == drawn.signs.count)
    }

    @Test("a square keeps no line its zooms never stroke: local routes from a country's view")
    func undrawnLinesAreLeftOut() {
        let file = Self.square([([2], [Self.a, Self.b]), ([1], [Self.c, Self.d])])
        let region = RouteSquareGrid.square(at: .region, latitude: 47.5, longitude: 12.9)
        let area = RouteSquareGrid.square(at: .area, latitude: 47.5, longitude: 12.9)
        #expect(DrawnRouteSquare(file, square: region).lines.map(\.networks) == [.regional])
        #expect(DrawnRouteSquare(file, square: area).lines.count == 2)
    }

    @Test("a joined line's box holds every point of it, and its length is the sum of its steps")
    func boundsAndLength() throws {
        let drawn = DrawnRouteSquare(Self.square([([1], [Self.a, Self.b]), ([1], [Self.b, Self.c])]))
        let line = try #require(drawn.lines.first)
        #expect(drawn.lines.count == 1)
        #expect(line.points.count == 3)
        for point in line.points {
            #expect(point.x >= line.bounds.minX && point.x <= line.bounds.maxX)
            #expect(point.y >= line.bounds.minY && point.y <= line.bounds.maxY)
        }
        let steps = zip(line.points, line.points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        #expect(line.length.isApproximatelyEqual(to: steps.reduce(0, +), absoluteTolerance: 1e-6))
    }
}
