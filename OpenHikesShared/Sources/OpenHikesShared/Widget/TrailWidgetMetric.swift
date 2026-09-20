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
import Synchronization

/// Number formatting shared by everything the widget draws, so a distance in
/// the status line cannot be rounded differently from a distance in a chip.
///
/// `public` because the app is now held to it as well: `HikeFormat.elevation`
/// has to give the same answer ``elevation(meters:locale:)`` does, and
/// `ElevationFormatTests` asserts that against this type rather than against a
/// restatement of the formula, which would only agree with itself. The app and
/// the widget drew the same summit as "1,250 m" and "4,101 ft" for exactly as
/// long as nothing could compare them.
public enum WidgetFormat {
    /// Trail-length style: locale-aware, and rounded the way a road sign
    /// rounds — "4.2 km", "2.6 mi".
    public static func length(
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
    /// both make of it. That is the whole reason this cannot simply be
    /// ``length(meters:locale:)``, and it is also why the unit has to be
    /// chosen by hand: there is no usage that means "a height".
    ///
    /// Chosen by ``prefersImperialRoadUnits(in:)`` rather than by
    /// `measurementSystem`, so the height agrees with the distance beside it
    /// in every locale rather than in most of them. See that helper for the
    /// eighteen where the two answers part company.
    public static func elevation(
        meters: Double,
        locale: Locale = .current
    ) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        let converted = prefersImperialRoadUnits(in: locale)
            ? measurement.converted(to: .feet)
            : measurement
        return Measurement(
            value: converted.value.rounded(),
            unit: converted.unit
        )
        .formatted(
            .measurement(width: .abbreviated, usage: .asProvided)
                .locale(locale)
        )
    }

