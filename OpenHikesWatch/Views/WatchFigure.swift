//
//  WatchFigure.swift
//  OpenHikesWatch
//
//  One labelled number, which is most of what this app draws.
//
//  One accessibility element rather than two, which is the rule the app's
//  `StatFigure` and `StatRow` follow: a figure read out as a caption and then a
//  value is two swipes to hear one figure.
//

import SwiftUI

struct WatchFigure: View {
    /// How far a value may shrink before it wraps instead.
    ///
    /// A 40 mm watch is narrow enough that "1,240 m" in two columns is
    /// already tight, and a figure that wrapped would push the caption off
    /// the tile. Shrinking is the lesser cost, and 0.6 is where the digits
    /// stop being legible at arm's length.
    private static let minimumScale = 0.6
    /// The caption, in points. Below `.caption2` on purpose: these labels are
    /// one word each and are read once, while the values beside them are read
    /// on every glance.
    private static let captionSize = 10.0

    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.headline.monospacedDigit())
                .minimumScaleFactor(Self.minimumScale)
                .lineLimit(1)
            Text(title)
                .font(.system(size: Self.captionSize))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}
