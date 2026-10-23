//
//  OverpassTrailGraphMemoryTests.swift
//  OpenHikesTests
//
//  How many decoded trail graphs the provider keeps in memory, and which one
//  it lets go of first.
//
//  The disk half of the cache has always been capped; the memory half held
//  every region a session had ever read, so the cap on files bounded nothing a
//  long recording actually paid for. These ask the memory half its own
//  question by taking the directory away before asking, which leaves only
//  what the provider still holds to answer from.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

/// Answers every request with the same small graph and counts them, so a
/// region that comes back from disk and one that is downloaded again are told
/// apart by a number.
private actor CountingGraphTransport {
    static let successStatusCode = 200

    private(set) var callCount = 0

    func respond() -> OverpassHTTPResponse {
        callCount += 1
        return OverpassHTTPResponse(
            data: Data(OverpassGraphFixture.alpineRoute.utf8),
            statusCode: Self.successStatusCode,
            headers: [:]
        )
    }
}

@Suite("Overpass memory cache")
struct OverpassTrailGraphMemoryTests {
    /// The bound, written out rather than read from the provider, for the
    /// reason the expiry suite gives for its lifetime: a test that takes its
    /// expected value from the code asserts only that the code equals itself.
    private static let memoryCapacity = 64

    /// The centre-ish of a distinct z12 region per index. A z12 tile is
    /// 360 / 4096 ≈ 0.088° wide, so a 0.1° step never lands twice in one.
    private static func coordinate(_ index: Int) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 47.63, longitude: 10.0 + Double(index) * 0.1)
    }

    @Test("regions past the capacity are let go of, oldest first")
    func memoryStopsGrowingAtTheCapacity() async throws {
        let regionCount = Self.memoryCapacity + 16
        try await withProvider { provider, transport, directory in
            for index in 0..<regionCount {
                try await provider.prefetch(around: Self.coordinate(index))
            }
            #expect(await transport.callCount == regionCount)
            try FileManager.default.removeItem(at: directory)

            for index in 0..<regionCount {
                let held = await provider.hasCompleteCachedGraph(covering: [Self.coordinate(index)])
                let shouldBeHeld = index >= regionCount - Self.memoryCapacity
                #expect(held == shouldBeHeld, "region \(index) held: \(held)")
            }
        }
    }

    /// Least recently *used*, not least recently fetched: the region a live
    /// match keeps reading is the one that must survive, however early in the
    /// walk it was downloaded.
    @Test("a region read since it was fetched outlives newer ones that were not")
    func readingARegionKeepsIt() async throws {
        try await withProvider { provider, _, directory in
            try await fill(provider)
            _ = try await provider.cachedGraph(covering: [Self.coordinate(0)])
            try await provider.prefetch(around: Self.coordinate(Self.memoryCapacity))
            try FileManager.default.removeItem(at: directory)

            #expect(await provider.hasCompleteCachedGraph(covering: [Self.coordinate(0)]))
            #expect(await provider.hasCompleteCachedGraph(covering: [Self.coordinate(1)]) == false)
            let rest = (2...Self.memoryCapacity).map(Self.coordinate)
            #expect(await provider.hasCompleteCachedGraph(covering: rest))
        }
    }

    /// An eviction is meant to cost a decode, not a download, for as long as
    /// the region's file is still on disk.
    @Test("a region let go of comes back from disk without a request")
    func evictedRegionIsReadBackFromDisk() async throws {
        try await withProvider { provider, transport, _ in
            try await fill(provider)
            _ = try await provider.cachedGraph(covering: [Self.coordinate(0)])
            try await provider.prefetch(around: Self.coordinate(Self.memoryCapacity))

            let graph = try await provider.cachedGraph(covering: [Self.coordinate(1)])
            #expect(graph?.edges.isEmpty == false)
            #expect(await provider.hasCompleteCachedGraph(covering: [Self.coordinate(1)]))
            #expect(await transport.callCount == Self.memoryCapacity + 1)
        }
    }

    @Test("a region gone from memory and disk is downloaded again")
    func evictedRegionWithoutAFileIsRefetched() async throws {
        try await withProvider { provider, transport, directory in
            try await fill(provider)
            try await provider.prefetch(around: Self.coordinate(Self.memoryCapacity))
            try FileManager.default.removeItem(at: directory)
            #expect(await provider.hasCompleteCachedGraph(covering: [Self.coordinate(0)]) == false)

            try await provider.prefetch(around: Self.coordinate(0))

            #expect(await transport.callCount == Self.memoryCapacity + 2)
            #expect(await provider.hasCompleteCachedGraph(covering: [Self.coordinate(0)]))
        }
    }

    // MARK: Harness

    /// Fetches regions `0..<memoryCapacity`, in order, so the memory cache is
    /// exactly full with region 0 its least recently used.
    private func fill(_ provider: OverpassTrailGraphProvider) async throws {
        for index in 0..<Self.memoryCapacity {
            try await provider.prefetch(around: Self.coordinate(index))
        }
    }

    private func withProvider(
        _ body: (OverpassTrailGraphProvider, CountingGraphTransport, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trail-graph-memory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let transport = CountingGraphTransport()
        let provider = OverpassTrailGraphProvider(
            directory: directory,
            clock: clock.read
        ) { _ in await transport.respond() }
        try await body(provider, transport, directory)
    }
}
