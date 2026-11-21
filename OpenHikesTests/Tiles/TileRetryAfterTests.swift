//
//  TileRetryAfterTests.swift
//  OpenHikesTests
//
//  What the client does when a tile server names its own deadline.
//
//  `TileRetryTests` owns the backoff the app invents for itself — five
//  seconds to five minutes, escalating per tile. This suite owns the one case
//  where the client is not guessing: a 429 or an overloaded 503 carrying
//  `Retry-After`. Coming back on the shortest delay the policy has, five
//  seconds after a server said it was rate limiting us, is the request
//  pattern OSM's usage policy exists to discourage.
//
//  The rule under test throughout is that the header is a *floor* and never a
//  ceiling. It can push a retry further out; it can never bring one forward,
//  and it can never stop the per-tile escalation happening underneath it. So
//  no server, hostile or merely misconfigured, can make this client more
//  eager than its own policy would have been.
//
//  The reading of the header itself is the vector tile package's, where the
//  tile server's client reads it too, and is tested there
//  (`RetryAfterHeaderTests`).
//
//  `.serialized` for the same reason `TileTransportTests` is: `StubTileProtocol`
//  scripts responses through process-wide state.
//

import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesVectorTiles
@testable import OpenHikesVectorTilesTestSupport
import Testing

@Suite("Retry-After", .serialized)
struct TileRetryAfterTests {
    private let key = "osm/14/2638/6357@2.0"
    private let start = ContinuousClock.now

    private func url() -> URL {
        guard let url = URL(string: "https://tiles.example.invalid/14/2638/6357.png") else {
            preconditionFailure("Invalid test URL")
        }
        return url
    }

    // MARK: Remembering it

    @Test("a recorded deadline stands until it comes due")
    func recordedDeadlineExpiresOnItsOwn() {
        var advice = TileRetryAdvice()
        advice.record(key, notBefore: start.advanced(by: .seconds(60)), at: start)

        #expect(advice.deadline(for: key, at: start) == start.advanced(by: .seconds(60)))
        #expect(advice.deadline(for: key, at: start.advanced(by: .seconds(60))) == nil, "due is not still waiting")
        #expect(advice.deadline(for: "another", at: start) == nil)
    }

    /// A server still overloaded when the second tile fails must not be heard
    /// as having relented about the first.
    @Test("a later deadline wins over an earlier one")
    func theLaterDeadlineWins() {
        var advice = TileRetryAdvice()
        advice.record(key, notBefore: start.advanced(by: .seconds(300)), at: start)
        advice.record(key, notBefore: start.advanced(by: .seconds(10)), at: start)

        #expect(advice.deadline(for: key, at: start) == start.advanced(by: .seconds(300)))
    }

    /// A provider having a bad afternoon refuses every tile a user pans
    /// across, and this table must not grow with all of them.
    @Test("the table is bounded")
    func tableIsBounded() {
        var advice = TileRetryAdvice()
        for index in 0..<(TileRetryAdvice.maximumTrackedKeys + 50) {
            advice.record("osm/14/\(index)/6357@2.0", notBefore: start.advanced(by: .seconds(60)), at: start)
        }
        #expect(advice.count == TileRetryAdvice.maximumTrackedKeys)

        // Due entries cost nothing to keep and are dropped as the next one
        // arrives, which is what keeps the eviction above a rare event.
        advice.record(key, notBefore: start.advanced(by: .seconds(600)), at: start.advanced(by: .seconds(120)))
        #expect(advice.count == 1)
    }

    // MARK: Feeding the backoff

