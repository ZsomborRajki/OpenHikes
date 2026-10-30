//
//  HikeLineRevisionTests.swift
//  OpenHikesDataTests
//
//  The line revision is what a reader of a hike's line watches: it moves when
//  the line is replaced through this instance, and at no other write. A
//  refresh after another context's save notifies every persisted property of
//  a registered hike, so the revision being unpersisted is the whole point.
//  The refresh itself needs a live `@Query` and is measured by the app's
//  suites.
//

import Observation
@testable import OpenHikesData
import Synchronization
import Testing

@Suite("A hike's line revision")
struct HikeLineRevisionTests {
    nonisolated private final class Changes: Sendable {
        private let value = Mutex(0)

        var count: Int { value.withLock { $0 } }

        func record() { value.withLock { $0 += 1 } }
    }

    private static let newLine = [
        RouteCoordinate(latitude: 47, longitude: 19, elevation: 100),
        RouteCoordinate(latitude: 47.001, longitude: 19, elevation: 200),
    ]

    private static func watching(_ hike: Hike) -> Changes {
        let changes = Changes()
        withObservationTracking {
            hike.trackLineReplacements()
        } onChange: {
            changes.record()
        }
        return changes
    }

    @Test("replacing the line moves the revision and tells whoever watches it")
    func replacingTheLineMovesTheRevision() {
        let hike = Hike(title: "Trail", distanceMeters: 0)
        let changes = Self.watching(hike)

        hike.replaceRoute(with: Self.newLine)

        #expect(changes.count == 1)
        #expect(hike.lineRevision == 1)
        #expect(hike.route == Self.newLine, "the line is in place before the revision moves")
    }

    @Test("a write to anything but the line leaves the revision alone")
    func otherWritesLeaveTheRevisionAlone() {
        let hike = Hike(title: "Trail", distanceMeters: 0)
        let changes = Self.watching(hike)

        hike.tintHex = "#FFFFFF"
        hike.routeWidth = 7
        hike.title = "Renamed"
        hike.customName = "Ridge"

        #expect(changes.count == 0)
        #expect(hike.lineRevision == 0)
    }

    @Test("every replacement counts, and the route watch hears the first")
    func everyReplacementCounts() {
        let hike = Hike(title: "Trail", distanceMeters: 0)
        let routeChanges = Changes()
        withObservationTracking {
            hike.trackRouteChanges()
        } onChange: {
            routeChanges.record()
        }

        hike.replaceRoute(with: Self.newLine)
        hike.replaceRoute(with: Self.newLine)
        hike.replaceRoute(with: [])

        #expect(hike.lineRevision == 3, "an identical line counts too: the readers compare before they rebuild")
        #expect(routeChanges.count == 1, "a one-shot registration")
    }
}
