//
//  WeatherReadingFormat.swift
//  OpenHikes
//
//  How a reading is put into words, and when it stops counting as one.
//
//  Both halves are here rather than in the views that draw them, because the
//  badge and its VoiceOver value were two independent renderings of the same
//  number and they disagreed. The badge drew `Int(temperature.value)` with a
//  bare degree sign, and WeatherKit hands this app Celsius: in `en_US` a
//  hiker read `12°` — twelve degrees Fahrenheit, which is −11 °C — while
//  VoiceOver, which did convert, said "53.6 degrees Fahrenheit" for the same
//  reading. On a hike a temperature is safety information, and the two
//  renderings have to be the same quantity by construction rather than by
//  someone remembering to change both.
//
//  So there is exactly one formatter here, and the only thing a caller picks
//  is how wide it spells the unit.
//

import Foundation
import OpenHikesData
import OpenHikesShared

nonisolated enum WeatherReadingFormat {
    private static let secondsPerMinute: Double = 60

    /// How much walking light is left, as a hiker would say it.
    ///
    /// Hours and minutes, abbreviated and dropping the zero field — "2 hr
    /// 40 min", "35 min" — because this number is read at a trailhead while
    /// deciding whether to go on, and "0 hr 35 min" makes that decision
    /// slower rather than more precise.
    ///
    /// Rounded **down** to the minute, which is the direction that cannot
    /// mislead: a hiker told they have forty minutes and given thirty-nine is
    /// fine, and one told forty who has thirty-nine and a half is being
    /// flattered by a rounding rule. Twilight is not a cliff edge, but the
    /// arithmetic should not be the optimistic part.
    ///
    /// **Floored to whole minutes before formatting, not after.** `.units`
    /// rounds the smallest field it is allowed to show, so handing it 2,370
    /// seconds with minutes as the floor renders "40 min" — flooring the
    /// *seconds* does nothing when seconds are not a field. Dropping the
    /// remainder here is what makes the sentence above true.
    ///
    /// `locale` takes the same seam every other formatter here does, so a
    /// suite can ask about a region rather than inheriting the simulator's.
    static func remainingLight(
        _ seconds: TimeInterval,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let whole = max(0, seconds)
        let flooredToMinute = (whole / secondsPerMinute).rounded(.down) * secondsPerMinute
        return Duration.seconds(flooredToMinute).formatted(
            .units(
                allowed: [.hours, .minutes],
                width: .abbreviated,
                zeroValueUnits: .hide
            )
            .locale(locale)
        )
    }

    /// The one place a temperature becomes text.
    ///
    /// The formatter itself is ``WidgetFormat/temperature(_:width:locale:)``
    /// in the shared package, and this is a name for it rather than a second
    /// copy — for the reason `HikeFormat.elevation` is: the widget draws this
    /// same reading on the home screen, and the app and the extension cannot
    /// round one quantity two ways. See that method for why `usage: .weather`
    /// and whole degrees, and this file's header for what the two independent
    /// renderings cost before there was one.
    ///
    /// Kept as a member here because every call site in the app reads
    /// `WeatherReadingFormat` for its other four, and sending one of the five
    /// somewhere else to be spelled would be the split that made them drift in
    /// the first place.
    static func temperature(
        _ measurement: Measurement<UnitTemperature>,
        width: Measurement<UnitTemperature>.FormatStyle.UnitWidth,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        WidgetFormat.temperature(measurement, width: width, locale: locale)
    }

    /// A fraction of one, as a percentage.
    ///
    /// Whole percent: humidity and cloud cover are both reported to far more
    /// precision than anybody can act on, and "72.4%" in a detail row reads as
    /// a measurement rather than as an observation.
    static func percentage(
        _ fraction: Double,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        fraction.formatted(
            .percent.precision(.fractionLength(0)).locale(locale)
        )
    }

    /// A wind speed, in whatever unit the reader's region measures speed in.
    ///
    /// `usage: .general` for the reason ``HikeFormat/speed(_:locale:)`` uses
    /// it: `.asProvided` renders the unit it was handed, which would pin every
    /// reader in the world to the provider's metres per second. `.general`
    /// gives mph for `en_US` and km/h for `de_DE` from the same input.
    ///
    /// Whole units, unlike the hiker's own pace, which carries one decimal.
    /// A tenth of a kilometre per hour separates one stroll from another and
    /// means nothing at all about wind.
    static func windSpeed(
        _ measurement: Measurement<UnitSpeed>,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard measurement.value.isFinite else { return "\u{2014}" }
        return measurement.formatted(
            .measurement(
                width: .abbreviated,
                usage: .general,
                numberFormatStyle: .number.precision(.fractionLength(0))
            )
            .locale(locale)
        )
    }

    /// Which way the wind is coming from, as a compass point.
    ///
    /// Sixteen points rather than the degrees the provider sends, because a
    /// direction is read and not calculated: nobody stands at a junction
    /// working out where 315° is. Sixteen rather than eight because eight puts
    /// a forty-five degree error on every reading, and rather than
    /// thirty-two because the extra points are names most readers cannot
    /// place.
    ///
    /// The bearing is the direction the wind blows *from*, which is the
    /// convention every forecast uses — see ``WeatherWind/direction``.
    static func windDirection(_ measurement: Measurement<UnitAngle>) -> String? {
        let degrees = measurement.converted(to: .degrees).value
        guard degrees.isFinite else { return nil }
        let sector = Int((degrees / Self.compassSectorDegrees).rounded())
        let points = Self.compassPoints
        return points[((sector % points.count) + points.count) % points.count]
    }

    private static let compassSectorDegrees = 22.5

    /// North first, clockwise. Localized one by one rather than interpolated,
    /// because these are abbreviations rather than letters: a language whose
    /// word for north does not begin with N spells its own.
    private static let compassPoints: [String] = [
        String(localized: "N"),
        String(localized: "NNE"),
        String(localized: "NE"),
        String(localized: "ENE"),
        String(localized: "E"),
        String(localized: "ESE"),
        String(localized: "SE"),
        String(localized: "SSE"),
        String(localized: "S"),
        String(localized: "SSW"),
        String(localized: "SW"),
        String(localized: "WSW"),
        String(localized: "W"),
        String(localized: "WNW"),
        String(localized: "NW"),
        String(localized: "NNW"),
    ]

    /// Barometric pressure, in the reader's own unit.
    ///
    /// `usage: .barometric` is what makes that happen: inches of mercury for
    /// `en_US`, hectopascals almost everywhere else. Whole units for the
    /// former is wrong — 29.92 inHg is the interesting figure and 30 inHg is
    /// not — so the precision is given a range rather than a number, and each
    /// region gets the digits its unit is read to.
    static func pressure(
        _ measurement: Measurement<UnitPressure>,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard measurement.value.isFinite else { return "\u{2014}" }
        return measurement.formatted(
            .measurement(
                width: .abbreviated,
                usage: .barometric,
                numberFormatStyle: .number.precision(.fractionLength(0...2))
            )
            .locale(locale)
        )
    }

    /// How far it can be seen, in the unit the region measures road distance
    /// in.
    ///
    /// `usage: .road`, which is the same question the hike's own distance row
    /// asks and therefore the answer that agrees with it: kilometres where the
    /// signs are metric, miles where they are not.
    static func visibility(
        _ measurement: Measurement<UnitLength>,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard measurement.value.isFinite else { return "\u{2014}" }
        return measurement.formatted(
            .measurement(width: .abbreviated, usage: .road)
                .locale(locale)
        )
    }

    /// Rain or snow, as a depth per hour.
    ///
    /// `usage: .rainfall` picks millimetres or inches by region; the hour is
    /// spelled beside it, because Foundation formats quantities and not rates.
    /// See ``WeatherConditions/precipitationIntensity`` for why this is a
    /// length at all when the provider calls it a speed.
    static func precipitation(
        _ measurement: Measurement<UnitLength>,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard measurement.value.isFinite else { return "\u{2014}" }
        let depth = measurement.formatted(
            .measurement(
                width: .abbreviated,
                usage: .rainfall,
                numberFormatStyle: .number.precision(.fractionLength(0...1))
            )
            .locale(locale)
        )
        return String(localized: "\(depth)/h", comment: "A depth of rain per hour")
    }

    /// The ultraviolet index: the number the sun is rated at, and the band it
    /// falls in.
    ///
    /// Both, because neither is enough on its own. "8" means nothing to
    /// somebody who does not know the scale, and "Very High" throws away the
    /// one part of it that can be compared against yesterday.
    static func uvIndex(_ index: WeatherUVIndex) -> String {
        String(
            localized: "\(index.value) \(index.category.label)",
            comment: "A UV index number followed by its exposure band"
        )
    }

    /// How old a reading is, in words.
    ///
    /// Two units at most, and seconds are allowed only because they are the
    /// only truthful answer for a reading taken moments ago — "0 minutes" is
    /// what the coarser set produces there, and it reads as a bug. Above a
    /// minute the seconds fall away on their own.
    static func age(
        _ interval: TimeInterval,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        Duration.seconds(max(0, interval)).formatted(
            .units(
                allowed: [.days, .hours, .minutes, .seconds],
                width: .wide,
                maximumUnitCount: 2
            )
            .locale(locale)
        )
    }
}

