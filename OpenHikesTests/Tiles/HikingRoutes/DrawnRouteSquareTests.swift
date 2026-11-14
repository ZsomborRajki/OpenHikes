//
//  DrawnRouteSquareTests.swift
//  OpenHikesTests
//
//  A square as the layer strokes it: OpenStreetMap's short ways joined end to
//  end within a network, whichever way each was drawn, and never across one.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

@Suite("Drawn route square")
struct DrawnRouteSquareTests {
    private static func point(_ latitude: Int32, _ longitude: Int32) -> RouteSquareFile.Point {
        RouteSquareFile.Point(latitude: latitude, longitude: longitude)
    }

    private static func square(_ lines: [(RouteNetwork, [RouteSquareFile.Point])]) -> RouteSquareFile {
        RouteSquareFile(
            routes: [RouteSquareFile.Route(id: 1, tags: [:])],
            lines: lines.map { RouteSquareFile.Line(network: $0.0, routes: [0], points: $0.1) },
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

    @Test("ways of two networks are never joined, even where they meet")
    func networksStayApart() {
        let drawn = DrawnRouteSquare(Self.square([(.national, [Self.a, Self.b]), (.local, [Self.b, Self.c])]))
        #expect(drawn.lines.count == 2)
        #expect(Set(drawn.lines.map(\.network)) == [.national, .local])
        #expect(drawn.pointCount == 4)
    }

    @Test("a joined line's box holds every point of it")
    func boundsHoldTheLine() throws {
        let drawn = DrawnRouteSquare(Self.square([(.regional, [Self.a, Self.b]), (.regional, [Self.b, Self.c])]))
        let line = try #require(drawn.lines.first)
        #expect(drawn.lines.count == 1)
        #expect(line.points.count == 3)
        for point in line.points {
            #expect(point.x >= line.bounds.minX && point.x <= line.bounds.maxX)
            #expect(point.y >= line.bounds.minY && point.y <= line.bounds.maxY)
        }
    }
}
