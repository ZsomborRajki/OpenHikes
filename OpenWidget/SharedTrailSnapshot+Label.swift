// The widget’s sentences are extracted into its own catalog.

import Foundation
import OpenHikesShared

nonisolated extension SharedTrailSnapshot {
    /// "62% · 1.4 mi left" while a live fix is on the trail, otherwise just
    /// the trail's total length. Shared with the iOS widget so the app and
    /// extension cannot drift out of sync.
    ///
    /// During a walk the percentage is coverage and the caption says
    /// *hiked*, so the return-leg case reads "50% hiked · 0.2 km left"
    /// rather than a contradiction. A paused walk says so first, because on a
    /// widget that is the one word that changes what the number means.
    var statusText: String {
        progressStatusText ?? WidgetFormat.length(meters: totalDistanceMeters)
    }

    /// The half of ``statusText`` that says where the walk stands, and `nil`
    /// when there is no walk to stand anywhere in it.
    ///
    /// Split out for the Home Screen widget's single accessibility element.
    /// There the trail's length is drawn as a chip of its own, so a spoken
    /// value built from ``statusText`` would say the same figure twice — "2.6
    /// km, Ascent 420 m, Length 2.6 km" — for the state a placed widget is in
    /// most of the time. The Lock Screen families still draw ``statusText``
    /// and still want the fallback, which is why it stays there rather than
    /// moving here. See ``TrailWidgetSpeech`` in the widget target.
    var progressStatusText: String? {
        if let walk {
            let covered = String(localized: "\(Self.percent(walk.coveredFraction))% hiked")
            let prefix = walk.state == .paused ? String(localized: "Paused · ") : ""
            guard let remainingDistanceMeters else { return prefix + covered }
            let remaining = WidgetFormat.length(meters: remainingDistanceMeters)
            return String(localized: "\(prefix)\(covered) · \(remaining) left")
        }
        guard let fractionComplete, let remainingDistanceMeters else { return nil }
        let remaining = WidgetFormat.length(meters: remainingDistanceMeters)
        return String(localized: "\(Self.percent(fractionComplete))% · \(remaining) left")
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }
}
