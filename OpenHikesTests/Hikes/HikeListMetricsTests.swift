//
//  HikeListMetricsTests.swift
//  OpenHikesTests
//
//  What gets cached for an elevation order, and what deliberately does not.
//
//  Both halves are assertions about *agreement*. The figure this caches is the
//  one the detail screen shows for the same hike, so it has to be measured the
//  way that screen measures it; and a route with no heights has to stay
//  missing, because ``HikeListSort`` sorts a missing figure last and a zero as
//  a flat walk.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

// swiftlint:disable no_magic_numbers

@Suite("The elevation figures a library is sorted by")
struct HikeListMetricsTests {
    @Test("a noisy flat track does not accumulate a mountain of phantom climb")
    func sensorNoiseIsNotClimb() throws {
        let container = try Fixture.modelContainer()
        let context = ModelContext(container)
        // A phone on a table: two hundred points wandering a metre and a half
        // either side of the same height. Summing `max(delta, 0)` over this
        // integrates the noise in one direction forever — the deadband is what
        // makes it nothing, and is why this goes through the same accumulator
        // the detail screen uses.
        let hike = Fixture.hike(in: context, title: "Flat", route: Self.noisyFlatRoute)
        try context.save()

        _ = HikeListMetrics.fillElevation(for: [hike.id], in: container)

        let climb = try #require(refetched(hike.id, in: container)?.climbMeters)
        #expect(climb < 10)
    }

    @Test("a real climb is still measured")
    func aRealClimbSurvivesTheDeadband() throws {
        let container = try Fixture.modelContainer()
        let context = ModelContext(container)
        let hike = Fixture.hike(in: context, title: "Up", route: Self.climbingRoute)
        try context.save()

        _ = HikeListMetrics.fillElevation(for: [hike.id], in: container)

        let saved = try #require(refetched(hike.id, in: container))
        let climb = try #require(saved.climbMeters)
        // Five hundred metres of genuine ascent, which no deadband should eat.
        #expect(climb > 400)
        #expect(saved.descentMeters ?? -1 >= 0)
    }

    @Test("a route with no heights is left unmeasured rather than filed as flat")
    func aHeightlessRouteCachesNothing() throws {
        let container = try Fixture.modelContainer()
        let context = ModelContext(container)
        // A GPX imported without `<ele>`. Zero would be a claim that the walk
        // was level, and `HikeListSort` reads zero as exactly that — so it
        // stays missing and sorts last.
        let hike = Fixture.hike(in: context, title: "No Heights", route: Self.heightlessRoute)
        try context.save()

        _ = HikeListMetrics.fillElevation(for: [hike.id], in: container)

        let saved = try #require(refetched(hike.id, in: container))
        #expect(saved.climbMeters == nil)
        #expect(saved.descentMeters == nil)
    }

    /// The row as a *fresh* context sees it, which is the only way to tell a
    /// value that was written from one that is merely sitting in the context
    /// the sweep used.
    ///
    /// Not named `saved`, which is what the callers below call their results:
    /// a local of the same name shadows this inside its own initializer, and
    /// Xcode 26.6 reads `saved(…)` as a call on the `Hike` being bound rather
    /// than on this, where 27 resolves it here. CI ran 26.6 when that was
    /// found and runs 27 now, so the name is no longer load-bearing — it stays
    /// because a helper that says what it fetches beats one that collides with
    /// every caller's local.
    private func refetched(_ hikeID: UUID, in container: ModelContainer) -> Hike? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Two hundred points wandering inside a metre of one height.
    ///
    /// Deliberately *inside* the deadband rather than across it: the amplitude
    /// is what the accumulator's own header describes as a phone resting on a
    /// table, and a fixture that swung the full three metres would be sitting
    /// exactly on the threshold it is meant to be testing the far side of.
    /// The pattern is a repeating wander rather than a square wave so the runs
    /// have different lengths, which is what a real sensor produces.
    private static let noisyFlatRoute: [RouteCoordinate] = (0..<200).map { step in
        let wobble = [0.0, 0.9, -0.6, 0.4, -1.0, 0.7, -0.3, 0.8][step % 8]
        return RouteCoordinate(
            latitude: 47.5530 + Double(step) * 0.0001,
            longitude: 12.9880,
            elevation: 600 + wobble
        )
    }

    private static let climbingRoute: [RouteCoordinate] = (0..<100).map { step in
        RouteCoordinate(
            latitude: 47.5530 + Double(step) * 0.0001,
            longitude: 12.9880,
            elevation: 600 + Double(step) * 5
        )
    }

    private static let heightlessRoute: [RouteCoordinate] = (0..<50).map { step in
        RouteCoordinate(latitude: 47.5530 + Double(step) * 0.0001, longitude: 12.9880)
    }
}

// swiftlint:enable no_magic_numbers
