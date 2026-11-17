//
//  JunctionFixture.swift
//  OpenHikesTests
//
//  One fork, for the suites about junction warnings that need a trail graph
//  and a hike along it rather than geometry of their own: the phone's guide
//  and the watch's package.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData

// swiftlint:disable no_magic_numbers

enum JunctionFixture {
    private static let origin = CLLocationCoordinate2D(latitude: 47.0, longitude: 11.0)

    /// The point `east` and `north` metres from the origin.
    static func at(_ east: Double, _ north: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: origin.latitude + north / RouteGeometry.metersPerDegreeLatitude,
            longitude: origin.longitude + east
                / (RouteGeometry.metersPerDegreeLatitude * cos(origin.latitude * .pi / 180))
        )
    }

    /// A Y at the origin: a stem 400 m long from the south, and two arms
    /// going on north-north-west and north-north-east.
    static let fork = TrailGraph(
        nodes: [
            TrailGraphNode(id: 0, coordinate: at(0, -400)),
            TrailGraphNode(id: 1, coordinate: at(0, 0)),
            TrailGraphNode(id: 2, coordinate: at(-140, 400)),
            TrailGraphNode(id: 3, coordinate: at(140, 400)),
        ],
        edges: [
            edge(way: 0, index: 0, from: 0, to: 1),
            edge(way: 0, index: 1, from: 1, to: 2),
            edge(way: 1, index: 0, from: 1, to: 3),
        ]
    )

    /// The trail up the stem and on along the left arm: a *keep left* 400 m
    /// along it.
    static let route = [at(0, -400), at(0, 0), at(-140, 400)].map(RouteCoordinate.init)

    private static func edge(way: Int64, index: Int, from: Int64, to: Int64) -> TrailGraphEdge {
        TrailGraphEdge(
            id: TrailGraphEdgeID(wayID: way, segmentIndex: index),
            fromNodeID: from,
            toNodeID: to,
            lengthMeters: 1,
            highway: "path"
        )
    }
}

// swiftlint:enable no_magic_numbers
