//
//  HikeFormat.swift
//  OpenHikes
//
//  Formatting helpers for hike stats (duration, elevation, speed).
//

import Foundation
import OpenHikesShared

nonisolated public enum HikeFormat {
    /// Under an hour the interesting unit is seconds; over it, minutes.
    ///
    /// `Duration.UnitsFormatStyle` rather than `DateComponentsFormatter`: the
    /// old formatter is a mutable `NSObject` that has to be configured per
    /// call (`allowedUnits` depends on the interval), so every stat tile on
    /// the detail screen allocated and threw away one. A format style is a
    /// `Sendable` value, so the two shapes are `static let` and the call site
    /// only picks between them.
    ///
    /// `.narrow`, not `.abbreviated`, despite the old formatter's style being
    /// spelled `.abbreviated`: the two frameworks disagree about what the word
    /// means. `Duration`'s `.abbreviated` is "1 hr, 25 min"; its `.narrow` is
    /// "1h 25m", which is what `DateComponentsFormatter.abbreviated` produced
    /// and what a stat tile has room for.
    private static let longStyle = Duration.UnitsFormatStyle(
        allowedUnits: [.hours, .minutes],
        width: .narrow
    )
    private static let shortStyle = Duration.UnitsFormatStyle(
        allowedUnits: [.minutes, .seconds],
        width: .narrow
    )

    public static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "—" }
        let duration = Duration.seconds(interval)
        return interval >= 3600
            ? duration.formatted(longStyle)
            : duration.formatted(shortStyle)
    }

    /// The same two shapes, in words, for a sentence that is read aloud.
    ///
    /// ``duration(_:)`` is `.narrow` because that is what a stat tile has room
    /// for, and a voice answer has no tile: a speech synthesiser handed "1h
    /// 25m" is being asked to guess, exactly as one handed "2.4 km" is. The
    /// allowed units are the same, so the same hike is described in the same
    /// terms on the screen and out loud — only the spelling differs.
    private static let spokenLongStyle = Duration.UnitsFormatStyle(
        allowedUnits: [.hours, .minutes],
        width: .wide
    )
    private static let spokenShortStyle = Duration.UnitsFormatStyle(
        allowedUnits: [.minutes, .seconds],
        width: .wide
    )

    public static func spokenDuration(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "—" }
        let duration = Duration.seconds(interval)
        return interval >= 3600
            ? duration.formatted(spokenLongStyle)
            : duration.formatted(spokenShortStyle)
    }

    /// How long a planned route takes, as Apple Maps writes it on a route —
    /// "1 hr, 5 min" — rounded up to the minute, and never "0 min".
    ///
    /// ``WidgetFormat/timeLeft(seconds:width:)``, which the widget and the
    /// Live Activity draw time left with: one rule for a time still to come,
    /// wherever it is shown.
    public static func travelTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "—" }
        return WidgetFormat.timeLeft(seconds: interval)
    }

    public static func spokenTravelTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "—" }
        return WidgetFormat.timeLeft(seconds: interval, width: .wide)
    }

    /// The date and the time to the minute — what a photograph, a map pin and
    /// the sync status all put beside themselves.
    ///
    /// `static let` for the same reason the two above are, and it matters more
    /// here: these are attached per cell. A `Date.FormatStyle` written at the
    /// call site is a fresh value each time, so a grid of a dozen photographs
    /// built a dozen of them on every pass, and the pass ran on every tick of
    /// a checkbox.
    ///
    /// Safe to hold: `Date.FormatStyle` defaults to `Locale.autoupdatingCurrent`,
    /// so a static one still follows a change of language or region.
    private static let timestampStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)
    /// The time alone, for a caption already sitting under a known date.
    private static let timeOfDayStyle = Date.FormatStyle(date: .omitted, time: .shortened)

    public static func timestamp(_ date: Date) -> String {
        date.formatted(timestampStyle)
    }

    public static func timeOfDay(_ date: Date) -> String {
        date.formatted(timeOfDayStyle)
    }

    /// A height: whole metres, or whole feet where that is the local unit,
    /// and never promoted to kilometres — a 1,250 m summit is 1,250 m high,
    /// not "1.2 km" high, which is what `.road` and `.general` would both
    /// make of it.
    ///
    /// This was `length(_:)`, and it formatted `usage: .asProvided` on a
    /// measurement built in metres, so it rendered metres to every reader in
    /// the world while the distance beside it used `usage: .road` and adapted.
    /// A US reader read "3.1 mi" and "1,250 m" in the same stats card — and
    /// the widget's formatter had already been given the conversion, so the
    /// app and the widget disagreed about the same hike. That is the same bug
    /// ``speed(_:locale:)`` and `WeatherReadingFormat` were each fixed for;
    /// elevation is the row that was never given the treatment. It is that
    /// formatter now, ``WidgetFormat/elevation(meters:locale:width:)``, rather
    /// than a second copy of its conversion — which is what the eighteen
    /// locales ``WidgetFormat/prefersImperialRoadUnits(in:)`` names needed:
    /// `en_LR` drew "5 km" and "4,101 ft" in one stat grid while the copy
    /// here still asked `measurementSystem`.
    ///
    /// Renamed at the same time, because the old name is what let *Inferred
    /// Path* — a distance — be formatted by the elevation formatter without
    /// anyone noticing. A distance uses `usage: .road` directly, the way the
    /// *Distance* row it sits beneath always has.
    ///
    /// A dash for a figure that isn't a number, the same answer
    /// ``duration(_:)`` gives and for the same reason: an elevation total
    /// derived from a route carrying a non-finite height formats as "∞ m" or
    /// "NaN m", and both read on a stat tile as though something had been
    /// measured.
    ///
    /// The `locale` parameter is a test seam, as it is on ``speed(_:locale:)``
    /// and for the same reason: region is the input this is sensitive to, and
    /// a suite that could only ask about the simulator's own region would
    /// assert whatever the machine happened to be set to — which is exactly
    /// how a formatting bug survives a green test run.
    public static func elevation(
        _ measurement: Measurement<UnitLength>,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard measurement.value.isFinite else { return "—" }
        return WidgetFormat.elevation(meters: measurement.converted(to: .meters).value, locale: locale)
    }

    /// The same height, in words, for a sentence that is read aloud.
    ///
    /// ``spokenDuration(_:)``'s counterpart, and there for the same reason: a
    /// speech synthesiser handed "535 m" is being asked to guess. The unit is
    /// chosen the same way, so a US reader hears "1,755 feet" where the chart
    /// draws "1,755 ft" — rather than the "535 meters at 0.4 miles" this used
    /// to say.
    public static func spokenElevation(
        _ measurement: Measurement<UnitLength>,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard measurement.value.isFinite else { return "—" }
        return WidgetFormat.elevation(
            meters: measurement.converted(to: .meters).value,
            locale: locale,
            width: .wide
        )
    }

    /// One decimal, in whatever unit the reader's region measures speed in.
    ///
    /// `usage: .general` rather than `.asProvided`, and no explicit conversion
    /// before it: `.asProvided` renders the unit it was handed, so pinning the
    /// value to km/h first pinned the *whole app* to km/h. The distance beside
    /// it has always used `usage: .road` and does adapt, which left a reader in
    /// the US looking at "3.1 mi" and "5.0 km/h" in the same grid. `.general`
    /// gives mph for `en_US` and `en_GB` and km/h for `de_DE` and `ja_JP`, from
    /// the same metres-per-second input, so the two rows finally agree.
    ///
    /// `numberFormatStyle` is kept because the unit change must not quietly
    /// become a precision change as well: without it the style rounds to whole
    /// units, and "4 km/h" cannot tell a stroll from a march.
    ///
    /// The `locale` parameter is a test seam. Region is exactly the input this
    /// is now sensitive to, and a suite that could only ask about the
    /// simulator's own region would assert whatever the machine happened to be
    /// set to — which is how a formatting bug survives a green test run.
    public static func speed(
        _ measurement: Measurement<UnitSpeed>,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard measurement.value.isFinite else { return "—" }
        return WidgetFormat.speed(
            metersPerSecond: measurement.converted(to: .metersPerSecond).value,
            locale: locale
        )
    }
}
