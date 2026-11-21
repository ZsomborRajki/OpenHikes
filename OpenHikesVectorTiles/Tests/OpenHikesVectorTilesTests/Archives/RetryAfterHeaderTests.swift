//
//  RetryAfterHeaderTests.swift
//  OpenHikesVectorTilesTests
//
//  The reading of `Retry-After`: its two spellings, what counts as no advice
//  at all, the ceiling on what is honored, and which responses carry any.
//  What a client does with the deadline is its own to test: the tile
//  server's in `VectorTileClientTests`, and the app's raster tiles and
//  Overpass in the app's suites.
//

import Foundation
import OpenHikesVectorTiles
import Testing

@Suite("Retry-After header")
struct RetryAfterHeaderTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func response(
        status: Int,
        headers: [String: String] = [:]
    ) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://tiles.example.invalid/14/2638/6357.png"))
        return try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
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

    /// The zone field is read as a *name*, not as the literal text `GMT`, and
    /// `UTC` names the same offset. Pinned because the parser was moved off
    /// `DateFormatter`'s `zzz` onto `Date.ParseStrategy`, and a verbatim
    /// `GMT` would have quietly narrowed what the client accepts.
    @Test("UTC names the same zone as GMT")
    func utcSpellingIsRead() {
        let value = Self.imfFixdate(now.addingTimeInterval(120))
            .replacingOccurrences(of: "GMT", with: "UTC")
        #expect(RetryAfterHeader.delay(from: value, now: now) == .seconds(120))
    }

    /// The value is the date or it is not advice. `Date.ParseStrategy.parse`
    /// would stop as soon as it had read one and hand back a deadline from a
    /// header it only half understood, so the match has to be a whole one.
    @Test("a date with something after it is not a date")
    func trailingTextIsRefused() {
        let value = Self.imfFixdate(now.addingTimeInterval(120)) + " and change"
        #expect(RetryAfterHeader.delay(from: value, now: now) == nil)
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
    func onlyRateLimitStatusesAreHonored(status: Int) throws {
        let refusal = try response(status: status, headers: [RetryAfterHeader.name: "90"])
        let advice = RetryAfterHeader.delay(from: refusal, now: now)
        #expect((advice != nil) == RetryAfterHeader.honoredStatusCodes.contains(status))
    }

    @Test("a rate limit with no header carries no advice")
    func rateLimitWithoutHeaderCarriesNothing() throws {
        let refusal = try response(status: RetryAfterHeader.tooManyRequests)
        #expect(RetryAfterHeader.delay(from: refusal, now: now) == nil)
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
