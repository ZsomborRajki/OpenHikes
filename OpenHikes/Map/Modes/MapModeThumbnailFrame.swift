//
//  MapModeThumbnailFrame.swift
//  OpenHikes
//
//  The frame every picture on *Map Modes* stands in: rounded, with a hairline
//  round it and the accent ring when it is the one chosen. The map cards and
//  the *Hiking Routes* pair share it, so the two rows read as one sheet of
//  choices rather than two designs.
//

import SwiftUI

struct MapModeThumbnailFrame: ViewModifier {
    let isSelected: Bool

    /// A picture's side at the default text size. Each card scales it with
    /// Dynamic Type itself, so the name under it never outgrows the card.
    static let side: CGFloat = 84

    private static let cornerRadius: CGFloat = 12
    private static let ringWidth: CGFloat = 3
    /// Between the picture and the ring, so selection never moves the picture.
    private static let ringGap: CGFloat = 2
    /// A hairline round every picture, so a pale map does not bleed into the
    /// sheet behind it.
    private static let edgeOpacity: Double = 0.12
    private static let edgeWidth: CGFloat = 0.5

    /// How wide a card is around a picture of `side`, ring included.
    static func width(around side: CGFloat) -> CGFloat {
        side + 2 * (ringWidth + ringGap)
    }

    func body(content: Content) -> some View {
        content
            .clipShape(.rect(cornerRadius: Self.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(.primary.opacity(Self.edgeOpacity), lineWidth: Self.edgeWidth)
            }
            .padding(Self.ringWidth + Self.ringGap)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Self.cornerRadius + Self.ringWidth + Self.ringGap)
                        .strokeBorder(Color.accentColor, lineWidth: Self.ringWidth)
                }
            }
    }
}
