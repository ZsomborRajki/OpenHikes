//
//  RecordingGuideRow.swift
//  OpenHikes
//
//  The trail shown under the recording, named on the recording screen.
//
//  The map draws the line and says nothing about whose it is, and a line with
//  no name and no way to remove it is one the hiker has to leave the recording
//  to understand. So the recording card names it, above the figures and in
//  the trail's own colour, with Stop Showing beside it. Nothing at all while
//  no trail is shown.
//
//  Its own view, so the card's body reads nothing of the guide.
//  See ``RecordingGuide``.
//

import SwiftUI

struct RecordingGuideRow: View {
    let guide: RecordingGuide

    var body: some View {
        if let trail = guide.shown {
            HStack(spacing: 12) {
                Image(systemName: RecordingGuideButton.symbolName)
                    .foregroundStyle(Color(hex: trail.tintHex)?.opaque ?? RouteStyle.defaultTint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trail on the Map")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(trail.title)
                        .font(.subheadline)
                }
                // One element, the name as its value, as a stat row is.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Trail on the Map")
                .accessibilityValue(trail.title)
                .accessibilityIdentifier("recording-guide")
                Spacer(minLength: 0)
                Button("Stop Showing") {
                    guide.stopShowing()
                }
                .glassButtonStyle()
                .accessibilityIdentifier("recording-guide-stop")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
