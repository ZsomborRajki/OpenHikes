//
//  PlausibleTimestampTests.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikesData
import Testing

@Suite("Plausible timestamps")
struct PlausibleTimestampTests {
    private static let now = Date(timeIntervalSince1970: 1_792_000_000)

    @Test(
        "A placeholder stamp is treated as absent",
        arguments: [
            ("0001-01-01T00:00:00Z", "DateTime.MinValue"),
            ("1970-01-01T00:00:00Z", "the Unix epoch"),
            ("1989-12-31T00:00:00Z", "the FIT epoch"),
        ]
    )
    func placeholdersAreRefused(stamp: String, why: String) throws {
        let date = try Date(stamp, strategy: .iso8601)
        #expect(PlausibleTimestamp.validated(date, now: Self.now) == nil, "\(why)")
    }

    @Test("A recent stamp passes through unchanged")
    func recentStampPasses() {
        let date = Self.now.addingTimeInterval(-3600)
        #expect(PlausibleTimestamp.validated(date, now: Self.now) == date)
    }

    @Test("Non-finite timestamps are absent", arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteStampsAreRefused(seconds: Double) {
        let date = Date(timeIntervalSinceReferenceDate: seconds)
        #expect(PlausibleTimestamp.validated(date, now: Self.now) == nil)
    }

    @Test("The earliest timestamp is included, and anything before it is absent")
    func earliestBoundary() {
        let earliest = PlausibleTimestamp.earliest
        #expect(PlausibleTimestamp.validated(earliest, now: Self.now) == earliest)
        #expect(PlausibleTimestamp.validated(earliest.addingTimeInterval(-1), now: Self.now) == nil)
    }

    @Test("The window is a day wide past now, and a stamp beyond it is refused")
    func futureIsBounded() {
        #expect(PlausibleTimestamp.validated(Self.now.addingTimeInterval(3600), now: Self.now) != nil)
        #expect(PlausibleTimestamp.validated(Self.now.addingTimeInterval(2 * 86_400), now: Self.now) == nil)
        let latest = Self.now.addingTimeInterval(PlausibleTimestamp.futureTolerance)
        #expect(PlausibleTimestamp.validated(latest, now: Self.now) == latest)
        #expect(PlausibleTimestamp.validated(latest.addingTimeInterval(1), now: Self.now) == nil)
    }

    @Test("No stamp stays no stamp")
    func nilStaysNil() {
        #expect(PlausibleTimestamp.validated(nil, now: Self.now) == nil)
    }
}
