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

    private static func figures(
        in locale: Locale,
        speed: Double? = hourlyFiveKilometers,
        heartRate: Double? = 112
    ) -> WatchRecordingFigures {
        WatchRecordingFigures(
            distanceMeters: 5000,
            elevationGainMeters: 342,
            averageSpeedMetersPerSecond: speed,
            heartRateBPM: heartRate,
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

    @Test("the speed is in the unit the region measures road speed in")
    func speedFollowsTheLocale() {
        #expect(Self.figures(in: Self.metric).averageSpeed.value.contains("km/h"))
        #expect(Self.figures(in: Self.imperial).averageSpeed.value.contains("mph"))
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

    /// Before the second fix there is no average, and a covered sensor has no
    /// heart rate; a zero for either would be a claim about the walk.
    @Test("nothing to say is a dash, never a zero")
    func missingFiguresAreDashes() {
        let figures = Self.figures(in: Self.metric, speed: nil, heartRate: nil)
        #expect(figures.averageSpeed.value == "—")
        #expect(figures.heartRate.value == "—")
    }

    @Test("a heart rate is whole beats")
    func heartRateIsWholeBeats() {
        #expect(Self.figures(in: Self.metric, heartRate: 111.6).heartRate == .init(title: "Heart", value: "112"))
    }
}
