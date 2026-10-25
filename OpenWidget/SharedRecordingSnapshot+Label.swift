// The widget’s recording captions are resolved in its own bundle.

import Foundation
import OpenHikesShared

nonisolated extension SharedRecordingSnapshot {
    var title: String {
        isCapturingFixes ? String(localized: "Recording Hike") : String(localized: "Recording Paused")
    }

    var statusText: String {
        "\(WidgetFormat.length(meters: distanceMeters)) · \(pointCountText)"
    }

    /// The half of ``statusText`` the Home Screen widget's chips do not
    /// already say.
    ///
    /// The distance is a chip there now — "Hiked 1.4 km" — so an
    /// accessibility value built from ``statusText`` would read "1.4 km · 320
    /// pts, Ascent 180 m, Hiked 1.4 km". The Lock Screen families draw
    /// ``statusText`` and no chips, so they keep both figures. See
    /// ``TrailWidgetSpeech`` in the widget target.
    var pointCountText: String {
        String(localized: "\(pointCount) pts")
    }
}