    /// The join. The server's deadline replaces the policy's when it is
    /// longer, and the failure count still escalates underneath it — so the
    /// *next* failure of the same tile is charged the next delay up, exactly
    /// as it would have been.
    @Test("a longer server deadline pushes the retry out")
    func serverDeadlineOverridesAShorterBackoff() {
        var log = TileFailureLog(policy: TileRetryPolicy(delays: [.seconds(5), .seconds(15)]))
        let serverDeadline = start.advanced(by: .seconds(120))

        #expect(log.recordFailure(key, at: start, notBefore: serverDeadline) == serverDeadline)
        #expect(!log.mayAttempt(key, at: start.advanced(by: .seconds(119)), isOnline: true))
        #expect(log.mayAttempt(key, at: serverDeadline, isOnline: true))

        #expect(
            log.recordFailure(key, at: start) == start.advanced(by: .seconds(15)),
            "the escalation carried on underneath — this is the second failure, not the first"
        )
    }

    /// The direction that must not work. A server asking for one second
    /// cannot undo a backoff that has escalated to five minutes, or a
    /// misconfigured provider could talk this client into hammering it.
    @Test("a shorter server deadline cannot bring a retry forward")
    func serverDeadlineCannotShortenABackoff() {
        var log = TileFailureLog(policy: TileRetryPolicy(delays: [.seconds(45)]))

        let retryAt = log.recordFailure(key, at: start, notBefore: start.advanced(by: .seconds(1)))
        #expect(retryAt == start.advanced(by: .seconds(45)))
        #expect(!log.mayAttempt(key, at: start.advanced(by: .seconds(2)), isOnline: true))
    }

    /// No advice is the ordinary case, and it must leave the policy exactly
    /// where `TileRetryTests` pins it.
    @Test("no advice leaves the policy untouched")
    func noAdviceLeavesThePolicyAlone() {
        var log = TileFailureLog(policy: TileRetryPolicy(delays: [.seconds(5)]))
        #expect(log.recordFailure(key, at: start, notBefore: nil) == start.advanced(by: .seconds(5)))
    }

    // MARK: End to end

    /// What the renderer will actually find. A rate-limited fetch is still a
    /// miss — nothing about this makes a tile appear — but the deadline the
    /// server named is waiting for the failure to be recorded against.
    @Test("a rate-limited fetch leaves its deadline behind for the renderer")
    func rateLimitedFetchRecordsAdvice() async throws {
        StubTileProtocol.reset()
        defer { StubTileProtocol.reset() }
        let sandbox = TileSandbox(sessionConfiguration: StubTileProtocol.sessionConfiguration())
        StubTileProtocol.alwaysRespond(
            with: .init(
                statusCode: RetryAfterHeader.tooManyRequests,
                data: Data("slow down".utf8),
                headers: [RetryAfterHeader.name: "120"]
            )
        )

        #expect(await sandbox.cache.loadTile(forKey: key, url: url()) == nil)

        let deadline = try #require(sandbox.cache.retryDeadline(for: url()))
        let waitSeconds = ContinuousClock.now.duration(to: deadline).components.seconds
        #expect(waitSeconds > 110 && waitSeconds <= 120)
    }

    /// A server error that says nothing about rate leaves nothing behind, so
    /// the tile backs off on the policy's own five seconds.
    @Test("a plain server error leaves no deadline")
    func plainErrorRecordsNothing() async {
        StubTileProtocol.reset()
        defer { StubTileProtocol.reset() }
        let sandbox = TileSandbox(sessionConfiguration: StubTileProtocol.sessionConfiguration())
        StubTileProtocol.alwaysRespond(with: .status(500))

        #expect(await sandbox.cache.loadTile(forKey: key, url: url()) == nil)
        #expect(sandbox.cache.retryDeadline(for: url()) == nil)
    }

    /// The renderer's failure log is keyed by tile path and the cache files
    /// advice under the URL it refused. This is the translation between
    /// them, and it is the step that would silently find nothing.
    @Test("the overlay finds the advice its renderer will ask for")
    func overlayTranslatesThePathToTheAdvisedKey() async {
        StubTileProtocol.reset()
        defer { StubTileProtocol.reset() }
        let sandbox = TileSandbox(sessionConfiguration: StubTileProtocol.sessionConfiguration())
        StubTileProtocol.alwaysRespond(
            with: .init(
                statusCode: RetryAfterHeader.serviceUnavailable,
                data: Data(),
                headers: [RetryAfterHeader.name: "60"]
            )
        )
        let overlay = TileOverlay(
            providerID: "osm",
            urlTemplate: "https://tiles.example.invalid/{z}/{x}/{y}.png",
            cache: sandbox.cache,
            autoSaveStore: sandbox.store
        )
        let path = MKTileOverlayPath(x: 9500, y: 14_600, z: 15, contentScaleFactor: 2)

        #expect(overlay.retryDeadline(at: path) == nil, "precondition: nothing has failed yet")
        let disposition = await offMainAsync { await overlay.cacheTile(at: path) }
        #expect(disposition == .failed, "precondition: a 503 is a failed load")
        #expect(overlay.retryDeadline(at: path) != nil)
    }
}

/// `offMain` for work that is already `async`. `TileOverlay.cacheTile(at:)`
/// inherits its caller's isolation, and the tile pipeline it reaches asserts
/// it is not on the main thread.
@concurrent
private func offMainAsync<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
    await work()
}
