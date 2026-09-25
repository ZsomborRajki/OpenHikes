//
//  CuratedTrailSourceTests+Busy.swift
//  OpenHikesTests
//
//  Asking a busy server again, once, and knowing when not to.
//
//  An extension of `CuratedTrailSourceTests` in a file of its own, for the
//  reason its sibling `+Geometry` is: same type, same stub, and the file they
//  came from is at the length limit.
//
//  What is pinned here is a *policy*, and every clause of it is load-bearing
//  against an API this app does not own. Overpass answers a request it has no
//  slot for with a gateway refusal that arrives in seconds — measured at 8
//  against `overpass-api.de` on 2026-09-17 — and the next request is often
//  admitted, so one more ask turns a failed search into a search. A refusal
//  that took the whole budget is the opposite: the server spent that budget
//  and gave up, and asking again spends it twice while a pill spins. And a
//  `429` is neither, ever: it names the seconds it wants to be left alone, and
//  asking inside them is what turns one rate limit into a block on an address
//  shared by everyone on that network.
//
//  The clock and the pause are both seams — see *Deliberate test seams* in the
//  repository instructions — so nothing here waits on wall time.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

extension CuratedTrailSourceTests {
    /// What the source asked to wait for, so a case can assert on the pause
    /// without taking it.
    private final class PauseLog: Sendable {
        // `nonisolated` throughout: the seam is called from the source's own
        // actor, not from the main one this suite runs on.
        private let waits = Mutex<[TimeInterval]>([])

        nonisolated var recorded: [TimeInterval] { waits.withLock { $0 } }

        /// Captured by reference rather than by value: a `Mutex` is
        /// non-copyable, so the closure below takes the log and asks it.
        nonisolated private func record(_ seconds: TimeInterval) {
            waits.withLock { $0.append(seconds) }
        }

        /// The seam itself, ready to hand to `makeSource`.
        nonisolated var pause: @Sendable (TimeInterval) async throws -> Void {
            { [self] seconds in record(seconds) }
        }
    }

    /// What a gateway in front of a busy Overpass answers with, measured.
    private static let httpGatewayTimeout = 504
    /// What Overpass answers when it wants to be left alone for a while.
    private static let httpTooManyRequests = 429

    private static func gatewayRefusal() -> OverpassHTTPResponse {
        OverpassHTTPResponse(data: Data(), statusCode: httpGatewayTimeout, headers: [:])
    }

    /// The case the retry exists for: a slot was taken at the instant we
    /// knocked, and the search works on the second ask.
    @Test("a gateway refusal that arrives quickly is asked once more")
    func aQuickRefusalIsRetried() async throws {
        let pauses = PauseLog()
        let (source, stub) = Self.makeSource(
            [
                Self.gatewayRefusal(),
                Self.ok(Self.listingBody),
                Self.ok(Self.geometryBody),
            ],
            pause: pauses.pause
        )

        let trails = try await Self.search(source)

        #expect(trails.map(\.name) == ["Near Loop", "Far Path"], "the second ask answered")
        #expect(await stub.requestCount == 3, "the refused listing pass, again, then the geometry")
        #expect(pauses.recorded == [OverpassRequest.busyRetryDelay], "waited once, briefly")
    }

    /// One retry and not a loop. A server that refuses twice is telling us
    /// twice, and a client that keeps asking is the reason it is busy.
    @Test("a second refusal is the answer")
    func aSecondRefusalIsTheAnswer() async throws {
        let pauses = PauseLog()
        let (source, stub) = Self.makeSource(
            [Self.gatewayRefusal(), Self.gatewayRefusal()],
            pause: pauses.pause
        )

        let error = await #expect(throws: TrailGraphProviderError.self) {
            _ = try await Self.search(source)
        }

        #expect(await stub.requestCount == 2, "asked twice, and only twice")
        #expect(pauses.recorded.count == 1)
        #expect(
            CuratedTrailOutage(try #require(error)) == .busy,
            "and it reaches the hiker as busy rather than as unreachable"
        )
    }

    /// **The clause that keeps the pill from spinning for two minutes.** A
    /// refusal that took the whole budget is a server that spent it; the next
    /// ask would spend it again for the same answer, and the hiker waits twice
    /// as long to be told the same thing.
    @Test("a refusal that took the whole budget is not asked again")
    func aSlowRefusalIsNotRetried() async throws {
        let pauses = PauseLog()
        let clock = TestClock()
        let (source, stub) = Self.makeSource(
            [
                Self.gatewayRefusal(),
                Self.ok(Self.listingBody),
                Self.ok(Self.geometryBody),
            ],
            clock: clock,
            onRequest: { clock.advance(by: 25) },
            pause: pauses.pause
        )

        await #expect(throws: TrailGraphProviderError.self) {
            _ = try await Self.search(source)
        }

        #expect(await stub.requestCount == 1, "the slow refusal stands")
        #expect(pauses.recorded.isEmpty, "and nothing waited to ask again")
    }

    /// The refusal that is never retried, whatever it cost. A `429` names its
    /// own wait, and ``CuratedTrailSource`` refuses the next request without a
    /// round trip until it has passed.
    @Test("a rate limit is not asked again")
    func aRateLimitIsNotRetried() async throws {
        let pauses = PauseLog()
        let (source, stub) = Self.makeSource(
            [
                OverpassHTTPResponse(
                    data: Data(),
                    statusCode: Self.httpTooManyRequests,
                    headers: ["retry-after": "120"]
                ),
                Self.ok(Self.listingBody),
            ],
            pause: pauses.pause
        )

        await #expect(throws: TrailGraphProviderError.self) {
            _ = try await Self.search(source)
        }

        #expect(await stub.requestCount == 1)
        #expect(pauses.recorded.isEmpty)
    }

    /// The other half of *busy*, and the half that never reaches an HTTP
    /// status: a query the server abandoned answers `200` with a `remark`. The
    /// retry is wrapped around the decode for exactly this — see
    /// `OverpassConversation.retryingWhenBusy(_:)`.
    @Test("an abandoned query is asked once more too")
    func anAbandonedQueryIsRetried() async throws {
        let pauses = PauseLog()
        let (source, stub) = Self.makeSource(
            [
                Self.ok(#"{"elements":[],"remark":"runtime error: Query timed out"}"#),
                Self.ok(Self.listingBody),
                Self.ok(Self.geometryBody),
            ],
            pause: pauses.pause
        )

        let trails = try await Self.search(source)

        #expect(!trails.isEmpty)
        #expect(await stub.requestCount == 3)
        #expect(pauses.recorded == [OverpassRequest.busyRetryDelay])
    }
}
