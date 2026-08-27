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
//  walker read `12°` — twelve degrees Fahrenheit, which is −11 °C — while
//  VoiceOver, which did convert, said "53.6 degrees Fahrenheit" for the same
//  reading. On a hike a temperature is safety information, and the two
//  renderings have to be the same quantity by construction rather than by
//  someone remembering to change both.
//
//  So there is exactly one formatter here, and the only thing a caller picks
//  is how wide it spells the unit.
//

import Foundation

nonisolated enum WeatherReadingFormat {
    /// The one place a temperature becomes text.
    ///
    /// `usage: .weather` rather than the default `.general`: both convert to
    /// the locale's preferred unit, but only `.weather` asks for the unit that
    /// locale uses *for weather*, which is the question being asked here.
    ///
    /// The precision is pinned at whole degrees rather than left at the
    /// style's default, which carries every digit WeatherKit sent through the
    /// conversion: 12.3456 °C formats as `54.22208°`, in a capsule laid out
    /// for three characters. Rounding here — rather than at the call site the
    /// way the old badge did — is what keeps the spoken value on the same
    /// number as the drawn one.
    static func temperature(
        _ measurement: Measurement<UnitTemperature>,
        width: Measurement<UnitTemperature>.FormatStyle.UnitWidth,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        measurement.formatted(
            .measurement(
                width: width,
                usage: .weather,
                numberFormatStyle: .number.precision(.fractionLength(0))
            )
            .locale(locale)
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

extension WeatherPollingPolicy {
    /// How old a reading may get before the app stops presenting it as the
    /// current conditions.
    ///
    /// Two freshness intervals — half an hour at the standard policy — and it
    /// is derived from that policy rather than chosen next to it, so lowering
    /// the refresh rate moves this with it.
    ///
    /// The argument for *two*: one interval is simply "due for a refresh",
    /// which happens constantly and harmlessly — a poll a few seconds late, a
    /// walker who has not moved, a request already in flight — and dimming
    /// there would cry wolf on the ordinary case. By two, the reading has had
    /// one whole scheduled refresh miss plus the entire backoff ladder
    /// (`retryDelays`: 5 s, 30 s, 2 min, then 15 min) fail against it, which
    /// is four or more refused attempts. That is a walker out of signal, or an
    /// entitlement that has stopped answering, rather than a slow response.
    ///
    /// WeatherKit's own `WeatherMetadata.expirationDate` was the obvious
    /// alternative and is the wrong instrument: it is the provider saying when
    /// *it* will have new data (typically around an hour out), not this app
    /// saying when it last managed to reach the provider. A walker who has
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
