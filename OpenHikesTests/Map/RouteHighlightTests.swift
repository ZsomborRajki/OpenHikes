//
//  RouteHighlightTests.swift
//  OpenHikesTests
//
//  "Route highlight", split out of RenderIsolationTests.swift so that a file
//  declares one @Suite. That file's header still holds the context the two
//  share.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import SwiftUI
import Testing

@Suite("Route highlight")
struct RouteHighlightTests {
    private static let viewpoint = CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600)

    /// The pin has to reach the map when it genuinely moves — the guard below
    /// is only worth having if this still holds.
    @Test("placing and moving the pin reaches the map")
    func movesArePublished() async {
        let highlight = RouteHighlight()
        let counter = ObservationCounter { _ = highlight.coordinate }
        await counter.settle()

        highlight.move(to: Self.viewpoint)
        await counter.settle()
        #expect(counter.count == 1)

        highlight.move(to: CLLocationCoordinate2D(latitude: 47.6400, longitude: 12.8600))
        await counter.settle()
        #expect(counter.count == 2)
        #expect(highlight.coordinate?.latitude == 47.64)
    }

    /// `CLLocationCoordinate2D` isn't `Equatable` (pinned by `an equal write to
    /// a coordinate notifies anyway`), so without the comparison in
    /// `move(to:)` this is a notification for a pin that hasn't moved.
    @Test("moving the pin where it already is doesn't wake the map")
    func repeatedPositionIsNotRepublished() async {
        let highlight = RouteHighlight()
        let counter = ObservationCounter { _ = highlight.coordinate }
        await counter.settle()

        highlight.move(to: Self.viewpoint)
        await counter.settle()
        #expect(counter.count == 1, "precondition: placing the pin reaches the map")

        highlight.move(to: CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600))
        await counter.settle()
        #expect(counter.count == 1, "same place — the map's annotation is already there")
        #expect(highlight.coordinate?.latitude == 47.63, "and the pin is still where it belongs")
    }

    @Test("clearing a placed pin reaches the map")
    func clearingIsPublished() async {
        let highlight = RouteHighlight()
        highlight.move(to: Self.viewpoint)
        let counter = ObservationCounter { _ = highlight.coordinate }
        await counter.settle()

        highlight.move(to: nil)
        await counter.settle()
        #expect(counter.count == 1)
        #expect(highlight.coordinate == nil)
    }

    /// `updateLiveFollow` hides the pin on every matched fix while auto-follow
    /// owns the map. Only the first of those has anything to say.
    @Test("auto-follow's per-second clear reaches the map once")
    func repeatedClearIsSilentAfterTheFirst() async {
        let highlight = RouteHighlight()
        highlight.move(to: Self.viewpoint)
        let counter = ObservationCounter { _ = highlight.coordinate }
        await counter.settle()

        for _ in 0..<5 {
            highlight.move(to: nil)
            await counter.settle()
        }
        #expect(counter.count == 1, "the pin is hidden once; the next four polls have nothing to say")
        #expect(highlight.coordinate == nil)
    }

    /// The hot path this type exists for. Scrubbing now interpolates continuously
    /// along route segments, so each distinct distance should move the pin, while
    /// repeated drag samples at the same distance must still be filtered before
    /// they re-register the map coordinator's observation through a `Task` hop.
    ///
    /// Settling between events on purpose: drag events arrive in separate
    /// runloop turns, so this counts them the way the map would see them
    /// rather than letting a synchronous burst coalesce into one.
    @Test("a drag moves the pin once per distinct interpolated position")
    func scrubbingWritesOncePerDistinctPosition() async throws {
        let profile = RouteProfile(route: Fixture.ridgeRoute)
        let total = try #require(profile.distances.last)
        let highlight = RouteHighlight()
        let counter = ObservationCounter { _ = highlight.coordinate }
        await counter.settle()

        var dragEvents = 0
        var distinctPositions = 0
        for distance in stride(from: 0, through: total, by: 10) {
            let coordinate = profile.coordinate(atDistance: distance)
            highlight.move(to: coordinate)
            dragEvents += 1
            await counter.settle()
            highlight.move(to: coordinate)
            dragEvents += 1
            distinctPositions += 1
            await counter.settle()
        }

        #expect(dragEvents == distinctPositions * 2, "precondition: every position is submitted twice")
        #expect(
            counter.count == distinctPositions,
            "interpolated movement publishes, while repeating the same position remains silent"
        )
    }
}
