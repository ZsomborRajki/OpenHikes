//
//  WaymarkPlacementTests.swift
//  OpenHikesTests
//
//  Where a square's signs stand at a zoom: which routes get one, how far
//  apart along a line, never crowding another sign or repeating one close
//  by, only on the square's own ground, and along a line across the
//  antimeridian the short way round.
//
//  Distances are read back in tile pixels at the zoom asked about, which is
//  what the rules are written in.
//

import CoreGraphics
import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import RealModule
import Testing

@Suite("Waymark placement")
struct WaymarkPlacementTests {
    private static let regional = RouteSquareFile.Route(id: 1, tags: ["network": "rwn", "ref": "412"])
    private static let local = RouteSquareFile.Route(
        id: 2,
        tags: ["network": "lwn", "osmc:symbol": "red:white:red_bar"]
    )
    private static let other = RouteSquareFile.Route(
        id: 3,
        tags: ["network": "lwn", "osmc:symbol": "blue:white:blue_bar"]
    )

    /// A way due east along `latitude`, between two longitudes.
    private static func way(
        along routes: [Int],
        from west: Double,
        to east: Double,
        latitude: Double = 47.6
    ) -> RouteSquareFile.Line {
        RouteSquareFile.Line(
            network: .local,
            routes: routes,
            points: [west, east].map { longitude in
                RouteSquareFile.Point(latitude: Int32(latitude * 1_000_000), longitude: Int32(longitude * 1_000_000))
            }
        )
    }

    private static func square(_ routes: [RouteSquareFile.Route], _ lines: [RouteSquareFile.Line]) -> RouteSquareFile {
        RouteSquareFile(routes: routes, lines: lines, coordinateScale: 1_000_000)
    }

    /// Tile pixels in a map point at `zoom`.
    private static func scale(at zoom: Int) -> Double {
        pow(2, Double(zoom) - 20)
    }

    /// Where each sign stands along an east-west line, in tile pixels from
    /// the west, in order.
    private static func positions(_ marks: [PlacedWaymark], at zoom: Int) -> [Double] {
        marks.map { $0.center.x * scale(at: zoom) }.sorted()
    }

    @Test("only the long routes get a sign at zoom 12, and every route does from 13")
    func whichRoutes() {
        let drawn = DrawnRouteSquare(Self.square(
            [Self.regional, Self.local],
            [Self.way(along: [0], from: 12.8, to: 12.9), Self.way(along: [1], from: 12.8, to: 12.9, latitude: 47.7)]
        ))
        let far = drawn.waymarks(atZoom: 12).map { drawn.signs[$0.sign].network }
        let near = drawn.waymarks(atZoom: 13).map { drawn.signs[$0.sign].network }
        #expect(!far.isEmpty)
        #expect(Set(far) == [.regional])
        #expect(Set(near) == [.regional, .local])
    }

    /// Each zoom deeper doubles the places tried along a square's lines, and
    /// they are tried while a drawing thread waits.
    @Test("deeper than the deepest placement zoom the signs keep that zoom's places")
    func placementStopsDeepening() {
        // 0.1° of longitude is 74,565 tile pixels at zoom 20: room for 248
        // signs there, and for 62 at zoom 18.
        let drawn = DrawnRouteSquare(Self.square([Self.local], [Self.way(along: [0], from: 12.8, to: 12.9)]))
        let deepest = DrawnRouteSquare.deepestPlacementZoom
        let places = { (zoom: Int) in drawn.waymarks(atZoom: zoom).map { [$0.center.x, $0.center.y] } }
        let placed = places(deepest)
        #expect(placed.count > 1)
        #expect(places(deepest + 2) == placed)
        #expect(places(deepest - 1).count < placed.count, "shallower, there are fewer")
    }

    @Test("one line's signs stand its spacing apart, evenly, from half a step in")
    func evenlyAlongALine() throws {
        // 0.1° of longitude is 1,165 tile pixels at zoom 14: room for three.
        let drawn = DrawnRouteSquare(Self.square([Self.local], [Self.way(along: [0], from: 12.8, to: 12.9)]))
        let line = try #require(drawn.lines.first)
        let length = line.length * Self.scale(at: 14)
        let positions = Self.positions(drawn.waymarks(atZoom: 14), at: 14)
        let west = line.bounds.minX * Self.scale(at: 14)
        #expect(positions.count == Int(length / HikingRoutesStyle.waymarkRule(atZoom: 14).spacing))
        #expect(positions.count == 3)
        for (index, position) in positions.enumerated() {
            let expected = west + (Double(index) + 0.5) * length / Double(positions.count)
            #expect(position.isApproximatelyEqual(to: expected, absoluteTolerance: 0.01))
        }
    }