nonisolated extension WeatherPollingPolicy {
    /// How old a reading may get before the app stops presenting it as the
    /// current conditions.
    ///
    /// Two freshness intervals — half an hour at the standard policy — and it
    /// is derived from that policy rather than chosen next to it, so lowering
    /// the refresh rate moves this with it.
    ///
    /// The argument for *two*: one interval is simply "due for a refresh",
    /// which happens constantly and harmlessly — a poll a few seconds late, a
    /// hiker who has not moved, a request already in flight — and dimming
    /// there would cry wolf on the ordinary case. By two, the reading has had
    /// one whole scheduled refresh miss plus the entire backoff ladder
    /// (`retryDelays`: 5 s, 30 s, 2 min, then 15 min) fail against it, which
    /// is four or more refused attempts. That is a hiker out of signal, or an
    /// entitlement that has stopped answering, rather than a slow response.
    ///
    /// WeatherKit's own `WeatherMetadata.expirationDate` was the obvious
    /// alternative and is the wrong instrument: it is the provider saying when
    /// *it* will have new data (typically around an hour out), not this app
    /// saying when it last managed to reach the provider. A hiker who has
    /// been out of signal for fifty minutes would still be shown an
    /// unqualified reading from before the front came through.
    var stalenessInterval: TimeInterval { freshnessInterval * 2 }
}

