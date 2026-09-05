//
//  LaunchLocalStateSweepTests.swift
//  OpenHikesTests
//
//  The launch sweep that collects `HikeLocalState` rows whose hike is gone.
//
//  The companion to `LaunchSweepFailureTests`, whose two sweeps collect files;
//  this one collects a row, and it exists because a sidecar is the one thing
//  in the app nothing else can reach. The stores cannot be related, so nothing
//  cascades, and `Hike.deleteLocalState()` — the only thing that removes one —
//  runs on the local deletion path alone. A hike deleted on the walker's other
//  device arrives as a mirrored row deletion that cannot touch this store, and
//  what it leaves behind carries a `walkInProgress` that `openWalkAtLaunch` then
//  prefers over every real one, launch after launch.
//
//  The rule is the one both file sweeps follow, and the stake is higher here
//  than the wording suggests: a `Hike` fetch that came back empty because it
//  *failed* makes every sidecar on the device an orphan, and a sidecar is
//  where this device's whole record of what it has downloaded lives. So the
//  fetch is a closure, for the reason spelled out in the other file — nothing
//  makes a `ModelContext` throw on demand, and without the seam the `guard`
//  could be rewritten as `?? []` with every test still green.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// The failure a `ModelContext` cannot be made to produce.
private struct StoreFetchFailure: Error {}

@Suite("Launch orphaned local state sweep")
struct LaunchLocalStateSweepTests {
    /// What a red run means, in the terms the user would meet it.
    private static let emptyClaimComment: Comment = """
        The failed fetch swept with an empty hike list. In the app this deletes every device-local \
        sidecar there is, at launch — every hike's record of the map it downloaded for a valley \
        with no signal, and the walk it has under way.
        """

    /// A live hike with a sidecar, and an orphaned sidecar beside it: the row
    /// left behind when a hike goes without `deleteLocalState()`, which is
    /// every way a hike can go except the swipe in `MapSheet`.
    private struct Fixtures {
        let context: ModelContext
        let live: Hike
        let orphanedHikeID: UUID
    }

    private func fixtures() throws -> Fixtures {
        let context = try Fixture.modelContext()
        let live = Fixture.hike(in: context, title: "Still in the library")
        live.autoSavedTileKeys = ["osm/14/8723/5685@2.0"]
        let doomed = Fixture.hike(in: context, title: "Deleted on the other phone")
        doomed.autoSavedTileKeys = ["osm/14/8724/5685@2.0"]
        let doomedID = doomed.id
        // The mirrored deletion, as this store sees it: the row goes and the
        // sidecar is not so much as looked at.
        context.delete(doomed)
        try context.save()
        try #require(
            sidecars(in: context).count == 2,
            "the deleted hike's sidecar is what this suite is about"
        )
        return Fixtures(context: context, live: live, orphanedHikeID: doomedID)
    }

    private func sidecars(in context: ModelContext) -> [HikeLocalState] {
        (try? context.fetch(FetchDescriptor<HikeLocalState>())) ?? []
    }

    /// The sweep as the app runs it, with both fetches and the deletion going
    /// to the same context the instance method hands them.
    @discardableResult private func sweep(
        _ context: ModelContext,
        fetchingHikes fetchHikes: (() throws -> [Hike])? = nil
    ) -> [HikeLocalState] {
        OpenHikesModel.reclaimOrphanedLocalStates(
            fetchingHikes: fetchHikes ?? { try context.fetch(FetchDescriptor<Hike>()) },
            fetchingLocalStates: { try context.fetch(FetchDescriptor<HikeLocalState>()) },
            deleting: { orphans in
                for orphan in orphans { context.delete(orphan) }
                try context.save()
            }
        )
    }

    @Test("the orphaned sidecar goes and a live hike's is left alone")
    func sweepsTheOrphanOnly() throws {
        let fixtures = try fixtures()

        let swept = sweep(fixtures.context)

        #expect(swept.count == 1)
        #expect(swept.first?.hikeID == fixtures.orphanedHikeID)
        let left = sidecars(in: fixtures.context)
        #expect(left.count == 1)
        #expect(left.first?.hikeID == fixtures.live.id)
        #expect(
            fixtures.live.autoSavedTileKeys == ["osm/14/8723/5685@2.0"],
            "and the surviving hike still knows what it has on disk"
        )
    }

    @Test("a hike fetch that throws sweeps nothing, not even the orphan")
    func failedHikeFetchSweepsNothing() throws {
        let fixtures = try fixtures()

        let swept = sweep(fixtures.context) { throw StoreFetchFailure() }

        #expect(swept.isEmpty, Self.emptyClaimComment)
        #expect(sidecars(in: fixtures.context).count == 2, Self.emptyClaimComment)

        // The control, in the same test: read healthily, the orphan was
        // sweepable all along.
        #expect(sweep(fixtures.context).count == 1)
        #expect(sidecars(in: fixtures.context).count == 1)
    }

    @Test("a sidecar fetch that throws sweeps nothing")
    func failedSidecarFetchSweepsNothing() throws {
        let fixtures = try fixtures()

        let swept = OpenHikesModel.reclaimOrphanedLocalStates(
            fetchingHikes: { try fixtures.context.fetch(FetchDescriptor<Hike>()) },
            fetchingLocalStates: { throw StoreFetchFailure() },
            deleting: { _ in
                Issue.record("a sidecar fetch that failed must not reach a deletion")
            }
        )

        #expect(swept.isEmpty)
        #expect(sidecars(in: fixtures.context).count == 2)
    }

    /// A commit the store refuses leaves the row for the next launch rather
    /// than reporting it gone — the same answer a refused deletion gives in
    /// `HikeDeletion`.
    @Test("a deletion the store refuses is reported as nothing swept")
    func refusedDeletionSweepsNothing() throws {
        let fixtures = try fixtures()

        let swept = OpenHikesModel.reclaimOrphanedLocalStates(
            fetchingHikes: { try fixtures.context.fetch(FetchDescriptor<Hike>()) },
            fetchingLocalStates: { try fixtures.context.fetch(FetchDescriptor<HikeLocalState>()) },
            deleting: { _ in throw StoreFetchFailure() }
        )

        #expect(swept.isEmpty)
        #expect(sidecars(in: fixtures.context).count == 2)
    }

    /// A library with no hikes at all is an honest empty answer, and it
    /// sweeps: every sidecar there is belongs to a hike that is gone.
    @Test("an empty library is an honest answer, and sweeps every sidecar")
    func emptyLibrarySweepsEverything() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, title: "About to go")
        hike.autoSavedTileKeys = ["osm/14/8724/5685@2.0"]
        context.delete(hike)
        try context.save()

        #expect(sweep(context).count == 1)
        #expect(sidecars(in: context).isEmpty)
    }
}