    @Test("a line shorter than the spacing still gets one sign, in its middle")
    func shortLine() throws {
        let drawn = DrawnRouteSquare(Self.square([Self.local], [Self.way(along: [0], from: 12.8, to: 12.81)]))
        let line = try #require(drawn.lines.first)
        let marks = drawn.waymarks(atZoom: 13)
        #expect(marks.count == 1)
        #expect(try #require(marks.first).center.x.isApproximatelyEqual(to: line.bounds.midX, absoluteTolerance: 0.01))
    }

    @Test("the signs of routes that share a line stand side by side along it, the margin apart")
    func sideBySide() throws {
        let drawn = DrawnRouteSquare(Self.square(
            [Self.local, Self.other],
            [Self.way(along: [0, 1], from: 12.8, to: 12.85)]
        ))
        let marks = drawn.waymarks(atZoom: 13)
        #expect(Set(marks.map(\.sign)).count == 2)
        let positions = Self.positions(marks, at: 13)
        let apart = try #require(positions.last) - (try #require(positions.first))
        let rule = HikingRoutesStyle.waymarkRule(atZoom: 13)
        #expect(apart >= Double(WaymarkSign.side) + rule.margin)
        #expect(apart <= HikingRoutesStyle.positionTolerance)
    }

    @Test("the same sign is not repeated within its distance, however many lines carry it")
    func notRepeatedCloseBy() {
        // Two short ways of one waymark, twenty tile pixels apart at zoom 13:
        // nearer than the same sign may stand to itself.
        let lines = [
            Self.way(along: [0], from: 12.8, to: 12.81),
            Self.way(along: [0], from: 12.8, to: 12.81, latitude: 47.6023),
        ]
        #expect(DrawnRouteSquare(Self.square([Self.local], lines)).waymarks(atZoom: 13).count == 1)
    }

    @Test("a square places the signs on its own ground, and leaves the rest of a line to the next square")
    func ownGroundOnly() throws {
        // The square holds longitudes 12.75 to 13; the way runs out of it.
        let file = Self.square([Self.local], [Self.way(along: [0], from: 12.9, to: 13.1)])
        let square = RouteSquareGrid.square(at: .detail, latitude: 47.6, longitude: 12.9)
        let whole = DrawnRouteSquare(file).waymarks(atZoom: 14)
        let own = DrawnRouteSquare(file, square: square)
        let ground = try #require(own.ground)
        let placed = own.waymarks(atZoom: 14)
        #expect(!placed.isEmpty)
        #expect(placed.count < whole.count)
        #expect(placed.allSatisfy { ground.contains($0.center) })
    }

    /// Taveuni, in Fiji, is cut by the antimeridian. Its way's signs stand
    /// along the 0.2° it crosses, on the world's own copy, each placed by the
    /// square at the edge of the map it stands on. Measured the long way
    /// round, they stood out along the squares' whole width.
    @Test("a way across the date line has its signs along the ground it crosses, at both edges of the map")
    func acrossTheDateLine() {
        let file = Self.square([Self.local], [Self.way(along: [0], from: 179.9, to: -179.9, latitude: -16.8)])
        let marks = [179.99, -179.99].flatMap { longitude in
            let square = RouteSquareGrid.square(at: .detail, latitude: -16.8, longitude: longitude)
            return DrawnRouteSquare(file, square: square).waymarks(atZoom: 14)
        }
        let world = MKMapSize.world.width
        let reach = 0.1 * world / 360 + 1
        #expect(marks.allSatisfy { (0..<world).contains($0.center.x) })
        #expect(marks.allSatisfy { $0.center.x < reach || $0.center.x > world - reach })
        #expect(marks.contains { $0.center.x < reach } && marks.contains { $0.center.x > world - reach })
    }

    @Test("a square's signs at a zoom are placed once, and the same every time they are asked for")
    func placedOnce() {
        let drawn = DrawnRouteSquare(Self.square(
            [Self.local, Self.other],
            [Self.way(along: [0, 1], from: 12.8, to: 12.9)]
        ))
        let first = drawn.waymarks(atZoom: 13), again = drawn.waymarks(atZoom: 13)
        #expect(first.map(\.sign) == again.map(\.sign))
        #expect(first.map(\.center.x) == again.map(\.center.x))
        #expect(drawn.waymarks(atZoom: 14).count > first.count, "closer in, the same line has room for more")
    }
}
