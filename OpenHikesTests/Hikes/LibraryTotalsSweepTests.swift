//
//  LibraryTotalsSweepTests.swift
//  OpenHikesTests
//
//  Reading the library for *Totals*: a fetch that fails is a failure, never
//  an empty library or half of one (#756).
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Library totals sweep")
struct LibraryTotalsSweepTests {
    private struct ReadFailure: Error {}

    private static let failingHikes: @Sendable (ModelContext) throws -> [Hike] = { _ in throw ReadFailure() }
    private static let failingWalks: @Sendable (ModelContext) throws -> [HikeWalk] = { _ in throw ReadFailure() }

    /// A library of one hike and one walk along it.
    private static func library() throws -> ModelContainer {
        let container = try ModelContainer.openHikes(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let hikeID = UUID()
        context.insert(Hike(title: "Ridge Loop", distanceMeters: 2000, id: hikeID))
        context.insert(
            HikeWalk(
                hikeID: hikeID,
                startedAt: .now,
                endedAt: .now.addingTimeInterval(3600),
                activeSeconds: 3000,
                coveredIntervals: [0, 1500],
                furthestDistanceMeters: 1500,
                routeDistanceMeters: 2000,
                endReason: .reachedEnd
            )
        )
        try context.save()
        return container
    }

    @Test("an empty library reads as empty, not as a failure")
    func emptyLibrary() async throws {
        let container = try ModelContainer.openHikes(isStoredInMemoryOnly: true)

        let read = try await LibraryTotalsSweep.read(from: container)

        #expect(read.hikes.isEmpty)
        #expect(read.walks.isEmpty)
    }

    @Test("a readable library reads its hikes and walks")
    func readableLibrary() async throws {
        let read = try await LibraryTotalsSweep.read(from: Self.library())

        #expect(read.hikes.map(\.title) == ["Ridge Loop"])
        #expect(read.walks.map(\.coveredMeters) == [1500])
    }

    private static func walk(of hikeID: UUID, covering meters: Double, along revision: String?) -> HikeWalk {
        HikeWalk(
            hikeID: hikeID,
            startedAt: .now,
            endedAt: .now.addingTimeInterval(3600),
            activeSeconds: 3000,
            coveredIntervals: [0, meters],
            furthestDistanceMeters: meters,
            routeDistanceMeters: 2000,
            endReason: .ended,
            routeRevision: revision
        )
    }

    /// The test the walk's own summary makes, so *Totals* does not credit a
    /// walk with the line its trail was redrawn to afterwards (#912). A walk
    /// whose trail is not there has nothing to have changed.
    @Test("a walk is told from one along a line its trail has been redrawn from since")
    func redrawnTrailsAreMarked() async throws {
        let container = try ModelContainer.openHikes(isStoredInMemoryOnly: true)
        let context = ModelContext(container)
        let hike = Hike(
            title: "Drawn Ridge",
            distanceMeters: 2000,
            route: [
                RouteCoordinate(latitude: 47.55, longitude: 12.97, elevation: 600),
                RouteCoordinate(latitude: 47.57, longitude: 12.97, elevation: 900),
            ]
        )
        context.insert(hike)
        // Told apart by what each covered.
        context.insert(Self.walk(of: hike.id, covering: 100, along: TrailWalkRecord.routeRevision(of: hike.route)))
        context.insert(Self.walk(of: hike.id, covering: 200, along: "a line drawn before"))
        context.insert(Self.walk(of: hike.id, covering: 300, along: nil))
        context.insert(Self.walk(of: UUID(), covering: 400, along: nil))
        try context.save()

        let read = try await LibraryTotalsSweep.read(from: container)
        let changed = read.walks.sorted { $0.coveredMeters < $1.coveredMeters }.map(\.trailHasChanged)

        #expect(changed == [false, true, true, false])
    }

    /// The screen's figures and Siri's outings are counted off the main
    /// actor now (#1118), and are the same figures counting the read gives.
    @Test("the totals and outings counted off the main actor are the read's")
    func countedTotalsAreTheReads() async throws {
        let container = try Self.library()
        let date = Date.now.addingTimeInterval(7200)
        let read = try await LibraryTotalsSweep.read(from: container)

        let totals = try await LibraryTotalsSweep.totals(from: container, asOf: date, calendar: .current)
        let outings = try await LibraryTotalsSweep.outings(from: container)

        #expect(totals == LibraryTotals(hikes: read.hikes, walks: read.walks, asOf: date, calendar: .current))
        #expect(totals.allTime.outings == 1)
        #expect(outings.hikes == read.hikes)
        #expect(outings.outings == LibraryTotals.outings(hikes: read.hikes, walks: read.walks))
    }

    @Test("a failed fetch fails the totals rather than counting half a library")
    func countedTotalsFail() async throws {
        let container = try Self.library()
        let reads = LibraryTotalsSweep.Reads(hikes: LibraryTotalsSweep.Reads.store.hikes, walks: Self.failingWalks)

        await #expect(throws: ReadFailure.self) {
            try await LibraryTotalsSweep.totals(from: container, asOf: .now, calendar: .current, using: reads)
        }
        await #expect(throws: ReadFailure.self) {
            try await LibraryTotalsSweep.outings(from: container, using: reads)
        }
    }

    @Test("a failed hike fetch fails the read")
    func hikeFetchFails() async throws {
        let container = try Self.library()
        let reads = LibraryTotalsSweep.Reads(hikes: Self.failingHikes, walks: LibraryTotalsSweep.Reads.store.walks)

        await #expect(throws: ReadFailure.self) {
            try await LibraryTotalsSweep.read(from: container, using: reads)
        }
    }

    @Test("a failed walk fetch fails the read rather than dropping the walks")
    func walkFetchFails() async throws {
        let container = try Self.library()
        let reads = LibraryTotalsSweep.Reads(hikes: LibraryTotalsSweep.Reads.store.hikes, walks: Self.failingWalks)

        await #expect(throws: ReadFailure.self) {
            try await LibraryTotalsSweep.read(from: container, using: reads)
        }
    }

    @Test("both fetches failing fails the read")
    func bothFetchesFail() async throws {
        let container = try Self.library()
        let reads = LibraryTotalsSweep.Reads(hikes: Self.failingHikes, walks: Self.failingWalks)

        await #expect(throws: ReadFailure.self) {
            try await LibraryTotalsSweep.read(from: container, using: reads)
        }
    }

    @Test("reading again after a failure sums the whole library")
    func retryAfterFailure() async throws {
        let container = try Self.library()
        let failing = LibraryTotalsSweep.Reads(hikes: LibraryTotalsSweep.Reads.store.hikes, walks: Self.failingWalks)
        await #expect(throws: ReadFailure.self) {
            try await LibraryTotalsSweep.read(from: container, using: failing)
        }

        let read = try await LibraryTotalsSweep.read(from: container)

        #expect(read.hikes.count == 1)
        #expect(read.walks.count == 1)
    }
}
