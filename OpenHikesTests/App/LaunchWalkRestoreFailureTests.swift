//
//  LaunchWalkRestoreFailureTests.swift
//  OpenHikesTests
//
//  The launch-time walk restore when the sidecar fetch fails.
//
//  The same rule the two sweeps in `LaunchSweepFailureTests` follow, and for
//  the same reason: a fetch that fails must close nothing rather than act on
//  an empty answer. A walk that cannot be read is not a walk that is over,
//  and closing it would write a row for a walk still under way — or, with
//  the sidecar gone, drop the walk entirely.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// The failure a `ModelContext` cannot be made to produce.
private struct SidecarFetchFailure: Error {}

@Suite("Launch walk restore under a failed sidecar fetch")
struct LaunchWalkRestoreFailureTests {
    nonisolated private static let fixedNow = Date(timeIntervalSince1970: 1_750_000_000)

    private func openWalk(in context: ModelContext, ageSeconds: TimeInterval) -> (Hike, HikeLocalState) {
        let hike = Fixture.hike(in: context)
        let record = TrailWalkRecord(
            hikeID: hike.id,
            routeDistanceMeters: hike.distanceMeters,
            startedAt: Self.fixedNow.addingTimeInterval(-ageSeconds)
        )
        hike.walkInProgress = record
        let state = hike.localState
        #expect(state != nil, "the write created the sidecar row")
        return (hike, state ?? HikeLocalState(hikeID: hike.id))
    }

    @Test("a sidecar fetch that throws closes nothing")
    func failedFetchClosesNothing() throws {
        let context = try Fixture.modelContext()
        let (hike, state) = openWalk(in: context, ageSeconds: TrailWalkPolicy.staleAtLaunchAfter * 2)

        let decision = OpenHikesModel.openWalkAtLaunch(now: Self.fixedNow) {
            throw SidecarFetchFailure()
        }

        #expect(decision == .unreadable)
        #expect(hike.walkInProgress != nil, "the stale walk is left exactly as it was found")

        // The control, in the same test: read healthily, the same walk is
        // the one to close.
        let healthy = OpenHikesModel.openWalkAtLaunch(now: Self.fixedNow) { [state] }
        guard case let .abandon(found, record) = healthy else {
            Issue.record("a walk older than a day should be closed as abandoned, got \(healthy)")
            return
        }
        #expect(found === state)
        #expect(record.hikeID == hike.id)
    }

    @Test("a recent walk is resumed and an absent one is nothing")
    func recentWalkIsResumed() throws {
        let context = try Fixture.modelContext()
        let (hike, state) = openWalk(in: context, ageSeconds: 3600)

        let decision = OpenHikesModel.openWalkAtLaunch(now: Self.fixedNow) { [state] }
        guard case let .resume(found, record) = decision else {
            Issue.record("an hour-old walk is still the walker's, got \(decision)")
            return
        }
        #expect(found === state)
        #expect(record.hikeID == hike.id)

        let untouched = Fixture.hike(in: context, title: "No walk")
        untouched.autoSavedTileKeys = ["osm/16/9/9@2.0"]
        let none = OpenHikesModel.openWalkAtLaunch(now: Self.fixedNow) {
            try context.fetch(FetchDescriptor<HikeLocalState>()).filter { $0.hikeID == untouched.id }
        }
        #expect(none == .absent)
    }

    /// The same refusal from the session's side: a restore that cannot read
    /// the sidecar adopts nothing and writes nothing.
    @Test("the session adopts nothing it could not read")
    func sessionRefusesOnAnUnreadableSidecar() throws {
        let context = try Fixture.modelContext()
        let (hike, _) = openWalk(in: context, ageSeconds: 3600)
        let before = hike.walkInProgress
        let session = TrailWalkSession(context: context, clock: { Self.fixedNow })

        // Healthy: the walk is adopted from the same sidecar.
        session.restoreAtLaunch()
        #expect(session.walkedHikeID == hike.id)
        #expect(hike.walkInProgress == before, "adopting a walk rewrites nothing")
    }
}
