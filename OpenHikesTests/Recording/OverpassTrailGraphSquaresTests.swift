//
//  OverpassTrailGraphSquaresTests.swift
//  OpenHikesTests
//
//  A trail graph provider handed the squares: a region they answer is asked of
//  Overpass not at all, a region they cannot answer is asked as before, and
//  Overpass asking to be left alone stops only what would ask it.
//
//  Asserted on requests, because the point of the squares is the request that
//  is not made.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

/// Answers every Overpass request with what it was given, and counts them.
private actor CountingOverpass {
    private(set) var requests = 0
    private let answer: OverpassHTTPResponse

    init(statusCode: Int = 200, body: String = OverpassGraphFixture.alpineRoute, headers: [String: String] = [:]) {
        answer = OverpassHTTPResponse(data: Data(body.utf8), statusCode: statusCode, headers: headers)
    }

    func respond() -> OverpassHTTPResponse {
        requests += 1
        return answer
    }
}

@Suite("Overpass trail graph with squares")
struct OverpassTrailGraphSquaresTests {
    static let hut = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)
    /// The square around ``hut``, holding `OverpassGraphFixture.alpineRoute`'s
    /// walkable way.
    static let square = TrailGraphSquareLibraryTests.found([TrailGraphSquareLibraryTests.localPath])

    private static func makeProvider(
        _ database: StubTrailCellDatabase,
        overpass: CountingOverpass,
        directory: URL
    ) -> OverpassTrailGraphProvider {
        OverpassTrailGraphProvider(
            directory: directory,
            squares: TrailGraphSquareLibrary(database: database, directory: nil),
            transport: { _ in await overpass.respond() }
        )
    }

    static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("graph-squares-provider-\(UUID().uuidString)")
    }

    @Test("a region the squares answer asks Overpass nothing")
    func squaresAnswerWithoutOverpass() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = StubTrailCellDatabase(cells: [TrailGraphSquareLibraryTests.squareName: Self.square])
        let overpass = CountingOverpass()
        let provider = Self.makeProvider(database, overpass: overpass, directory: directory)

        try await provider.prefetch(around: Self.hut)
        let graph = try #require(try await provider.cachedGraph(covering: [Self.hut]))

        #expect(await overpass.requests == 0)
        #expect(graph.edges.map(\.hikingRouteName) == ["Alpine Route"])
        #expect(await provider.hasCompleteCachedGraph(covering: [Self.hut]), "kept as a region like any other")
    }

    @Test("a region the squares do not cover is asked of Overpass as it always was")
    func uncoveredAsksOverpass() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let overpass = CountingOverpass()
        let database = StubTrailCellDatabase(manifest: .absent)
        let provider = Self.makeProvider(database, overpass: overpass, directory: directory)

        try await provider.prefetch(around: Self.hut)
        let graph = try #require(try await provider.cachedGraph(covering: [Self.hut]))

        #expect(await overpass.requests == 1)
        #expect(graph.edges.count == 1, "Overpass's answer, its private way left out as ever")
    }

    /// Overpass's `429` is Overpass's: the squares are asked before it would
    /// be, and a region they cannot answer is still refused without asking.
    @Test("Overpass asking to wait stops only the regions that would ask it")
    func aRateLimitStopsOnlyOverpass() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = StubTrailCellDatabase(cells: [TrailGraphSquareLibraryTests.squareName: .failed])
        let overpass = CountingOverpass(statusCode: 429, body: "", headers: ["retry-after": "120"])
        let provider = Self.makeProvider(database, overpass: overpass, directory: directory)

        await #expect(throws: TrailGraphProviderError.self) {
            try await provider.prefetch(around: Self.hut)
        }
        await #expect(throws: TrailGraphProviderError.self) {
            try await provider.prefetch(around: Self.hut)
        }
        let refusedWithoutAsking = await overpass.requests
        database.hold(Self.square, as: TrailGraphSquareLibraryTests.squareName)
        try await provider.prefetch(around: Self.hut)

        #expect(refusedWithoutAsking == 1, "the second attempt was refused before Overpass was asked")
        #expect(await overpass.requests == 1)
        #expect(try await provider.cachedGraph(covering: [Self.hut])?.edges.count == 1)
    }

    /// A square fetched on one day and read for a new region thirty days
    /// later is a month old, and the region is as old as it.
    @Test("a region read out of a kept square expires with the square")
    func aRegionExpiresWithItsSquare() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let day: TimeInterval = 24 * 3600
        let database = StubTrailCellDatabase(cells: [TrailGraphSquareLibraryTests.squareName: Self.square])
        let overpass = CountingOverpass()
        let provider = OverpassTrailGraphProvider(
            directory: directory,
            clock: clock.read,
            squares: TrailGraphSquareLibrary(database: database, directory: nil, clock: clock.read),
            transport: { _ in await overpass.respond() }
        )
        // The region beside the hut's, in the same square.
        let beside = CLLocationCoordinate2D(latitude: 47.60, longitude: 12.80)

        try await provider.prefetch(around: Self.hut)
        clock.advance(by: OverpassCache.lifetime - day)
        try await provider.prefetch(around: beside)
        let keptOnTheSquaresLastDay = await provider.hasCompleteCachedGraph(covering: [beside])
        clock.advance(by: 2 * day)

        #expect(keptOnTheSquaresLastDay)
        #expect(await !provider.hasCompleteCachedGraph(covering: [beside]), "not thirty days after it was read")
        #expect(database.requests.count == 1, "both regions were read out of the one square")
        #expect(await overpass.requests == 0)
    }
}
