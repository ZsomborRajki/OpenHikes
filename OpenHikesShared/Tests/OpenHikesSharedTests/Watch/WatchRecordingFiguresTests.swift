//
//  WatchRecordingFiguresTests.swift
//  OpenHikesSharedTests
//
//  What the watch's recording screen calls each live figure, and how it
//  formats it. Every locale is pinned: `swift test` runs in whatever region
//  the host is set to, which may be en_US on a CI runner and metric on a
//  developer's Mac, and a caption is only proven to agree with its unit in
//  both.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch recording figures")
struct WatchRecordingFiguresTests {
    private static let metric = Locale(identifier: "de_DE")
    private static let imperial = Locale(identifier: "en_US")
    /// Five kilometres in an hour: 5 km/h, which as a pace would be 12 min/km.
    private static let hourlyFiveKilometers = 5000.0 / 3600
    /// The screen's clock. A fixed instant rather than `.now`, so a reading's
    /// age is exactly what each test says it is.
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func figures(
        in locale: Locale,
        climb: Double? = 342,
        speed: Double? = hourlyFiveKilometers,
        heartRate: Double? = 112,
        heartRateAge: TimeInterval? = 5
    ) -> WatchRecordingFigures {
        WatchRecordingFigures(
            distanceMeters: 5000,
            elevationGainMeters: climb,
            averageSpeedMetersPerSecond: speed,
            heartRateBPM: heartRate,
            heartRateSampledAt: heartRateAge.map { now.addingTimeInterval(-$0) },
            now: now,
            locale: locale
        )
    }

    /// The bug this suite was written for: the watch drew "5.0 km/h" under
    /// "Pace". The phone's recording screen captions the same average
    /// "Avg Speed", and the value is the one formatter both devices use.
    @Test("the average is captioned as a speed, as the phone captions it", arguments: [metric, imperial])
    func averageIsCaptionedAsASpeed(locale: Locale) {
        let speed = Self.figures(in: locale).averageSpeed
        #expect(speed.title == "Avg Speed")
        #expect(speed.value == WidgetFormat.speed(metersPerSecond: Self.hourlyFiveKilometers, locale: locale))
    }

    /// Pinned whole rather than compared with the formatter, which is what
    /// the test above does: a value that turned into a pace, or lost its
    /// decimal, would still equal the formatter it was built with.
    @Test("the speed reads in the region's road unit, to one decimal")
    func speedFollowsTheLocale() {
        #expect(Self.figures(in: Self.metric).averageSpeed.value == "5,0 km/h")
        #expect(Self.figures(in: Self.imperial).averageSpeed.value == "3.1 mph")
    }

    @Test("distance and climb are formatted as everywhere else")
    func distanceAndClimbShareTheWidgetFormat() {
        let figures = Self.figures(in: Self.imperial)
        #expect(figures.distance == .init(
            title: "Distance",
            value: WidgetFormat.length(meters: 5000, locale: Self.imperial)
        ))
        #expect(figures.climb == .init(
            title: "Climb",
            value: WidgetFormat.elevation(meters: 342, locale: Self.imperial)
        ))
    }

    /// Before the second fix there is no average, and before HealthKit's
    /// first sample there is no heart rate; a zero for either would be a
    /// claim about the walk.
    @Test("nothing to say is a dash, never a zero")
    func missingFiguresAreDashes() {
        let figures = Self.figures(in: Self.metric, speed: nil, heartRate: nil)
        #expect(figures.averageSpeed.value == "—")
        #expect(figures.heartRate.value == "—")
    }

    /// #1026: the watch read "0 m" before a second trusted height, and all
    /// through a walk whose heights the altitude policy refused, where the
    /// phone draws a dash for the same climb.
    @Test("a climb with no change measured yet is a dash")
    func unmeasuredClimbIsADash() {
        #expect(Self.figures(in: Self.metric, climb: nil).climb == .init(title: "Climb", value: "—"))
    }

    /// The other half: a level walk that has been measured did climb
    /// nothing, and says so.
    @Test("a measured level walk climbs 0 m", arguments: [(metric, "0 m"), (imperial, "0 ft")])
    func measuredLevelWalkReadsZero(locale: Locale, expected: String) {
        #expect(Self.figures(in: locale, climb: 0).climb.value == expected)
    }

    /// `Int(_:)` traps on these, and this screen is where a crash costs the
    /// walk.
    @Test("a heart rate that is not a number is no reading", arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteHeartRateIsADash(beats: Double) {
        #expect(Self.figures(in: Self.metric, heartRate: beats).heartRate.value == "—")
    }

    @Test("a heart rate is whole beats")
    func heartRateIsWholeBeats() {
        #expect(Self.figures(in: Self.metric, heartRate: 111.6).heartRate == .init(title: "Heart", value: "112"))
    }

    /// #1024: the builder's most recent sample never goes back to nothing, so
    /// the last reading stayed up as the live one after the sensor stopped.
    @Test("a reading older than the window is no reading", arguments: [
        WatchRecordingFigures.heartRateFreshness,
        WatchRecordingFigures.heartRateFreshness + 1,
        600,
    ])
    func staleHeartRateIsADash(age: TimeInterval) {
        #expect(Self.figures(in: Self.metric, heartRateAge: age).heartRate.value == "—")
    }

    @Test("a reading inside the window shows its beats", arguments: [
        0,
        WatchRecordingFigures.heartRateFreshness - 1,
    ])
    func freshHeartRateShowsItsBeats(age: TimeInterval) {
        #expect(Self.figures(in: Self.metric, heartRateAge: age).heartRate.value == "112")
    }

    /// Nothing says how old it is, so nothing says it is current.
    @Test("a reading with no sample time is no reading")
    func undatedHeartRateIsADash() {
        #expect(Self.figures(in: Self.metric, heartRateAge: nil).heartRate.value == "—")
    }

    /// The screen is drawn again at the expiry, which no new sample would
    /// prompt, and the figure judged there is the dash.
    @Test("the screen is redrawn the moment a reading goes stale")
    func redrawsAtTheExpiry() throws {
        let sampledAt = Self.now
        let redraws = WatchRecordingFigures.heartRateRedraws(sampledAt: sampledAt)
        #expect(redraws.first == sampledAt)
        let expiry = try #require(redraws.last)
        #expect(expiry == sampledAt.addingTimeInterval(WatchRecordingFigures.heartRateFreshness))
        let atExpiry = WatchRecordingFigures(
            distanceMeters: 0,
            elevationGainMeters: 0,
            averageSpeedMetersPerSecond: nil,
            heartRateBPM: 112,
            heartRateSampledAt: sampledAt,
            now: expiry,
            locale: Self.metric
        )
        #expect(atExpiry.heartRate.value == "—")
        #expect(WatchRecordingFigures.heartRateRedraws(sampledAt: nil).isEmpty)
    }
}
