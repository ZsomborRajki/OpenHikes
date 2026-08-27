//
//  OverpassTrailGraphExpiryTests.swift
//  OpenHikesTests
//
//  When a cached trail graph stops counting as current, and what happens on
//  either side of that instant.
//
//  Split from the other two Overpass suites so none of them outgrows the
//  type-body limit, and because these ask a different question: not "does the
//  download work" but "when does the app decide what it already has is too
//  old". The provider takes an injected clock precisely so that question can
//  be asked without waiting a month, and nothing was asking it.
//
//  Every test here drives time through that clock. A `Task.sleep` long enough
//  to cross this boundary would take thirty days, and a shorter one that
//  pretended to would only be testing itself.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

/// Counts calls and can be told to start failing, so a refetch that goes wrong
/// is a scripted event rather than an accident of ordering.
private actor ExpiryTransport {
    static let successStatusCode = 200
    static let serverErrorStatusCode = 500

    private(set) var callCount = 0
    private var failFrom: Int?
    private let payloads: [Data]

    init(payloads: [Data]) {
        self.payloads = payloads
    }

    func failFromCall(_ index: Int) {
        failFrom = index
    }

    func respond() -> OverpassHTTPResponse {
        callCount += 1
        if let failFrom, callCount >= failFrom {
            return OverpassHTTPResponse(
                data: Data(),
                statusCode: Self.serverErrorStatusCode,
                headers: [:]
            )
        }
        let payload = payloads[min(callCount - 1, payloads.count - 1)]
        return OverpassHTTPResponse(
            data: payload,
            statusCode: Self.successStatusCode,
            headers: [:]
        )
    }
}

@Suite("Overpass cache expiry")
struct OverpassTrailGraphExpiryTests {
    /// Thirty days, written out here rather than read from the provider.
    ///
    /// A test that takes its expected value from the implementation asserts
    /// only that the implementation equals itself: shortening the lifetime to
    /// an hour would keep such a test green while quietly putting the app back
    /// on the network every hour of a walk. This is the promise, stated
    /// independently, and it fails if the code changes its mind.
    private static let cacheLifetime: TimeInterval = 30 * 24 * 60 * 60

    private static let coordinate = CLLocationCoordinate2D(
        latitude: 47.63,
        longitude: 12.86
    )

    // MARK: The boundary

