//
//  HikeRouteObservationTests.swift
//  OpenHikesDataTests
//
//  The library registers a route dependency without loading its external
//  value. Exercise the actual @Model registrar and keep unrelated styling
//  changes from turning that dependency into a route-validation trigger.
//

import Observation
@testable import OpenHikesData
import Synchronization
import Testing

@Suite("Route observation without reading its stored value")
struct HikeRouteObservationTests {
    nonisolated private final class Changes: Sendable {
        private let value = Mutex(0)

        var count: Int { value.withLock { $0 } }

        func record() { value.withLock { $0 += 1 } }
    }

    @Test("a route dependency receives route mutations and ignores a tint change")
    func routeDependencyIsSpecific() {
        let hike = Hike(title: "Trail", distanceMeters: 0)
        let changes = Changes()
        withObservationTracking {
            hike.trackRouteChanges()
        } onChange: {
            changes.record()
        }

        hike.tintHex = "#FFFFFF"
        #expect(changes.count == 0)
        hike.replaceRoute(with: [
            RouteCoordinate(latitude: 47, longitude: 19, elevation: 100),
            RouteCoordinate(latitude: 47.001, longitude: 19, elevation: 200),
        ])
        #expect(changes.count == 1)
    }
}
