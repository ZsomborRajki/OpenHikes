//
//  HikeFormat.swift
//  OpenHikes
//
//  Formatting helpers for hike stats (duration, length, speed).
//

import Foundation

nonisolated enum HikeFormat {
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

    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "—" }
        let duration = Duration.seconds(interval)
        return interval >= 3600
            ? duration.formatted(longStyle)
            : duration.formatted(shortStyle)
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

    static func timestamp(_ date: Date) -> String {
        date.formatted(timestampStyle)
    }

    static func timeOfDay(_ date: Date) -> String {
        date.formatted(timeOfDayStyle)
    }

    /// Whole units, in the unit it was handed — and a dash for a figure that
    /// isn't a number.
    ///
    /// The same answer ``duration(_:)`` gives, for the same reason: an
    /// elevation total derived from a route carrying a non-finite height
    /// formats as "∞ m" or "NaN m", and both read on a stat tile as though
    /// something had been measured.
    static func length(_ measurement: Measurement<UnitLength>) -> String {
        guard measurement.value.isFinite else { return "—" }
        let rounded = Measurement(value: measurement.value.rounded(), unit: measurement.unit)
        return rounded.formatted(.measurement(width: .abbreviated, usage: .asProvided))
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
    static func speed(
        _ measurement: Measurement<UnitSpeed>,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard measurement.value.isFinite else { return "—" }
        return measurement.formatted(
            .measurement(
                width: .abbreviated,
                usage: .general,
                numberFormatStyle: .number.precision(.fractionLength(1))
            )
            .locale(locale)
        )
    }
}