    /// Elapsed-time style — "1:03:12", "12:40". Whole seconds, because this
    /// is a stopwatch rather than a measurement.
    ///
    /// Only ever the *spoken* and paused forms of a recording's clock: a
    /// running Live Activity draws `Text(timerInterval:)` instead, which the
    /// system ticks without the app spending an update on it.
    public static func duration(seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded()))
            .formatted(.time(pattern: .hourMinuteSecond))
    }

    /// Walking-pace style, to one decimal — "4.3 km/h", "2.7 mph".
    ///
    /// `usage: .general`, and no explicit conversion before it, which is what
    /// `HikeFormat.speed` was fixed to and this copy was not. Asking the
    /// locale's measurement system whether to convert is a different question
    /// from asking ICU what the region measures road speed in, and the two
    /// part company in the eighteen locales
    /// ``prefersImperialRoadUnits(in:)`` names: a hiker in Yangon read
    /// "5.0 km/h" on the recording screen and "3.1 mph" on the Lock Screen
    /// panel for the same fix.
    ///
    /// `numberFormatStyle` is kept for the reason `HikeFormat` gives: without
    /// it the style rounds to whole units, and "4 km/h" cannot tell a stroll
    /// from a march.
    public static func speed(
        metersPerSecond: Double,
        locale: Locale = .current
    ) -> String {
        Measurement(value: metersPerSecond, unit: UnitSpeed.metersPerSecond)
            .formatted(
                .measurement(
                    width: .abbreviated,
                    usage: .general,
                    numberFormatStyle: .number.precision(.fractionLength(1))
                )
                .locale(locale)
            )
    }

    /// Whether this region measures a road distance in miles.
    ///
    /// The question ``length(meters:locale:)`` asks by passing `usage: .road`,
    /// made available to the two formatters that cannot pass a usage: a height
    /// has no usage of its own, and asking `measurementSystem` instead is a
    /// *different* question that happens to agree in most places. It disagrees
    /// in eighteen of the 1,062 identifiers `Locale.availableIdentifiers`
    /// carries — Liberia is `ussystem`, Myanmar is `uksystem`, and both sign
    /// their roads in kilometres — which is how the app drew "5 km" beside
    /// "4,101 ft" in one stat grid for a reader there.
    ///
    /// Asked by formatting rather than read from a table, because Foundation
    /// exposes no answer and a checked-in table would be a copy of CLDR that
    /// stops matching it. A reference distance is formatted twice, once by
    /// road usage and once forced to kilometres, and the answer is whether the
    /// two disagree. Comparing rendered strings rather than looking for "mi"
    /// is what makes it right in Scottish Gaelic, which abbreviates the mile
    /// `mì`, and in Lakota, which spells both units as words.
    ///
    /// Memoised because it is five times the cost of the formatting it
    /// decides — 4.9 µs against 1.0 µs, measured over 10,000 calls — and the
    /// answer is a property of the locale that cannot change while the process
    /// lives. The map is bounded by the number of distinct identifiers asked
    /// about, which is one on a device and the whole list only in the suites
    /// that sweep it.
    public static func prefersImperialRoadUnits(in locale: Locale) -> Bool {
        let identifier = locale.identifier
        if let known = roadUnits.withLock({ $0[identifier] }) { return known }
        let answer = measureRoadUnits(in: locale)
        roadUnits.withLock { $0[identifier] = answer }
        return answer
    }

    private static let roadUnits = Mutex<[String: Bool]>([:])

    /// Five kilometres: far enough above the metre-to-kilometre threshold that
    /// no locale renders it in the smaller unit, so the only difference the
    /// comparison can find is the one being asked about.
    private static let roadProbeMeters: Double = 5000
    private static let roadProbe = Measurement(
        value: roadProbeMeters,
        unit: UnitLength.meters
    )

    private static func measureRoadUnits(in locale: Locale) -> Bool {
        // Whole units on both sides, so a rounding difference between the two
        // usages cannot be mistaken for a unit difference.
        let digits = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(0))
            .grouping(.never)
        let road = roadProbe.formatted(
            .measurement(width: .abbreviated, usage: .road, numberFormatStyle: digits)
                .locale(locale)
        )
        let metric = roadProbe.converted(to: .kilometers).formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: digits)
                .locale(locale)
        )
        return road != metric
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
        case remaining = "remaining"
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
        case .remaining: "flag.pattern.checkered"
        }
    }

    /// What the glyph means, spelled out for VoiceOver.
    public var spokenLabel: String {
        switch kind {
        case .ascent: "Ascent"
        case .currentElevation: "Elevation"
        case .pace: "Average speed"
        case .points: "Track points"
        case .remaining: "Remaining"
        }
    }

    public var accessibilityPhrase: String { "\(spokenLabel) \(value)" }
}

/// The one place each chip is built.
///
/// Every surface that draws these — the widget's trail and recording bands,
/// and both halves of the Live Activity — comes through here, so a figure
/// cannot be rounded one way on a home screen and another on a Lock Screen.
/// Each returns `nil` for a figure there is nothing to say about, which is
/// what implements the "omit the chip rather than draw a dash" rule the
/// builders below rely on.
extension TrailWidgetMetric {
    /// Absent for a route with no elevations, and for a flat one: "Ascent 0 m"
    /// is a chip's width spent saying nothing.
    static func ascent(meters: Double?, locale: Locale) -> Self? {
        guard let meters, meters > 0 else { return nil }
        return Self(
            kind: .ascent,
            value: WidgetFormat.elevation(meters: meters, locale: locale)
        )
    }

    /// Sea level is a real height, so this one is absent only when there is no
    /// live fix to read a height from.
    static func currentElevation(meters: Double?, locale: Locale) -> Self? {
        guard let meters else { return nil }
        return Self(
            kind: .currentElevation,
            value: WidgetFormat.elevation(meters: meters, locale: locale)
        )
    }

    /// Absent while standing still: a pace of zero is what every recording
    /// reads before its second fix, and it is not a fact about the walk.
    static func pace(metersPerSecond: Double?, locale: Locale) -> Self? {
        guard let metersPerSecond, metersPerSecond > 0 else { return nil }
        return Self(
            kind: .pace,
            value: WidgetFormat.speed(
                metersPerSecond: metersPerSecond,
                locale: locale
            )
        )
    }

