//
//  WeatherFreshnessTests.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import Testing

/// When a preserved reading stops counting as the current conditions.
///
/// ``WeatherManager/update(for:)`` keeps the last successful snapshot when
/// WeatherKit fails, which is deliberate — an empty badge is worse than a
/// twenty-minute-old temperature — and used to leave a walker who had lost
/// signal reading an hours-old number with nothing saying so.
@Suite("Weather freshness")
struct WeatherFreshnessTests {
    private let capturedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let policy = WeatherPollingPolicy(
        freshnessInterval: 900,
        retryDelays: [5, 30, 120]
    )

    @Test("the staleness window is two refresh intervals")
    func windowFollowsThePolicy() {
        #expect(policy.stalenessInterval == 1800)
        // Derived rather than a constant beside it: halving the refresh rate
        // has to halve this too, or a badge dims a full interval late.
        #expect(WeatherPollingPolicy.standard.stalenessInterval
            == WeatherPollingPolicy.standard.freshnessInterval * 2)
    }

    @Test("a reading one refresh interval old is still current")
    func oneIntervalIsNotStale() {
        let snapshot = reading(capturedAt: capturedAt)
        let dueForRefresh = capturedAt.addingTimeInterval(policy.freshnessInterval)

        #expect(!snapshot.isStale(asOf: dueForRefresh, policy: policy))
        // A second before the window closes it is still presented as current;
        // the boundary is what a walker standing in patchy signal sits on.
        #expect(!snapshot.isStale(
            asOf: capturedAt.addingTimeInterval(policy.stalenessInterval - 1),
            policy: policy
        ))
    }

    @Test("a reading past the window is stale")
    func twoIntervalsIsStale() {
        let snapshot = reading(capturedAt: capturedAt)

        #expect(snapshot.isStale(
            asOf: capturedAt.addingTimeInterval(policy.stalenessInterval),
            policy: policy
        ))
        #expect(snapshot.isStale(
            asOf: capturedAt.addingTimeInterval(4 * 3600),
            policy: policy
        ))
    }

    @Test("the badge's dimming deadline is the moment the window closes")
    func stalenessDateIsTheWindowEdge() {
        let snapshot = reading(capturedAt: capturedAt)

        #expect(snapshot.stalenessDate(policy: policy)
            == capturedAt.addingTimeInterval(1800))
    }

    /// A provider clock a little ahead of the device's would otherwise hand
    /// the sheet a negative interval and a reading from the future.
    @Test("a reading stamped in the future has no negative age")
    func futureReadingClampsToZero() {
        let snapshot = reading(capturedAt: capturedAt.addingTimeInterval(30))

        #expect(snapshot.age(asOf: capturedAt) == 0)
        #expect(!snapshot.isStale(asOf: capturedAt, policy: policy))
    }

    @Test("the sheet spells the exact age out")
    func ageIsSpelledOut() {
        let snapshot = reading(capturedAt: capturedAt)
        let locale = Locale(identifier: "en_US")

        #expect(snapshot.formattedAge(
            asOf: capturedAt.addingTimeInterval(45 * 60),
            locale: locale
        ) == "45 minutes")
        #expect(snapshot.formattedAge(
            asOf: capturedAt.addingTimeInterval(75 * 60),
            locale: locale
        ) == "1 hour, 15 minutes")
        // Seconds are in the allowed set only for this case: the coarser set
        // renders a reading taken moments ago as "0 minutes".
        #expect(snapshot.formattedAge(
            asOf: capturedAt.addingTimeInterval(20),
            locale: locale
        ) == "20 seconds")
    }

    private func reading(capturedAt: Date) -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "cloud.sun.fill",
            temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
            conditionDescription: "Partly Cloudy",
            capturedAt: capturedAt
        )
    }
}
