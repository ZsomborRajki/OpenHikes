//
//  TrailJunctionDateLineTests.swift
//  OpenHikesTests
//
//  A fork on a leg the line walks across the antimeridian, as Taveuni's
//  trails in Fiji are walked: the leg is a hundred metres of ground, the
//  graph keeps the ways that cross the date line, and the fork on it is
//  warned of as anywhere else. A paused leg across the same spot is a
//  transfer, and still warns of nothing.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import RealModule
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Trail junctions across the date line")
struct TrailJunctionDateLineTests {
    /// On the antimeridian, at Taveuni's latitude.
    private static let origin = CLLocationCoordinate2D(latitude: -16.85, longitude: 180)

    /// The point `east` and `north` metres from the origin, its longitude in
    /// `-180..<180` as a recording and the graph hold it.
    private static func at(_ east: Double, _ north: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: origin.latitude + north / RouteGeometry.metersPerDegreeLatitude,
            longitude: RouteGeometry.normalizedLongitude(
                origin.longitude + east / (RouteGeometry.metersPerDegreeLatitude * cos(origin.latitude * .pi / 180))
            )
        )
    }

    /// A Y three metres east of the date line: the stem from the west across
    /// it, and two arms going on east-north-east and east-south-east.
    private static let fork = TrailGraph(
        nodes: [
            TrailGraphNode(id: 0, coordinate: at(-200, 0)),
            TrailGraphNode(id: 1, coordinate: at(3, 0)),
            TrailGraphNode(id: 2, coordinate: at(200, 70)),
            TrailGraphNode(id: 3, coordinate: at(200, -70)),
        ],
        edges: [
            JunctionFixture.edge(way: 0, index: 0, from: 0, to: 1),
            JunctionFixture.edge(way: 0, index: 1, from: 1, to: 2),
            JunctionFixture.edge(way: 1, index: 0, from: 1, to: 3),
        ]
    )

    /// Up the stem and on along the left arm, recorded sixty metres either
    /// side of the fork: only the leg across the date line passes it.
    private static func line(pausedAt paused: Set<Int> = []) -> RouteProfile {
        let points = [at(-200, 0), at(-60, 0), at(60, 21), at(200, 70)]
        return RouteProfile(route: points.enumerated().map { index, point in
            RouteCoordinate(
                latitude: point.latitude,
                longitude: point.longitude,
                boundary: paused.contains(index) ? .paused : nil
            )
        })
    }

    @Test("the fixture's middle leg is a short walk across the date line")
    func theLegCrossesTheDateLine() {
        let profile = Self.line()
        let start = profile.coordinates[1]
        let end = profile.coordinates[2]

        #expect(start.longitude > 179.9 && end.longitude < -179.9)
        #expect(RouteGeometry.distanceMeters(from: start, to: end) < 150)
    }

    @Test("a fork on a leg walked across the date line is warned of")
    func aForkAcrossTheDateLine() throws {
        let profile = Self.line()

        let junctions = TrailJunctionFinder.junctions(along: profile, in: Self.fork)

        let junction = try #require(junctions.first)
        #expect(junctions.count == 1)
        #expect(junction.towardsEnd == .keepLeft)
        #expect(junction.distanceMeters.isApproximatelyEqual(to: 203, absoluteTolerance: 5))
    }

    @Test("the same leg paused is a transfer, and warns of nothing")
    func aPausedLegAcrossTheDateLine() {
        let profile = Self.line(pausedAt: [2])

        #expect(TrailJunctionFinder.junctions(along: profile, in: Self.fork).isEmpty)
    }
}

// swiftlint:enable no_magic_numbers
