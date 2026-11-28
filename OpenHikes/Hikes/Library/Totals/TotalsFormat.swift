//
//  TotalsFormat.swift
//  OpenHikes
//
//  How *Totals* spells its figures, each the way the rest of the app spells
//  the same one: a distance as the detail screen writes one, a height
//  through ``HikeFormat/elevation(_:locale:)``, and the chart's axis in the
//  unit the reader's roads are signed in.
//
//  `locale` is `LibraryTotalsUnitTests`' seam, as it is on `HikeFormat`.
//

import Foundation
import OpenHikesData
import OpenHikesShared

nonisolated enum TotalsFormat {
    /// A distance walked.
    ///
    /// Nothing walked is written in the chart's unit, "0 km", and not in the
    /// "0 m" a road sign's rule makes of it: a month with no hike in it is
    /// read off the chart, whose axis starts at that same "0 km".
    static func distance(_ meters: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard meters != 0 else {
            return axisDistance(0, in: chartUnit(in: locale), locale: locale)
        }
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road).locale(locale))
    }

    static func height(_ meters: Double) -> String {
        HikeFormat.elevation(Measurement(value: meters, unit: UnitLength.meters))
    }

    /// Miles where ``distance(_:locale:)`` writes miles, and kilometres
    /// everywhere else: ``WidgetFormat/prefersImperialRoadUnits(in:)`` is the
    /// question the tiles ask by passing `usage: .road`. This asked
    /// `measurementSystem` instead, a different question that happens to
    /// agree in most places. Liberia is `ussystem` and Myanmar `uksystem`,
    /// both sign their roads in kilometres, and both drew "5 km" tiles above
    /// a chart in miles (#1368).
    static func chartUnit(in locale: Locale = .autoupdatingCurrent) -> UnitLength {
        WidgetFormat.prefersImperialRoadUnits(in: locale) ? .miles : .kilometers
    }

    /// A value on the chart's axis, with its unit: "50 km". The axis has no
    /// title of its own, so every line of it says what it counts.
    static func axisDistance(
        _ value: Double,
        in unit: UnitLength,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        Measurement(value: value, unit: unit)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number).locale(locale))
    }

    /// `meters` as the chart plots it.
    static func chartValue(_ meters: Double, in unit: UnitLength) -> Double {
        Measurement(value: meters, unit: UnitLength.meters).converted(to: unit).value
    }
}

/// A figure as it is drawn and as it is read aloud, which differ only for a
/// duration: "225h 45m" is shorthand VoiceOver misreads, so it is spoken in
/// words (``HikeFormat/spokenDuration(_:)``).
nonisolated struct TotalsReading: Equatable, Sendable {
    let drawn: String
    let spoken: String

    static func distance(_ meters: Double) -> Self {
        let text = TotalsFormat.distance(meters)
        return Self(drawn: text, spoken: text)
    }

    static func height(_ meters: Double) -> Self {
        let text = TotalsFormat.height(meters)
        return Self(drawn: text, spoken: text)
    }

    static func duration(_ seconds: TimeInterval) -> Self {
        Self(drawn: HikeFormat.duration(seconds), spoken: HikeFormat.spokenDuration(seconds))
    }

    static func count(_ count: Int) -> Self {
        let text = count.formatted()
        return Self(drawn: text, spoken: text)
    }
}
