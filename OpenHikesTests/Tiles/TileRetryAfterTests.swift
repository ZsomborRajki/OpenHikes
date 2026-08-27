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
//  `.serialized` for the same reason `TileTransportTests` is: `StubTileProtocol`
//  scripts responses through process-wide state.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

@Suite("Retry-After", .serialized)
struct TileRetryAfterTests {
    private let key = "osm/14/2638/6357@2.0"
    private let start = ContinuousClock.now
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func url() -> URL {
        guard let url = URL(string: "https://tiles.example.invalid/14/2638/6357.png") else {
            preconditionFailure("Invalid test URL")
        }
        return url
    }

    private func response(
        status: Int,
        headers: [String: String] = [:]
    ) throws -> HTTPURLResponse {
        try #require(
            HTTPURLResponse(url: url(), statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        )
    }

    // MARK: Reading the header

    /// The common spelling: a number of seconds.
    @Test("delta-seconds is honoured")
    func deltaSecondsIsParsed() {
        #expect(RetryAfterHeader.delay(from: "120", now: now) == .seconds(120))
        #expect(RetryAfterHeader.delay(from: "  30 ", now: now) == .seconds(30), "surrounding space is not a value")
    }

    /// The other spelling RFC 9110 allows, and the one whose meaning depends
    /// on when it is read.
    @Test("an HTTP-date is honoured, relative to now")
    func httpDateIsParsed() {
        let inTwoMinutes = now.addingTimeInterval(120)
        let formatted = Self.imfFixdate(inTwoMinutes)
        #expect(RetryAfterHeader.delay(from: formatted, now: now) == .seconds(120))
    }

    /// Nothing usable is no advice at all, rather than a guess. Each of these
    /// would otherwise become a `.zero` floor, which is a floor in name only,
    /// or a nonsense one.
    @Test(
        "a value that asks for nothing usable is ignored",
        arguments: ["", "   ", "0", "-30", "soon", "Fri, 99 Zzz 1999 25:61:61 GMT"]
    )
    func unusableValuesAreIgnored(value: String) {
        #expect(RetryAfterHeader.delay(from: value, now: now) == nil)
    }

    /// A date already behind us asks for nothing — it does not ask for a wait
    /// measured backwards.
    @Test("a deadline in the past is ignored")
    func pastDeadlineIsIgnored() {
        #expect(RetryAfterHeader.delay(from: Self.imfFixdate(now.addingTimeInterval(-60)), now: now) == nil)
    }

    /// A server asking for a day — or a date misread as one — must not take a
    /// tile off the map until the app is relaunched.
    @Test("an absurd wait is clamped")
    func absurdWaitIsClamped() {
        #expect(RetryAfterHeader.delay(from: "86400", now: now) == RetryAfterHeader.maximumDelay)
        #expect(RetryAfterHeader.maximumDelay > .seconds(300), "and still longer than the policy's own ceiling")
    }

    // MARK: Which responses carry advice

    /// 429 is the rate limit; 503 is a tile server shedding load. Both are
    /// statements about this client's request rate. A 404 or a 500 is not,
    /// however helpfully it is decorated.
    @Test("only a rate limit or an overload can park a tile", arguments: [429, 503, 500, 404, 200])
    func onlyRateLimitStatusesAreHonoured(status: Int) throws {
        let refusal = try response(status: status, headers: [RetryAfterHeader.name: "90"])
        let advice = RetryAfterHeader.delay(from: refusal, now: now)
        #expect((advice != nil) == RetryAfterHeader.honouredStatusCodes.contains(status))
    }

    @Test("a rate limit with no header carries no advice")
    func rateLimitWithoutHeaderCarriesNothing() throws {
        let refusal = try response(status: RetryAfterHeader.tooManyRequests)
        #expect(RetryAfterHeader.delay(from: refusal, now: now) == nil)
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

        let deadline = try #require(sandbox.cache.retryDeadline(forKey: key))
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
        #expect(sandbox.cache.retryDeadline(forKey: key) == nil)
    }

    /// The renderer's failure log is keyed by tile path and the cache files
    /// advice under the provider-namespaced key. This is the translation
    /// between them, and it is the step that would silently find nothing.
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
        let loaded = await offMainAsync { await overlay.cacheTile(at: path) }
        #expect(!loaded, "precondition: a 503 is a miss")
        #expect(overlay.retryDeadline(at: path) != nil)
    }

    /// The IMF-fixdate spelling of an instant — `Sun, 06 Nov 1994 08:49:37
    /// GMT`. Written out here rather than reusing the parser's own formatter,
    /// so a test would still fail if that formatter were wrong.
    private static func imfFixdate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}

/// `offMain` for work that is already `async`. `TileOverlay.cacheTile(at:)`
/// inherits its caller's isolation, and the tile pipeline it reaches asserts
/// it is not on the main thread.
@concurrent
private func offMainAsync<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
    await work()
}