    /// The inclusive side, named. An entry whose age is *exactly* the lifetime
    /// is current; the refetch begins one tick later.
    ///
    /// Asserted as a pair rather than as two tests so that a change moving the
    /// comparison from `<=` to `<` cannot be made to pass by adjusting one
    /// half. Which side is inclusive barely matters on its own — what matters
    /// is that it was chosen, because an off-by-one here is a month of silence
    /// or a month of extra requests and neither announces itself.
    @Test("an entry exactly at the lifetime is still current; one second later it is not")
    func boundaryIsInclusiveAtTheLifetime() async throws {
        try await withProvider { provider, transport, clock in
            try await provider.prefetch(around: Self.coordinate)
            #expect(await transport.callCount == 1)

            clock.advance(by: Self.cacheLifetime)
            try await provider.prefetch(around: Self.coordinate)
            #expect(
                await transport.callCount == 1,
                "an entry at exactly the lifetime was treated as expired"
            )
            #expect(await provider.hasCompleteCachedGraph(covering: [Self.coordinate]))

            clock.advance(by: 1)
            try await provider.prefetch(around: Self.coordinate)
            #expect(
                await transport.callCount == 2,
                "an entry past the lifetime was not refetched"
            )
        }
    }

    /// Well inside the window, nothing reaches the network however often the
    /// region is asked for — which is the whole reason the cache exists, since
    /// this runs while somebody is walking.
    @Test("time inside the window costs no requests", arguments: [
        0.0, 1.0, 60.0 * 60, 29.0 * 24 * 60 * 60,
    ] as [TimeInterval])
    func insideTheWindowIsServedFromCache(age: TimeInterval) async throws {
        try await withProvider { provider, transport, clock in
            try await provider.prefetch(around: Self.coordinate)
            clock.advance(by: age)

            for _ in 0..<3 {
                try await provider.prefetch(around: Self.coordinate)
            }
            let graph = try await provider.cachedGraph(covering: [Self.coordinate])

            #expect(await transport.callCount == 1)
            #expect(graph?.edges.count == 1)
        }
    }

    /// The comparison is written twice — once for the in-memory entry and once
    /// for the one read back off disk — so a suite that only ever exercised a
    /// warm provider would pass with the disk half broken. This asks a
    /// provider with an empty memory cache, which is what every cold launch is.
    @Test("a provider that has just launched applies the same boundary to disk")
    func diskPathUsesTheSameBoundary() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let transport = ExpiryTransport(payloads: [Self.alpinePayload])
        let warm = OverpassTrailGraphProvider(
            directory: directory,
            clock: clock.read
        ) { _ in await transport.respond() }
        try await warm.prefetch(around: Self.coordinate)

        clock.advance(by: Self.cacheLifetime)
        let atBoundary = OverpassTrailGraphProvider(
            directory: directory,
            clock: clock.read
        ) { _ in await transport.respond() }
        #expect(
            await atBoundary.hasCompleteCachedGraph(covering: [Self.coordinate]),
            "the disk entry expired a tick early"
        )

        clock.advance(by: 1)
        let pastBoundary = OverpassTrailGraphProvider(
            directory: directory,
            clock: clock.read
        ) { _ in await transport.respond() }
        #expect(
            await pastBoundary.hasCompleteCachedGraph(covering: [Self.coordinate]) == false,
            "the disk entry outlived the lifetime"
        )
        #expect(await transport.callCount == 1)
    }

    /// A successful refetch replaces what was there, and the clock it is
    /// stamped with is the injected one — otherwise a graph downloaded during
    /// a test would carry a real `Date` and be current forever.
    @Test("a refetched entry restarts the window from when it was fetched")
    func refetchRestartsTheWindow() async throws {
        try await withProvider(
            payloads: [Self.alpinePayload, Self.emptyPayload]
        ) { provider, transport, clock in
            try await provider.prefetch(around: Self.coordinate)
            clock.advance(by: Self.cacheLifetime + 1)
            try await provider.prefetch(around: Self.coordinate)
            #expect(await transport.callCount == 2)

            let refreshed = try await provider.cachedGraph(covering: [Self.coordinate])
            #expect(refreshed?.edges.isEmpty == true, "the second payload did not replace the first")

            clock.advance(by: Self.cacheLifetime)
            try await provider.prefetch(around: Self.coordinate)
            #expect(
                await transport.callCount == 2,
                "the window was measured from the first fetch rather than the second"
            )
        }
    }

    // MARK: What a failure is allowed to cost

    /// A failed refresh must not take the old graph with it, and this is the
    /// intended behaviour rather than a tolerated one: a walker halfway up a
    /// hill with no signal is exactly who is holding a month-old graph, and
    /// month-old trail tagging is very nearly as good as today's. Deleting it
    /// on a failed refresh would turn a stale map into no map at the moment it
    /// is least replaceable.
    ///
    /// The two rows of the answer are deliberately different: matching still
    /// gets the stale graph, while `hasCompleteCachedGraph` — which gates a
    /// *measurement* — reports it as missing, because a number derived from
    /// month-old tagging and presented as today's would be wrong rather than
    /// absent.
    @Test("a refetch that fails leaves the stale graph usable")
    func failedRefetchKeepsTheStaleGraph() async throws {
        try await withProvider { provider, transport, clock in
            try await provider.prefetch(around: Self.coordinate)
            await transport.failFromCall(2)
            clock.advance(by: Self.cacheLifetime + 1)

            await #expect(throws: TrailGraphProviderError.server(statusCode: 500)) {
                try await provider.prefetch(around: Self.coordinate)
            }

            let graph = try await provider.cachedGraph(covering: [Self.coordinate])
            #expect(graph?.edges.count == 1, "the stale graph was destroyed by a failed refresh")
            #expect(
                await provider.hasCompleteCachedGraph(covering: [Self.coordinate]) == false,
                "a measurement was offered month-old tagging as though it were current"
            )
            #expect(await transport.callCount == 2)
        }
    }

    /// The same, from cold: the failure happens on a provider that has never
    /// held the entry in memory, so the fallback has to come off disk.
    @Test("a cold provider whose refetch fails still falls back to disk")
    func coldFailedRefetchFallsBackToDisk() async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let seeding = ExpiryTransport(payloads: [Self.alpinePayload])
        let first = OverpassTrailGraphProvider(
            directory: directory,
            clock: clock.read
        ) { _ in await seeding.respond() }
        try await first.prefetch(around: Self.coordinate)

        clock.advance(by: Self.cacheLifetime + 1)
        let failing = ExpiryTransport(payloads: [Self.alpinePayload])
        await failing.failFromCall(1)
        let cold = OverpassTrailGraphProvider(
            directory: directory,
            clock: clock.read
        ) { _ in await failing.respond() }

        await #expect(throws: TrailGraphProviderError.server(statusCode: 500)) {
            try await cold.prefetch(around: Self.coordinate)
        }
        let graph = try await cold.cachedGraph(covering: [Self.coordinate])

        #expect(graph?.edges.count == 1)
    }

    /// A device whose clock has moved backwards — a manual change, or a
    /// restore — makes an entry look as though it were fetched in the future.
    /// Treated as current, deliberately: the alternative reading calls
    /// everything on disk expired at once and answers a clock adjustment with
    /// a burst of Overpass requests, on a shared public endpoint, from a phone
    /// that may well be on cellular.
    @Test("an entry from the future is current rather than expired")
    func aBackwardClockDoesNotInvalidateTheCache() async throws {
        try await withProvider { provider, transport, clock in
            try await provider.prefetch(around: Self.coordinate)
            clock.advance(by: -(Self.cacheLifetime * 2))

            try await provider.prefetch(around: Self.coordinate)

            #expect(await transport.callCount == 1)
            #expect(await provider.hasCompleteCachedGraph(covering: [Self.coordinate]))
        }
    }

    // MARK: Harness

    private static let alpinePayload = Data(OverpassGraphFixture.alpineRoute.utf8)
    private static let emptyPayload = Data(#"{"elements":[]}"#.utf8)

    private static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("trail-graph-expiry-\(UUID().uuidString)", isDirectory: true)
    }

    private func withProvider(
        payloads: [Data] = [],
        _ body: (OverpassTrailGraphProvider, ExpiryTransport, TestClock) async throws -> Void
    ) async throws {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let transport = ExpiryTransport(
            payloads: payloads.isEmpty ? [Self.alpinePayload] : payloads
        )
        let provider = OverpassTrailGraphProvider(
            directory: directory,
            clock: clock.read
        ) { _ in await transport.respond() }
        try await body(provider, transport, clock)
    }
}
