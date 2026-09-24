//
//  TrailDraftClimbTimeTests.swift
//  OpenHikesTests
//
//  The trail maker's time once the line's climb is known — see
//  `TrailDraft.travelTime(climb:)`. A flat 4 km/h was out by a factor of two on
//  exactly the alpine routes where the time matters most.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

@MainActor
@Suite("Trail draft climb time")
struct TrailDraftClimbTimeTests {
    private static let longitude = -122.03

    /// Two stops about 1.1 km apart, so the flat time is about seventeen
    /// minutes and a climb of a few hundred metres dominates it.
    private func twoStops(_ mode: TrailTravelMode = .hiking) -> TrailDraft {
        let draft = TrailDraft()
        draft.addStop(CLLocationCoordinate2D(latitude: 37.330, longitude: Self.longitude))
        draft.addStop(CLLocationCoordinate2D(latitude: 37.340, longitude: Self.longitude))
        draft.setTravelMode(mode)
        return draft
    }

    private static func climb(gain: Double, loss: Double) -> RouteElevationSummary {
        var accumulator = ElevationAccumulator()
        // Down by `loss`, then up by `gain`, far past the deadband.
        accumulator.record(1000)
        accumulator.record(1000 - loss)
        accumulator.record(1000 - loss + gain)
        return RouteElevationSummary(accumulator)
    }

    @Test("a hiking line with a climb is timed by DIN 33466")
    func hikingCountsTheClimb() {
        let draft = twoStops()
        let climb = Self.climb(gain: 600, loss: 100)
        let expected = WalkingTimeEstimate.seconds(
            distanceMeters: draft.distanceMeters,
            ascentMeters: 600,
            descentMeters: 100
        )

        #expect(abs(draft.travelTime(climb: climb) - expected) < 0.001)
        #expect(draft.travelTime(climb: climb) > draft.travelTime * 2, "the climb dominates this line")
    }

    /// The figure is settling for two seconds after every edit, and a free
    /// hiker never has one; both keep the flat pace.
    @Test("with no heights yet, a hiking line keeps its flat pace")
    func noClimbKeepsTheFlatPace() {
        let draft = twoStops()
        #expect(draft.travelTime(climb: nil) == draft.travelTime)
        #expect(draft.climbFactor(nil) == 1)
    }

    /// Apple Maps' estimate already knows its roads, and a bicycle or a car
    /// is not timed by a hiking standard.
    @Test("walking, cycling and driving are not rescaled by the climb")
    func otherModesIgnoreTheClimb() {
        let climb = Self.climb(gain: 600, loss: 100)
        for mode in [TrailTravelMode.walking, .cycling, .driving] {
            let draft = twoStops(mode)
            #expect(draft.travelTime(climb: climb) == draft.travelTime, "\(mode)")
        }
    }

    /// DIN never takes less than the flat pace, and a gentle line's rounding
    /// must not show a hiking line as faster than its own flat figure.
    @Test("a climb never makes a line quicker")
    func aClimbNeverSpeedsUp() {
        let draft = twoStops()
        #expect(draft.climbFactor(Self.climb(gain: 3, loss: 3)) >= 1)
    }

    /// The map's bubble is redrawn when the climb lands, because the drawn
    /// state it is compared by carries it.
    @Test("a climb landing is a change the map redraws the bubbles for")
    func theClimbIsPartOfWhatIsDrawn() {
        let draft = twoStops()
        let before = TrailDraftDrawnState(draft, climb: nil)
        let after = TrailDraftDrawnState(draft, climb: Self.climb(gain: 600, loss: 100))
        #expect(before != after)
    }
}
