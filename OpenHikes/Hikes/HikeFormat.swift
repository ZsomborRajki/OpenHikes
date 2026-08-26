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

    static func length(_ measurement: Measurement<UnitLength>) -> String {
        let rounded = Measurement(value: measurement.value.rounded(), unit: measurement.unit)
        return rounded.formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }

    static func speed(_ measurement: Measurement<UnitSpeed>) -> String {
        measurement.converted(to: .kilometersPerHour)
            .formatted(
                .measurement(
                    width: .abbreviated,
                    usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(1))
                )
            )
    }
}
