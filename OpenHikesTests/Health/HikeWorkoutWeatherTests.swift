//
//  HikeWorkoutWeatherTests.swift
//  OpenHikesTests
//
//  When a finished walk carries the weather into Health, and — mostly — when
//  it does not. A stale or misplaced reading on a workout is worse than none,
//  because nothing in Health can dim it the way the badge dims its own.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Hike workout weather")
struct HikeWorkoutWeatherTests {
    private static let startedAt = Date(timeIntervalSince1970: 1_757_000_000)
    private static let endedAt = startedAt.addingTimeInterval(3 * 3600)
    private static let here = CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)
    /// The badge's dimming window — thirty minutes under the standard policy.
    private static let window = WeatherPollingPolicy.standard.stalenessInterval

    @Test("a reading about the hiker, taken during the walk, is kept")
    func aReadingDuringTheWalkIsKept() throws {
        let weather = try #require(
            Self.weather(.me(Self.here), capturedAt: Self.startedAt.addingTimeInterval(3600))
        )
        #expect(weather.temperature == Measurement(value: 9, unit: UnitTemperature.celsius))
        #expect(weather.humidity == WeatherConditions.preview.humidity)
    }

    /// Recording pins the badge to the hiker for its whole length, so a
    /// reading about anywhere else is a reading about somewhere else.
    @Test("a reading about a searched place or a selected trail is refused")
    func aReadingAboutSomewhereElseIsRefused() {
        let during = Self.startedAt.addingTimeInterval(3600)
        #expect(Self.weather(.place(Self.here, name: "Salzburg"), capturedAt: during) == nil)
        #expect(Self.weather(.trail(Self.here, hikeID: UUID(), name: "Thumsee"), capturedAt: during) == nil)
    }

    /// Last night's reading, restored by the badge at launch, is the case
    /// this rule exists for.
    @Test("a reading from before the walk, past the badge's window, is refused")
    func anOldReadingIsRefused() {
        let tooEarly = Self.startedAt.addingTimeInterval(-Self.window - 1)
        #expect(Self.weather(.me(Self.here), capturedAt: tooEarly) == nil)

        let justBefore = Self.startedAt.addingTimeInterval(-Self.window)
        #expect(Self.weather(.me(Self.here), capturedAt: justBefore) != nil)
    }

    @Test("a reading from long after the walk ended is refused")
    func aLateReadingIsRefused() {
        let tooLate = Self.endedAt.addingTimeInterval(Self.window + 1)
        #expect(Self.weather(.me(Self.here), capturedAt: tooLate) == nil)
    }

    @Test("no reading on the badge is no weather")
    func nothingOnTheBadgeIsNothing() {
        #expect(HikeWorkoutWeather(state: .idle, walkFrom: Self.startedAt, to: Self.endedAt) == nil)
        #expect(
            HikeWorkoutWeather(state: .loading(.me(Self.here)), walkFrom: Self.startedAt, to: Self.endedAt) == nil
        )
        #expect(
            HikeWorkoutWeather(state: .unavailable(.me(Self.here)), walkFrom: Self.startedAt, to: Self.endedAt)
                == nil
        )
    }

    private static func weather(_ subject: WeatherSubject, capturedAt: Date) -> HikeWorkoutWeather? {
        let snapshot = WeatherSnapshot(
            symbolName: "cloud.sun.fill",
            temperature: Measurement(value: 9, unit: UnitTemperature.celsius),
            conditionDescription: "Partly Cloudy",
            capturedAt: capturedAt,
            conditions: .preview
        )
        return HikeWorkoutWeather(
            state: .reading(snapshot, subject: subject),
            walkFrom: startedAt,
            to: endedAt
        )
    }
}