    /// Absent before the first fix lands, when "0 pts" would read as a broken
    /// recording rather than as one that has just started.
    static func points(_ count: Int?, locale: Locale) -> Self? {
        guard let count, count > 0 else { return nil }
        return Self(
            kind: .points,
            value: count.formatted(.number.locale(locale))
        )
    }
}

extension TrailWidgetMetric {
    /// The chips a snapshot offers, in order, cut to what the family has room
    /// for.
    ///
    /// Both snapshots build their band this way and the rule is the same for
    /// each: a figure that is missing is **omitted** rather than drawn as a
    /// dash, so a route imported without elevations shows fewer chips instead
    /// of a row of placeholders. That is what makes `nil` the right thing for
    /// each factory to return, and what makes the order of `candidates` the
    /// whole of the priority — the cut happens after the compact, so a
    /// missing first chip promotes the second rather than costing the slot.
    ///
    /// - Parameter candidates: Most useful first.
    static func band(_ candidates: [TrailWidgetMetric?], limit: Int) -> [TrailWidgetMetric] {
        guard limit > 0 else { return [] }
        return Array(candidates.compactMap(\.self).prefix(limit))
    }

    /// The same chips as one phrase, for a widget's single accessibility
    /// element — the glyphs themselves say nothing to VoiceOver.
    static func accessibilityText(for metrics: [TrailWidgetMetric]) -> String {
        metrics.map(\.accessibilityPhrase).joined(separator: ", ")
    }
}

extension SharedTrailSnapshot: TrailWidgetMetricSource {}
extension SharedRecordingSnapshot: TrailWidgetMetricSource {}

/// Something a widget can draw a band of stat chips for.
///
/// Two snapshots answer this and they answer it differently — a trail's
/// chips are ascent and where the hiker is, a recording's are ascent and
/// pace. What they do not differ about is turning whichever chips came back
/// into the one phrase a widget speaks, so that lives here: a widget is a
/// single accessibility element, the glyphs say nothing to VoiceOver, and a
/// second spelling of the joining would be a widget that reads differently
/// depending on what it happens to be showing.
public protocol TrailWidgetMetricSource {
    /// This snapshot's chips, most useful first, truncated to whatever the
    /// widget family has width for.
    func metrics(limit: Int, locale: Locale) -> [TrailWidgetMetric]
}

public extension TrailWidgetMetricSource {
    /// The same chips as one phrase, for the widget's single accessibility
    /// element.
    func metricsAccessibilityText(limit: Int, locale: Locale = .current) -> String {
        TrailWidgetMetric.accessibilityText(for: metrics(limit: limit, locale: locale))
    }
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
    /// The hiker's own elevation joins it only while there is a live fix to
    /// read it from — on the trail, "where am I" is worth the second slot; off
    /// it, there is nothing to put there.
    ///
    /// A missing figure is omitted rather than drawn as a dash: a route
    /// imported without elevations should show fewer chips, not a row of
    /// placeholders.
    func metrics(limit: Int, locale: Locale = .current) -> [TrailWidgetMetric] {
        TrailWidgetMetric.band(
            [
                TrailWidgetMetric.ascent(
                    meters: elevationGainMeters,
                    locale: locale
                ),
                TrailWidgetMetric.currentElevation(
                    meters: liveFix?.elevationMeters,
                    locale: locale
                ),
            ],
            limit: limit
        )
    }

}

public extension SharedRecordingSnapshot {
    /// The stat chips for a recording in progress, most useful first.
    ///
    /// Distance and point count are already on the status line beside them, so
    /// these are the two facts a live recording otherwise doesn't show: how
    /// much has been climbed, and how fast it is being walked.
    func metrics(limit: Int, locale: Locale = .current) -> [TrailWidgetMetric] {
        TrailWidgetMetric.band(
            [
                TrailWidgetMetric.ascent(
                    meters: elevationGainMeters,
                    locale: locale
                ),
                TrailWidgetMetric.pace(
                    metersPerSecond: averageSpeedMetersPerSecond,
                    locale: locale
                ),
            ],
            limit: limit
        )
    }

}
