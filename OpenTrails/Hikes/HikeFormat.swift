//
//  HikeFormat.swift
//  OpenTrails
//
//  Formatting helpers for hike stats (duration, length, speed).
//

import Foundation

nonisolated enum HikeFormat {
    static func duration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: interval) ?? "—"
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
