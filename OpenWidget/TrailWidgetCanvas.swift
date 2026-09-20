//
//  TrailWidgetCanvas.swift
//  OpenWidget
//
//  The surface both widget states are drawn on.
//
//  A trail and a recording in progress share a shape: text over a map that is
//  the widget's *background* rather than a subview, on a plain fill that shows
//  through until the first render lands, read as one element because the whole
//  widget is one tap target.
//
//  Each half of that has a reason, and each was written out twice.
//
//  **The map is a container background**, so it runs edge to edge under the
//  text and the system rounds it to the widget's own corner radius. It also
//  means the system can drop it wherever container backgrounds do not belong —
//  StandBy, a tinted Home Screen — and the text still stands on its own.
//
//  **The plain fill is underneath it**, because a snapshot that has not
//  rendered yet, or never will, leaves the fallback glyph needing something
//  behind it.
//
//  **One accessibility element**, because a widget is one tap target: the
//  trail's name is spoken on every family even though none of them draw it any
//  more, and for a recording it is the only place the paused state is put into
//  words.
//

import SwiftUI
import WidgetKit

extension View {
    /// Puts this text on the widget's canvas and reads the result as one
    /// thing.
    ///
    /// - Parameters:
    ///   - label: Spoken first. The trail's name in both states.
    ///   - value: Spoken after it — the status line and the stat chips, which
    ///     is where the two states genuinely differ.
    ///   - background: What goes on the plain fill. The map, and for a trail
    ///     with a rendered basemap the scrim over it.
    func trailWidgetCanvas(
        padding: CGFloat,
        label: String,
        value: String,
        @ViewBuilder background: () -> some View
    ) -> some View {
        self
            .padding(padding)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .containerBackground(for: .widget) {
                ZStack {
                    Rectangle().fill(.fill.tertiary)
                    background()
                }
            }
    }
}
