//
//  TrailWidgetMetric.swift
//  OpenHikesShared
//
//  The small stat chips the iOS widget draws in the band beneath its map, and
//  the number formatting they share with the status line above them.
//
//  They live here rather than in the widget target for the same reason
//  `statusText` does: the app computes the numbers and the extension renders
//  them, so the wording, the rounding, and the decision about which stat is
//  worth the width have to be made once, in one place.
//

import Foundation

/// Number formatting shared by everything the widget draws, so a distance in
/// the status line cannot be rounded differently from a distance in a chip.
enum WidgetFormat {
    /// Trail-length style: locale-aware, and rounded the way a road sign
    /// rounds — "4.2 km", "2.6 mi".
    static func length(
        meters: Double,
        locale: Locale = .current
    ) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(
                .measurement(width: .abbreviated, usage: .road)
                    .locale(locale)
            )
    }

    /// Elevation style: whole metres, or whole feet where that is the local
    /// unit, and never promoted to kilometres — a 1,250 m summit is 1,250 m
    /// high, not "1.2 km" high, which is what `.road` and `.general` would
    /// both make of it.
    static func elevation(
        meters: Double,
        locale: Locale = .current
    ) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        let converted = locale.measurementSystem == .metric
            ? measurement
            : measurement.converted(to: .feet)
        return Measurement(
            value: converted.value.rounded(),
            unit: converted.unit
        )
        .formatted(
            .measurement(width: .abbreviated, usage: .asProvided)
                .locale(locale)
        )
    }

    /// Walking-pace style, to one decimal — "4.3 km/h", "2.7 mph".
    ///
    /// `UnitSpeed` has no locale-aware usage of its own, so the unit is
    /// chosen from the locale's measurement system the way the length
    /// formatter's `.road` usage does it for distances.
    static func speed(
        metersPerSecond: Double,
        locale: Locale = .current
    ) -> String {
        let measurement = Measurement(
            value: metersPerSecond,
            unit: UnitSpeed.metersPerSecond
        )
        let converted = locale.measurementSystem == .metric
            ? measurement.converted(to: .kilometersPerHour)
            : measurement.converted(to: .milesPerHour)
        return converted.formatted(
            .measurement(
                width: .abbreviated,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(1))
            )
            .locale(locale)
        )
    }
}

/// One labelled number the trail widget draws over its map.
///
/// Deliberately pre-formatted rather than carrying a raw quantity: a widget's
/// view tree is rendered to a static snapshot, so there is no later pass in
/// which a `Text` could reformat itself, and building the entry is the moment
/// at which the right locale is in force.
public struct TrailWidgetMetric: Sendable, Equatable, Identifiable {
    /// What the number is.
    ///
    /// Cases are alphabetical because the linter asks for that; the order the
    /// chips are actually *drawn* in is decided by the builders below, and is
    /// most-useful-first so that truncating for a narrow family drops the
    /// least useful one.
    public enum Kind: String, Sendable, CaseIterable {
        case ascent = "ascent"
        case currentElevation = "currentElevation"
        case pace = "pace"
        case points = "points"
    }

    public let kind: Kind
    /// Already formatted for the locale in force when this was built.
    public let value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    public var id: String { kind.rawValue }

    /// The SF Symbol drawn beside ``value``. Purely decorative: the widget is
    /// a single accessibility element and speaks ``accessibilityPhrase``
    /// instead of the glyph.
    public var symbolName: String {
        switch kind {
        case .ascent: "arrow.up.forward"
        case .currentElevation: "figure.hiking"
        case .pace: "speedometer"
        case .points: "point.3.connected.trianglepath.dotted"
        }
    }

    /// What the glyph means, spelled out for VoiceOver.
    public var spokenLabel: String {
        switch kind {
        case .ascent: "Ascent"
        case .currentElevation: "Elevation"
        case .pace: "Average speed"
        case .points: "Track points"
        }
    }

    public var accessibilityPhrase: String { "\(spokenLabel) \(value)" }
}

public extension SharedTrailSnapshot {
    /// The stat chips for this trail: at most two, most useful first, and
    /// truncated to whatever the widget family has width for.
    ///
    /// A widget is a glance, not a report, so the band under the map carries
    /// one fact about height rather than four. Ascent is that fact — it is
    /// what separates a stroll from a climb, and the one thing the map behind
    /// it cannot draw. The high point and the descent were dropped for saying
    /// nearly the same thing twice over: on a loop the descent *is* the
    /// ascent, and a summit height is a number to read in the app rather than
    /// to glance at on a home screen.
    ///
    /// The walker's own elevation joins it only while there is a live fix to
    /// read it from — on the trail, "where am I" is worth the second slot; off
    /// it, there is nothing to put there.
    ///
    /// A missing figure is omitted rather than drawn as a dash: a route
    /// imported without elevations should show fewer chips, not a row of
    /// placeholders.
    func metrics(limit: Int, locale: Locale = .current) -> [TrailWidgetMetric] {
        guard limit > 0 else { return [] }
        var metrics: [TrailWidgetMetric] = []
        if let elevationGainMeters, elevationGainMeters > 0 {
            metrics.append(
                TrailWidgetMetric(
                    kind: .ascent,
                    value: WidgetFormat.elevation(
                        meters: elevationGainMeters,
                        locale: locale
                    )
                )
            )
        }
        if let elevation = liveFix?.elevationMeters {
            metrics.append(
                TrailWidgetMetric(
                    kind: .currentElevation,
                    value: WidgetFormat.elevation(
                        meters: elevation,
                        locale: locale
                    )
                )
            )
        }
        return Array(metrics.prefix(limit))
    }

    /// The same chips as one phrase, for the widget's single accessibility
    /// element — the glyphs themselves say nothing to VoiceOver.
    func metricsAccessibilityText(
        limit: Int,
        locale: Locale = .current
    ) -> String {
        metrics(limit: limit, locale: locale)
            .map(\.accessibilityPhrase)
            .joined(separator: ", ")
    }
}

public extension SharedRecordingSnapshot {
    /// The stat chips for a recording in progress, most useful first.
    ///
    /// Distance and point count are already on the status line beside them, so
    /// these are the two facts a live recording otherwise doesn't show: how
    /// much has been climbed, and how fast it is being walked.
    func metrics(limit: Int, locale: Locale = .current) -> [TrailWidgetMetric] {
        guard limit > 0 else { return [] }
        var metrics: [TrailWidgetMetric] = []
        if let elevationGainMeters, elevationGainMeters > 0 {
            metrics.append(
                TrailWidgetMetric(
                    kind: .ascent,
                    value: WidgetFormat.elevation(
                        meters: elevationGainMeters,
                        locale: locale
                    )
                )
            )
        }
        if let averageSpeedMetersPerSecond, averageSpeedMetersPerSecond > 0 {
            metrics.append(
                TrailWidgetMetric(
                    kind: .pace,
                    value: WidgetFormat.speed(
                        metersPerSecond: averageSpeedMetersPerSecond,
                        locale: locale
                    )
                )
            )
        }
        return Array(metrics.prefix(limit))
    }

    /// The same chips as one phrase — see
    /// ``SharedTrailSnapshot/metricsAccessibilityText(limit:locale:)``.
    func metricsAccessibilityText(
        limit: Int,
        locale: Locale = .current
    ) -> String {
        metrics(limit: limit, locale: locale)
            .map(\.accessibilityPhrase)
            .joined(separator: ", ")
    }
}
