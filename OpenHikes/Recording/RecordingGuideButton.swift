//
//  RecordingGuideButton.swift
//  OpenHikes
//
//  *Show While Recording*, on a trail's own screen.
//
//  In the bar's trailing place, the one ``WalkToggleButton`` takes when no
//  recording is under way. A hiker walks or records, never both, so during a
//  recording that button draws nothing, and its place is the one still on
//  screen at the sheet's smallest detent. This goes there instead: it shows
//  the trail under the recording, then opens the recording screen, where the
//  hiker sees the trail under their own track. Once the trail is shown, the
//  same place stops showing it.
//
//  Reads only which trail is shown and which recording is under way, and is
//  its own view rather than a `.toolbar` closure's contents, for the reason
//  ``WalkToggleButton`` is. See ``RecordingGuide``.
//

import OpenHikesData
import SwiftUI

struct RecordingGuideButton: View {
    /// The glyph a route is drawn with everywhere this app has one to draw.
    static let symbolName = "point.topleft.down.to.point.bottomright.curvepath"

    let hike: Hike
    /// `nil` draws nothing — a screen built without a guide.
    let guide: RecordingGuide?

    var body: some View {
        Group {
            if let guide, guide.isShowing(hike.id) {
                Button("Stop Showing While Recording", systemImage: "eye.slash") {
                    guide.stopShowing()
                }
                .accessibilityIdentifier("recording-guide-toggle")
            } else if let guide, guide.canShow(hike) {
                Button("Show While Recording", systemImage: Self.symbolName) {
                    guide.show(hike)
                    guide.openRecording()
                }
                // Tinted glass, as Start Hike is in this place.
                .prominentGlassButtonStyle()
                .accessibilityIdentifier("recording-guide-toggle")
            }
        }
        .tint(hike.tintOpaque)
    }
}
