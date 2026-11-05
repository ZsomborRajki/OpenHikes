//
//  LibraryLinesTests+FailedListings.swift
//  OpenHikesTests
//
//  A listing that fails keeps what is drawn, and spends neither the wake it
//  had nor the rows that wake was for (#1314): see *A read that fails* in
//  `LibraryLines.swift`.
//
//  A real store does not fail a fetch on demand, so the listing seam fails
//  the listings it is told to and lists the rest for real. Each line is
//  saved elsewhere, as an edit mirrored in from another device is, because
//  that save wakes the task once: only the pass a failure asks for can
//  draw it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

extension LibraryLinesTests {
    /// Two hikes drawn, followed on a store that keeps its history.
    private struct Drawn {
        let stage: LibraryLinesStage
        let edited: Hike
        let other: Hike

        init() async throws {
            stage = try LibraryLinesStage(onDisk: true)
            let main = stage.container.mainContext
            edited = Fixture.hike(in: main, title: "Edited")
            other = Fixture.hike(in: main, title: "Other", route: Fixture.loopRoute)
            try await RemoteChangeLog.save(main, settling: edited)
            stage.start()
            await settleDelegateHop(until: "both hikes are drawn") { [stage] in stage.library.lines.count == 2 }
        }

        func saveElsewhere(_ route: [RouteCoordinate], on hike: Hike) async throws {
            try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: stage.container) { stored in
                stored.replaceRoute(with: route)
            }
        }
    }

    /// Whether `hike`'s drawn line starts where `route` does.
    private static func draws(_ route: [RouteCoordinate], for hike: Hike, in stage: LibraryLinesStage) -> Bool {
        stage.library.line(of: hike.id)?.runs.first?.first?.latitude == route[0].latitude
    }

    @Test("a listing that fails is asked for again at once, and draws the line its save was for")
    func aFailedListingIsAskedForAgainAtOnce() async throws {
        let drawn = try await Drawn()
        let stage = drawn.stage
        let edited = drawn.edited
        let other = drawn.other
        defer { stage.stop() }

        stage.listings.fail(next: 1)
        try await drawn.saveElsewhere(Fixture.outAndBackRoute, on: edited)
        await settleDelegateHop(until: "the new line is drawn, with no other save") {
            Self.draws(Fixture.outAndBackRoute, for: edited, in: stage)
        }
        #expect(stage.library.retries == 1)
        #expect(stage.reads.count(of: other.id) == 1, "the pass a failure asks for reads no other line")

        // A listing that lands ends the failure, so the next one asks again.
        stage.listings.fail(next: 1)
        try await drawn.saveElsewhere(Fixture.ridgeRoute, on: other)
        await settleDelegateHop(until: "the other new line is drawn, with no other save") {
            Self.draws(Fixture.ridgeRoute, for: other, in: stage)
        }
        #expect(stage.library.retries == 2)
    }

    /// Nothing has looked at history when a listing fails, so the save it
    /// was woken for is still there for the next pass's look to find.
    @Test("a listing failure that holds asks for one more pass, and no more, and loses no saved line")
    func aListingFailureThatHoldsAsksForOneMorePass() async throws {
        let drawn = try await Drawn()
        let stage = drawn.stage
        let edited = drawn.edited
        let other = drawn.other
        defer { stage.stop() }
        let listed = stage.listings.count

        stage.listings.fail(next: .max)
        try await drawn.saveElsewhere(Fixture.outAndBackRoute, on: edited)
        await settleDelegateHop(until: "the save's listing and the one it asked for both failed") {
            stage.listings.failures == 2
        }
        #expect(Self.draws(Fixture.ridgeRoute, for: edited, in: stage), "the old line stays drawn")

        stage.listings.fail(next: 0)
        try await drawn.saveElsewhere(Fixture.ridgeRoute, on: other)
        await settleDelegateHop(until: "both new lines are drawn") {
            Self.draws(Fixture.outAndBackRoute, for: edited, in: stage)
                && Self.draws(Fixture.ridgeRoute, for: other, in: stage)
        }
        #expect(stage.library.retries == 1, "only the first failure asks for a pass")
        #expect(
            stage.listings.count == listed + 3,
            "the save's listing, the one its failure asked for, and the next save's"
        )
    }
}

/// Every listing of the library, and the ones it was told to fail.
nonisolated final class ListingLog: Sendable {
    private struct ListingFailure: Error {}

    private let counts = Mutex<(listings: Int, failures: Int, failing: Int)>((0, 0, 0))

    /// How many times the library was listed, or a listing failed.
    var count: Int { counts.withLock { $0.listings } }
    /// How many of those listings failed.
    var failures: Int { counts.withLock { $0.failures } }

    /// Fails the next `listings` listings, and lists any after for real.
    func fail(next listings: Int) {
        counts.withLock { $0.failing = listings }
    }

    @concurrent
    func list(in container: ModelContainer) async throws -> [LibraryLines.ListedHike] {
        let fails = counts.withLock { counts in
            counts.listings += 1
            guard counts.failing > 0 else { return false }
            counts.failing -= 1
            counts.failures += 1
            return true
        }
        if fails { throw ListingFailure() }
        return try await LibraryLines.listHikes(in: container)
    }
}
