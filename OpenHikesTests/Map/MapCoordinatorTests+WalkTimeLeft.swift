//
//  MapCoordinatorTests+WalkTimeLeft.swift
//  OpenHikesTests
//
//  The walk under way's time left, standing on its line: drawn over the
//  walked hike's route alone, moved along it by matched fixes, and held back
//  while the app is in the background. See `MapCoordinator+WalkTimeLeft.swift`.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Testing
#if canImport(UIKit)
import UIKit
#endif

extension MapCoordinatorTests {
    /// A walk on `Fixture.outAndBackRoute` in a store of its own, held for as
    /// long as the test needs the hike.
    private struct WalkUnderWay {
        let container: ModelContainer
        let session: TrailWalkSession
        let hike: Hike
        let profile: RouteProfile
        let clock: TestClock

        @MainActor
        init(clock: TestClock) throws {
            container = try Fixture.modelContainer()
            let context = ModelContext(container)
            self.clock = clock
            session = TrailWalkSession(context: context, clock: clock.read)
            hike = Fixture.hike(in: context, title: "Ridge Loop", route: Fixture.outAndBackRoute)
            profile = RouteProfile(route: hike.route)
        }

        /// One match per route point, a minute apart, as
        /// `TrailWalkSessionTests` feeds them.
        @MainActor
        func walk(from start: Int, through end: Int) {
            for index in start...end {
                clock.advance(by: 60)
                session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[index])
            }
        }

