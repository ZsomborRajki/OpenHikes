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

    @Test("ways that come back to where they started are one line, closed")
    func loop() {
        #expect(DrawnRouteSquare.joined([[Self.a, Self.b], [Self.c, Self.b], [Self.c, Self.a]])
            == [[Self.a, Self.b, Self.c, Self.a]])
    }

    /// OpenStreetMap numbers ways in no walking order, so a line can grow from
    /// either of its ends: from its first way forward, or from its last way
    /// backward, each a few hundred times. Either way it is the same line,
    /// running the way its first way was drawn.
    @Test(
        "a chain of ways is one line, whichever order the ways come in and whichever way each was drawn",
        arguments: [(false, false), (true, false), (false, true), (true, true)]
    )
    func chain(lastWayFirst: Bool, eachWayReversed: Bool) {
        let points = (0...400).map { Self.point(47_500_000, 12_900_000 + Int32($0) * 100) }
        let ways = zip(points, points.dropFirst()).map { eachWayReversed ? [$1, $0] : [$0, $1] }
        let joined = DrawnRouteSquare.joined(lastWayFirst ? ways.reversed() : ways)
        #expect(joined == [eachWayReversed ? points.reversed() : points])
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

    /// Seven long routes' signs and six local ones', two of them met twice,
    /// and named by the lines in an order of their own: the long half is
    /// ordered by network, a tie by when its sign was first met, and each
    /// half is cut to five apart from the other.
    @Test("a line shows five long routes' signs, then five local ones', each half cut apart from the other")
    func signsPerHalf() {
        let references: [(network: String?, ref: String)] = [
            ("lwn", "L1"), ("rwn", "R1"), (nil, "L2"), ("iwn", "E1"), ("nwn", "N1"), ("lwn", "L3"),
            ("rwn", "R2"), ("rwn", "R1"), ("lwn", "L4"), ("nwn", "N2"), ("lwn", "L5"), ("iwn", "E2"),
            ("lwn", "L6"), ("rwn", "R3"), ("lwn", "L1"),
        ]
        let file = RouteSquareFile(
            routes: references.enumerated().map { index, route in
                var tags = ["ref": route.ref]
                tags["network"] = route.network
                return RouteSquareFile.Route(id: Int64(index), tags: tags)
            },
            lines: [
                RouteSquareFile.Line(
                    network: .international,
                    routes: Array(references.indices.reversed()),
                    points: [Self.a, Self.b]
                ),
                RouteSquareFile.Line(
                    network: .regional,
                    routes: [12, 10, 8, 7, 5, 2, 1, 0, 14],
                    points: [Self.c, Self.d]
                ),
            ],
            coordinateScale: 1_000_000
        )
        let drawn = DrawnRouteSquare(file)
        #expect(drawn.signs.count == 13, "a route whose sign was met already adds none")
        let shown = drawn.lines.map { line in
            line.signs.map { index -> String in
                guard case .reference(let reference) = drawn.signs[index].content else { return "" }
                return reference
            }
        }
        #expect(shown.contains(["E1", "E2", "N1", "N2", "R1", "L1", "L2", "L3", "L4", "L5"]))
        #expect(shown.contains(["R1", "L1", "L2", "L3", "L4", "L5"]), "one long sign leaves the local five as they are")
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
