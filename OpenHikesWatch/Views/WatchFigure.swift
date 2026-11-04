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

import OpenHikesShared
import SwiftUI

struct WatchFigure: View {
    /// How far a value may shrink before it wraps instead.
    ///
    /// A 40 mm watch is narrow enough that "1,240 m" in two columns is
    /// already tight, and a figure that wrapped would push the caption off
    /// the tile. Shrinking is the lesser cost, and 0.6 is where the digits
    /// stop being legible at arm's length.
    private static let minimumScale = 0.6
    /// The caption, in points at the default text size. Below `.caption2` on
    /// purpose: these labels are a word or two each and are read once, while
    /// the values beside them are read on every glance. Scaled with
    /// `.caption2`, so it still grows when the value above it does, and left
    /// free to wrap rather than shrink at the largest sizes.
    @ScaledMetric(relativeTo: .caption2) private var captionSize = 10.0

    let title: Text
    let value: String
    /// What VoiceOver reads the figure by, where ``title`` is shortened to fit
    /// the tile. `nil` reads ``title``.
    var spokenTitle: Text?

    /// The caption is a key rather than a `String`, so that a caption written
    /// as a literal at the call site is extracted into the String Catalog. A
    /// `String` reached the verbatim `Text` and `accessibilityLabel`
    /// overloads, which draw it and list it nowhere (#1028).
    init(title: LocalizedStringKey, value: String, spokenTitle: LocalizedStringKey? = nil) {
        self.title = Text(title)
        self.value = value
        self.spokenTitle = spokenTitle.map { Text($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.headline.monospacedDigit())
                .minimumScaleFactor(Self.minimumScale)
                .lineLimit(1)
            title
                .font(.system(size: captionSize))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenTitle ?? title)
        .accessibilityValue(value)
    }
}

extension WatchFigure {
    /// A figure whose caption and value were decided together, in the shared
    /// package — see ``WatchRecordingFigures``.
    init(_ figure: WatchRecordingFigures.Figure) {
        self.init(title: figure.caption.label, value: figure.value, spokenTitle: figure.caption.spokenLabel)
    }

    /// A figure whose caption was looked up under a key of its own, because a
    /// translation names it apart from another use of the same English word
    /// (*One English word that a translation splits takes a second key* in
    /// the repository instructions).
    init(caption: String, value: String) {
        title = Text(verbatim: caption)
        self.value = value
    }
}
