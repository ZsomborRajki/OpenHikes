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
        directory: URL,
        clock: TestClock = TestClock()
    ) -> OverpassTrailGraphProvider {
        OverpassTrailGraphProvider(
            directory: directory,
            clock: clock.read,
            squares: TrailGraphSquareLibrary(database: database, directory: nil, clock: clock.read),
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
    /// The square is asked again once the minute it is left alone for has
    /// passed, while Overpass's two minutes have not.
    @Test("Overpass asking to wait stops only the regions that would ask it")
    func aRateLimitStopsOnlyOverpass() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let database = StubTrailCellDatabase(cells: [TrailGraphSquareLibraryTests.squareName: .failed])
        let overpass = CountingOverpass(statusCode: 429, body: "", headers: ["retry-after": "120"])
        let provider = Self.makeProvider(database, overpass: overpass, directory: directory, clock: clock)

        await #expect(throws: TrailGraphProviderError.self) {
            try await provider.prefetch(around: Self.hut)
        }
        await #expect(throws: TrailGraphProviderError.self) {
            try await provider.prefetch(around: Self.hut)
        }
        let refusedWithoutAsking = await overpass.requests
        database.hold(Self.square, as: TrailGraphSquareLibraryTests.squareName)
        clock.advance(by: TrailGraphSquareLibrary.failedRetry + 1)
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

    /// The maker's provider and the trails provider are one address to
    /// Overpass, so a `429` either earns stops both.
    @Test("Overpass asking one provider to wait stops the other's requests too")
    func theProvidersShareOverpassRefusal() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deadline = OverpassRetryDeadline()
        let refusing = CountingOverpass(statusCode: 429, body: "", headers: ["retry-after": "120"])
        let answering = CountingOverpass()
        let routing = OverpassTrailGraphProvider(
            directory: directory.appendingPathComponent("routing"),
            retryDeadline: deadline,
            transport: { _ in await refusing.respond() }
        )
        let trails = OverpassTrailGraphProvider(
            directory: directory.appendingPathComponent("trails"),
            squares: TrailGraphSquareLibrary(
                database: StubTrailCellDatabase(cells: [TrailGraphSquareLibraryTests.squareName: .failed]),
                directory: nil
            ),
            retryDeadline: deadline,
            transport: { _ in await answering.respond() }
        )

        await #expect(throws: TrailGraphProviderError.self) {
            try await routing.prefetch(around: Self.hut)
        }
        await #expect(throws: TrailGraphProviderError.self) {
            try await trails.prefetch(around: Self.hut)
        }

        #expect(await refusing.requests == 1)
        #expect(await answering.requests == 0, "refused before Overpass was asked")
    }

    @Test("the regions' directory is left out of the device's backups")
    func regionsAreNotBackedUp() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = StubTrailCellDatabase(cells: [TrailGraphSquareLibraryTests.squareName: Self.square])
        let provider = Self.makeProvider(database, overpass: CountingOverpass(), directory: directory)

        try await provider.prefetch(around: Self.hut)

        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
}
