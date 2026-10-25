// Words are resolved by the target whose catalog the widget bundles.

import Foundation
import OpenHikesShared

nonisolated extension TrailWidgetMetric {
    /// What the glyph means, spelled out for VoiceOver.
    var spokenLabel: String {
        switch kind {
        case .ascent: String(localized: "Ascent")
        case .averageSpeed: String(localized: "Average speed")
        case .currentElevation: String(localized: "Elevation")
        case .distance: String(localized: "Hiked")
        case .length: String(localized: "Length")
        case .points: String(localized: "Track points")
        case .remaining: String(localized: "Remaining")
        case .timeLeft: String(localized: "Time left")
        }
    }

    var accessibilityPhrase: String { "\(spokenLabel) \(value)" }
    /// The same chips as one phrase, for a widget's single accessibility
    /// element — the glyphs themselves say nothing to VoiceOver.
    static func accessibilityText(for metrics: [TrailWidgetMetric]) -> String {
        metrics.map(\.accessibilityPhrase).joined(separator: ", ")
    }
}

nonisolated extension TrailWidgetMetricSource {
    /// The same chips as one phrase, for the widget's single accessibility
    /// element.
    func metricsAccessibilityText(limit: Int, locale: Locale = .current) -> String {
        TrailWidgetMetric.accessibilityText(for: metrics(limit: limit, locale: locale))
    }
}
