//
//  WeatherSunPath.swift
//  OpenHikes
//
//  The sun's day as a curve, for the daylight card to draw.
//
//  The card says how much light is left in words, and a hiker reads the
//  times beside it. The curve is the same answer at a glance: where the sun
//  is on its way across, and how much of the way is still above the horizon.
//
//  It is one turn of a cosine, a day wide and highest at solar noon, with
//  the horizon drawn across it at the height the curve has at sunrise and at
//  sunset. So a short winter day leaves only the top of the curve above the
//  line and a midsummer day nearly all of it, with no second set of figures:
//  the two times the reading already carries decide both.
//
//  Solar noon is taken as the middle of the day's light. That is not the
//  moment the almanac gives, but the reading has no other, and the two differ
//  by less than the dot is wide.
//

import Foundation

nonisolated struct WeatherSunPath: Equatable, Sendable {
    private static let daySeconds: TimeInterval = 86_400

    let sunrise: Date
    let sunset: Date

    /// `nil` where the reading has no sunrise or no sunset (a polar summer
    /// has neither), or where they are not a day: out of order, or a day
    /// apart.
    init?(_ daylight: WeatherDaylight) {
        guard let rises = daylight.sunrise, let sets = daylight.sunset else { return nil }
        self.init(sunrise: rises, sunset: sets)
    }

    init?(sunrise: Date, sunset: Date) {
        let length = sunset.timeIntervalSince(sunrise)
        guard length > 0, length < Self.daySeconds else { return nil }
        self.sunrise = sunrise
        self.sunset = sunset
    }

    /// The middle of the day's light.
    var noon: Date {
        sunrise.addingTimeInterval(sunset.timeIntervalSince(sunrise) / 2)
    }

    /// Where on the curve a moment is, in radians: 0 at noon, −π at the
    /// midnight before and π at the midnight after. A moment outside that day
    /// is held at the midnight it is beyond.
    func phase(at date: Date) -> Double {
        let turn = date.timeIntervalSince(noon) / Self.daySeconds * 2 * .pi
        return min(max(turn, -.pi), .pi)
    }

    /// How high the sun stands at a moment, 1 at noon and −1 at midnight.
    func height(at date: Date) -> Double {
        cos(phase(at: date))
    }

    /// The height the curve has at sunrise and at sunset, which is where
    /// the horizon is drawn.
    var horizon: Double {
        height(at: sunrise)
    }

    /// Whether the sun is above the horizon at a moment.
    func isUp(at date: Date) -> Bool {
        sunrise <= date && date < sunset
    }
}