extension WeatherSnapshot {
    /// What the badge draws — the shortest spelling the locale accepts, which
    /// is a bare `54°` where the unit is unambiguous and `12 °C` where it is
    /// not.
    func formattedTemperature(locale: Locale = .autoupdatingCurrent) -> String {
        WeatherReadingFormat.temperature(temperature, width: .narrow, locale: locale)
    }

    /// What VoiceOver speaks: the same rounded quantity, unit spelled out.
    func spokenTemperature(locale: Locale = .autoupdatingCurrent) -> String {
        WeatherReadingFormat.temperature(temperature, width: .wide, locale: locale)
    }

    /// How long ago this reading was taken. Clamped at zero, because a
    /// provider clock a second ahead of the device's would otherwise produce a
    /// negative age and a reading from the future.
    func age(asOf now: Date = .now) -> TimeInterval {
        max(0, now.timeIntervalSince(capturedAt))
    }

    func formattedAge(
        asOf now: Date = .now,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        WeatherReadingFormat.age(age(asOf: now), locale: locale)
    }

    /// When this reading stops counting as the current conditions — the
    /// deadline the badge dims at.
    func stalenessDate(policy: WeatherPollingPolicy = .standard) -> Date {
        capturedAt.addingTimeInterval(policy.stalenessInterval)
    }

    func isStale(
        asOf now: Date = .now,
        policy: WeatherPollingPolicy = .standard
    ) -> Bool {
        age(asOf: now) >= policy.stalenessInterval
    }
}
