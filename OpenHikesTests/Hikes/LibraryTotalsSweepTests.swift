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