        var route: DisplayedRoute {
            DisplayedRoute(id: hike.id, coordinates: Fixture.coordinates(hike.route))
        }
    }

    /// Degrees: the mark and the annotation are the same coordinate, copied.
    private static let placeTolerance = 1e-9

    private static func expectSamePlace(
        _ annotation: WalkTimeLeftAnnotation?,
        as mark: WalkTimeLeftMark,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let latitude = annotation?.coordinate.latitude
        let longitude = annotation?.coordinate.longitude
        #expect(
            mark.coordinate.latitude.isApproximatelyEqual(to: latitude ?? .nan, absoluteTolerance: placeTolerance),
            sourceLocation: sourceLocation
        )
        #expect(
            mark.coordinate.longitude.isApproximatelyEqual(to: longitude ?? .nan, absoluteTolerance: placeTolerance),
            sourceLocation: sourceLocation
        )
    }

    @Test("a walk under way stands its time left halfway along its own line")
    func aWalkStandsItsTimeLeftOnItsLine() throws {
        let walk = try WalkUnderWay(clock: clock)
        walk.walk(from: 0, through: 3)
        let coordinator = MapView.Coordinator()
        let view = mapView(route: walk.route, walk: walk.session)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)

        let mark = try #require(walk.session.timeLeftMark())
        let drawn = try #require(coordinator.walkTimeLeft.annotation)
        #expect(map.annotations.contains { $0 === drawn })
        Self.expectSamePlace(drawn, as: mark)
        #expect(drawn.seconds == mark.seconds)
        #expect(drawn.title == String(localized: "\(HikeFormat.travelTime(mark.seconds)) left"))

        #if os(iOS)
        let bubble = try #require(coordinator.mapView(map, viewFor: drawn))
        #expect(bubble is WalkTimeLeftView)
        #expect(bubble.accessibilityIdentifier == "walk-time-left")
        #expect(bubble.accessibilityLabel == drawn.spokenDescription)
        #endif
    }

    /// The bubble stands on the walked line and takes the tap from it, so it
    /// opens what the line opens rather than nothing.
    @Test("a tap on the time left opens the walked hike, as a tap on its line does")
    func aTapOnTheTimeLeftOpensTheWalkedHike() throws {
        #if os(iOS)
        let walk = try WalkUnderWay(clock: clock)
        walk.walk(from: 0, through: 3)
        let coordinator = MapView.Coordinator()
        let view = mapView(route: walk.route, walk: walk.session)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        var opened = 0
        drawnRouteTap.onOpen { opened += 1 }

        let drawn = try #require(coordinator.walkTimeLeft.annotation)
        let bubble = try #require(coordinator.mapView(map, viewFor: drawn))
        #expect(bubble.accessibilityTraits.contains(.button))
        coordinator.mapView(map, didSelect: bubble)

        #expect(opened == 1)
        #expect(!map.selectedAnnotations.contains { $0 === drawn }, "let go of, so a second tap is heard")
        #endif
    }

    /// The walk outlives its screen; a time left over a line the map is not
    /// drawing would be a bubble in a field.
    @Test("the time left follows the walked hike's line on and off the map")
    func theTimeLeftFollowsTheSelection() throws {
        let walk = try WalkUnderWay(clock: clock)
        walk.walk(from: 0, through: 3)
        let coordinator = MapView.Coordinator()
        let other = Self.route()
        let map = makeMap(mapView(route: other, walk: walk.session), coordinator)
        defer { detach(map) }

        mapView(route: other, walk: walk.session).update(map, coordinator)
        #expect(coordinator.walkTimeLeft.annotation == nil, "another hike's line carries no time left")

        mapView(route: walk.route, walk: walk.session).update(map, coordinator)
        let drawn = try #require(coordinator.walkTimeLeft.annotation)
        #expect(map.annotations.contains { $0 === drawn })

        mapView(route: nil, walk: walk.session).update(map, coordinator)
        #expect(coordinator.walkTimeLeft.annotation == nil)
        #expect(!map.annotations.contains { $0 is WalkTimeLeftAnnotation })
    }

    @Test("a matched fix slides the time left along the line rather than dropping another")
    func aMatchSlidesTheTimeLeft() async throws {
        let walk = try WalkUnderWay(clock: clock)
        walk.walk(from: 0, through: 3)
        let coordinator = MapView.Coordinator()
        let view = mapView(route: walk.route, walk: walk.session)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        let drawn = try #require(coordinator.walkTimeLeft.annotation)
        let before = drawn.coordinate

        walk.walk(from: 4, through: 6)
        let mark = try #require(walk.session.timeLeftMark())
        await settle(until: "the time left to move with the walk") {
            drawn.coordinate.latitude != before.latitude || drawn.coordinate.longitude != before.longitude
        }

        #expect(coordinator.walkTimeLeft.annotation === drawn)
        #expect(map.annotations.filter { $0 is WalkTimeLeftAnnotation }.count == 1)
        Self.expectSamePlace(drawn, as: mark)
        #expect(drawn.seconds == mark.seconds)
    }

    @Test("a walk that ends takes its time left off the map")
    func anEndedWalkTakesItsTimeLeftAway() async throws {
        let walk = try WalkUnderWay(clock: clock)
        walk.walk(from: 0, through: 3)
        let coordinator = MapView.Coordinator()
        let view = mapView(route: walk.route, walk: walk.session)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        #expect(coordinator.walkTimeLeft.annotation != nil)

        walk.session.end()
        await settle(until: "the time left to leave the map") {
            coordinator.walkTimeLeft.annotation == nil
        }
        #expect(!map.annotations.contains { $0 is WalkTimeLeftAnnotation })
    }

    #if os(iOS)
    /// A walk is matched in a pocket all afternoon; the bubble is owed one
    /// pass on return, not one per fix to nobody.
    @Test("a walk that moves in the background moves its time left on return")
    func theBackgroundHoldsTheTimeLeftBack() async throws {
        let walk = try WalkUnderWay(clock: clock)
        walk.walk(from: 0, through: 3)
        let coordinator = MapView.Coordinator()
        let view = mapView(route: walk.route, walk: walk.session)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        view.update(map, coordinator)
        let drawn = try #require(coordinator.walkTimeLeft.annotation)
        let before = drawn.coordinate

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        defer {
            NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        }
        walk.walk(from: 4, through: 6)
        await settle(until: "the walk's move to be noted for the return") {
            coordinator.walkTimeLeft.isPending
        }
        #expect(drawn.coordinate.latitude == before.latitude && drawn.coordinate.longitude == before.longitude)

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        let mark = try #require(walk.session.timeLeftMark())
        #expect(!coordinator.walkTimeLeft.isPending)
        Self.expectSamePlace(drawn, as: mark)
    }
    #endif
}
