//
//  WeatherSunPathTests.swift
//  OpenHikesTests
//
//  The daylight card draws the sun's day as one turn of a cosine with the
//  horizon across it. The curve is decoration unless the line crosses it at
//  sunrise and sunset, the sun stands on it where the clock says, and a
//  reading with no day to draw draws none.
//

import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Weather sun path")
struct WeatherSunPathTests {
    private static let hour: TimeInterval = 3600
    private static let noon = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A day of `hours` of light, centered on ``noon``.
    private static func path(hours: Double) throws -> WeatherSunPath {
        try #require(WeatherSunPath(
            sunrise: noon.addingTimeInterval(-hours / 2 * hour),
            sunset: noon.addingTimeInterval(hours / 2 * hour)
        ))
    }

    @Test("noon is the middle of the day's light")
    func noonIsTheMiddle() throws {
        let path = try #require(WeatherSunPath(
            sunrise: Self.noon.addingTimeInterval(-4 * Self.hour),
            sunset: Self.noon.addingTimeInterval(6 * Self.hour)
        ))

        #expect(path.noon == Self.noon.addingTimeInterval(Self.hour))
    }

    @Test("the sun is highest at noon and lowest at the midnights either side")
    func heights() throws {
        let path = try Self.path(hours: 12)

        #expect(path.height(at: Self.noon).isApproximatelyEqual(to: 1, absoluteTolerance: 0.001))
        #expect(path.height(at: Self.noon.addingTimeInterval(12 * Self.hour))
            .isApproximatelyEqual(to: -1, absoluteTolerance: 0.001))
        #expect(path.height(at: Self.noon.addingTimeInterval(-12 * Self.hour))
            .isApproximatelyEqual(to: -1, absoluteTolerance: 0.001))
        #expect(path.phase(at: Self.noon).isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
        #expect(path.phase(at: Self.noon.addingTimeInterval(6 * Self.hour))
            .isApproximatelyEqual(to: .pi / 2, absoluteTolerance: 0.001))
    }

    /// The whole point of the horizon's height: the curve is above it for
    /// exactly as long as the sun is up.
    @Test("the curve crosses the horizon at sunrise and at sunset", arguments: [6.0, 9.5, 12, 15, 20])
    func crossesAtSunriseAndSunset(hours: Double) throws {
        let path = try Self.path(hours: hours)

        #expect(path.height(at: path.sunrise).isApproximatelyEqual(to: path.horizon, absoluteTolerance: 0.001))
        #expect(path.height(at: path.sunset).isApproximatelyEqual(to: path.horizon, absoluteTolerance: 0.001))
        #expect(path.height(at: path.sunrise.addingTimeInterval(Self.hour)) > path.horizon)
        #expect(path.height(at: path.sunset.addingTimeInterval(Self.hour)) < path.horizon)
    }

    @Test("a short day leaves less of the curve above the horizon than a long one")
    func horizonFollowsTheSeason() throws {
        let winter = try Self.path(hours: 8)
        let equinox = try Self.path(hours: 12)
        let summer = try Self.path(hours: 16)

        #expect(winter.horizon > equinox.horizon)
        #expect(equinox.horizon > summer.horizon)
        #expect(equinox.horizon.isApproximatelyEqual(to: 0, absoluteTolerance: 0.001))
    }

    /// A reading can be drawn long after it was taken. Its sun stays at the
    /// end of the curve it ran off, rather than starting round again.
    @Test("a moment outside the day is held at the midnight it is beyond")
    func holdsOutsideTheDay() throws {
        let path = try Self.path(hours: 12)

        #expect(path.phase(at: Self.noon.addingTimeInterval(40 * Self.hour))
            .isApproximatelyEqual(to: .pi, absoluteTolerance: 0.001))
        #expect(path.phase(at: Self.noon.addingTimeInterval(-40 * Self.hour))
            .isApproximatelyEqual(to: -.pi, absoluteTolerance: 0.001))
    }

    @Test("the sun is up from sunrise until sunset")
    func isUp() throws {
        let path = try Self.path(hours: 10)

        #expect(path.isUp(at: path.sunrise))
        #expect(path.isUp(at: Self.noon))
        #expect(!path.isUp(at: path.sunset))
        #expect(!path.isUp(at: path.sunrise.addingTimeInterval(-1)))
    }

    /// North of the Arctic Circle in June there is no sunset to draw to.
    @Test("a reading without both times has no curve")
    func needsBothTimes() {
        let dusk = Self.noon.addingTimeInterval(7 * Self.hour)

        #expect(WeatherSunPath(WeatherDaylight(sunrise: Self.noon, sunset: nil, civilDusk: dusk)) == nil)
        #expect(WeatherSunPath(WeatherDaylight(sunrise: nil, sunset: Self.noon, civilDusk: dusk)) == nil)
        #expect(WeatherSunPath(WeatherDaylight(sunrise: nil, sunset: nil, civilDusk: nil)) == nil)
    }

    @Test("times that are not one day have no curve")
    func needsADay() {
        let later = Self.noon.addingTimeInterval(8 * Self.hour)

        #expect(WeatherSunPath(sunrise: later, sunset: Self.noon) == nil)
        #expect(WeatherSunPath(sunrise: Self.noon, sunset: Self.noon) == nil)
        #expect(WeatherSunPath(sunrise: Self.noon, sunset: Self.noon.addingTimeInterval(24 * Self.hour)) == nil)
        #expect(WeatherSunPath(sunrise: Self.noon, sunset: later) != nil)
    }
}
