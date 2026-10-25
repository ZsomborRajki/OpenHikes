//
//  HikePlaceRowsInvalidationTests.swift
//  OpenHikesTests
//
//  A measured absence must be reused for unchanged inputs and discarded when
//  a place moves or a paused leg becomes walked, on either measurement path.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

@MainActor
@Suite("Hike place row invalidation")
struct HikePlaceRowsInvalidationTests {
    nonisolated private final class Tally: Sendable {
        private let batches = Mutex<[Int]>([])

        var sizes: [Int] { batches.withLock { $0 } }

        func measure(_ places: [TrailPlace], _ route: [RouteCoordinate]) -> [UUID: TrailPlaceAnchor] {
            batches.withLock { $0.append(places.count) }
            return TrailPlaceOrder.anchors(of: places, along: route)
        }
    }

    private static var pausedRoute: [RouteCoordinate] {
        [
            RouteCoordinate(latitude: 47.60, longitude: 12.98, boundary: .paused),
            RouteCoordinate(latitude: 47.602, longitude: 12.98, boundary: .paused),
        ]
    }

    private static func rows(_ tally: Tally, budget: Int) -> HikePlaceRows {
        HikePlaceRows(budget: budget) { places, route in tally.measure(places, route) }
    }

    private func landed(_ rows: HikePlaceRows, revision: Int, budget: Int) async {
        guard budget == 0 else { return }
        await settleDelegateHop(until: "measurement \(revision) lands") { rows.revision == revision }
    }

    @Test("changing only a leg's pause replaces its cached absence", arguments: [false, true])
    func boundaryChangeMeasuresAgain(offMainThread: Bool) async throws {
        let budget = offMainThread ? 0 : HikePlaceRows.synchronousBudget
        let owner = UUID()
        let tally = Tally()
        let rows = Self.rows(tally, budget: budget)
        let places = [TrailPlace(latitude: 47.601, longitude: 12.98, name: "Spring")]
        var route = Self.pausedRoute

        _ = rows.rows(of: places, along: route, for: owner)
        await landed(rows, revision: 1, budget: budget)
        #expect(rows.rows(of: places, along: route, for: owner).allSatisfy { $0.offRouteMeters == nil })
        #expect(tally.sizes == [1])

        // The first point's boundary has no arriving leg. Keeping it paused
        // must not prevent the now-walked leg from anchoring the place.
        route[1].boundary = nil
        _ = rows.rows(of: places, along: route, for: owner)
        await landed(rows, revision: 2, budget: budget)
        let walked = try #require(rows.rows(of: places, along: route, for: owner).first)
        #expect(walked.anchor != nil)
        #expect(walked.isOnTheLine)
        #expect(tally.sizes == [1, 1])

        route[1].boundary = .paused
        _ = rows.rows(of: places, along: route, for: owner)
        await landed(rows, revision: 3, budget: budget)
        let paused = rows.rows(of: places, along: route, for: owner)
        #expect(paused.allSatisfy { $0.anchor == nil && $0.offRouteMeters == nil })
        #expect(paused.map(\.id) == places.map(\.id))
        #expect(tally.sizes == [1, 1, 1])
    }

    @Test("moved and re-added unanchored places are measured alone", arguments: [false, true])
    func changedSpotsMeasureAgain(offMainThread: Bool) async {
        let budget = offMainThread ? 0 : HikePlaceRows.synchronousBudget
        let owner = UUID()
        let tally = Tally()
        let rows = Self.rows(tally, budget: budget)
        let route = Self.pausedRoute
        var places = [
            TrailPlace(latitude: 47.601, longitude: 12.98, name: "Spring"),
            TrailPlace(latitude: 47.6015, longitude: 12.98, name: "Shelter"),
        ]

        _ = rows.rows(of: places, along: route, for: owner)
        await landed(rows, revision: 1, budget: budget)
        places[0].name = "Renamed spring"
        let renamed = rows.rows(of: places, along: route, for: owner)
        #expect(renamed.first?.place.name == "Renamed spring")
        #expect(tally.sizes == [2])

        places[0].latitude += 0.0001
        _ = rows.rows(of: places, along: route, for: owner)
        await landed(rows, revision: 2, budget: budget)
        _ = rows.rows(of: places, along: route, for: owner)
        #expect(tally.sizes == [2, 1])

        places[0].longitude += 0.0001
        _ = rows.rows(of: places, along: route, for: owner)
        await landed(rows, revision: 3, budget: budget)
        _ = rows.rows(of: places, along: route, for: owner)
        #expect(tally.sizes == [2, 1, 1])

        let removed = places.removeFirst()
        _ = rows.rows(of: places, along: route, for: owner)
        #expect(tally.sizes == [2, 1, 1], "removing a place measures nothing")
        places.append(removed)
        _ = rows.rows(of: places, along: route, for: owner)
        await landed(rows, revision: 4, budget: budget)
        let restored = rows.rows(of: places, along: route, for: owner)
        #expect(restored.map(\.id) == places.map(\.id))
        #expect(restored.allSatisfy { $0.anchor == nil && $0.offRouteMeters == nil })
        #expect(tally.sizes == [2, 1, 1, 1])
    }
}
