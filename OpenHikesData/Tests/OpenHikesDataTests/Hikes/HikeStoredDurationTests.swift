//
//  HikeStoredDurationTests.swift
//  OpenHikesDataTests
//
//  The clock a hike stores beside its route (#1025). Siri, Spotlight and the
//  widget's catalogue read it for every finished hike rather than decoding
//  each route to find two stamps, so it is worth nothing unless it is the
//  figure the route itself gives. That agreement is what is pinned: when a
//  hike is made, after its route is replaced, and against the rule its detail
//  screen measures *Duration* by.
//

import Foundation
@testable import OpenHikesData
import Testing

@Suite("Hike stored duration")
struct HikeStoredDurationTests {
    private static let start = Date(timeIntervalSince1970: 1_757_000_000)

    /// The `index`th point north along a line, stamped `seconds` after
    /// ``start``, or carrying no stamp.
    private static func point(_ index: Int, at seconds: TimeInterval?) -> RouteCoordinate {
        RouteCoordinate(
            latitude: 47.63 + Double(index) * 0.001,
            longitude: 12.86,
            timestamp: seconds.map { start.addingTimeInterval($0) }
        )
    }

    private static func route(_ stamps: [TimeInterval?]) -> [RouteCoordinate] {
        stamps.enumerated().map { point($0.offset, at: $0.element) }
    }

    @Test("a hike is made with its route's clock")
    func madeWithItsRoutesClock() {
        let hike = Hike(title: "Thumsee Loop", distanceMeters: 2200, route: Self.route([0, 1800, 3600]))

        #expect(hike.durationSeconds == 3600)
    }

    @Test("replacing the route replaces the clock with it")
    func replacingTheRouteReplacesTheClock() {
        let hike = Hike(title: "Thumsee Loop", distanceMeters: 2200, route: Self.route([0, 3600]))

        hike.replaceRoute(with: Self.route([0, 600, 5400]))
        #expect(hike.durationSeconds == 5400)

        // What *Edit Route* writes: a drawn line, which carries no stamps.
        hike.replaceRoute(with: Self.route([nil, nil, nil]))
        #expect(hike.durationSeconds == nil)
    }

    /// A recording's draft is made with no route, and the one it walked is
    /// written into it in place at Stop.
    @Test("a recording's draft has no clock until its route is written into it")
    func aDraftTakesItsClockWithItsRoute() {
        let hike = Hike(title: "Morning Walk", distanceMeters: 0, isRecording: true)
        #expect(hike.durationSeconds == nil)

        hike.replaceRoute(with: Self.route([0, 300, 900]))
        #expect(hike.durationSeconds == 900)
    }

    /// Case by case against `HikeRouteStatistics`, which walks every point:
    /// the stored figure is found by a search in from each end instead, and
    /// the two have to agree wherever the stamps fall.
    @Test(
        "the stored clock is the one the route's statistics measure",
        arguments: [
            ("stamped throughout", [0, 600, 1200], 1200),
            ("never stamped", [nil, nil, nil], nil),
            ("stamped once", [nil, 600, nil], nil),
            ("stamped only between its ends", [nil, 600, 900, 2400, nil], 1800),
            ("stamped backwards", [1200, 600, 0], nil),
            ("stamped at one instant", [600, 600], nil),
            ("empty", [], nil),
        ] as [(String, [TimeInterval?], TimeInterval?)]
    )
    func storedClockIsTheStatisticsClock(shape: String, stamps: [TimeInterval?], expected: TimeInterval?) {
        let hike = Hike(title: shape, distanceMeters: 1000, route: Self.route(stamps))

        #expect(hike.durationSeconds == expected, "\(shape)")
        #expect(hike.durationSeconds == hike.routeStatistics.duration, "\(shape)")
    }
}
