//
//  ClearFieldButton.swift
//  OpenHikes
//
//  The ✕ at the end of a search field that empties it: the map sheet's, and
//  *Offline Maps*'.
//
//  Its glyph is a line of text high, seventeen points at the default size,
//  and a finger needs the floor ``minimumTapTarget(_:)`` sets, which the
//  accessibility audit's hit-region check holds a control to. But the field
//  is a capsule a line of text and its padding high, and a target of the full
//  size in its row made the field taller the moment it held a character. So
//  the glyph keeps its own room in the row, drawing nothing there, and the
//  button is laid over that room at the full size, centred on it: the target
//  reaches past the glyph into the field's padding and the gap before it, and
//  the field keeps its height.
//
//  The glyph is the button's only content and is hidden, so the button says
//  what it does; unnamed, it announced itself as an unnamed button.
//

import SwiftUI

struct ClearFieldButton: View {
    let identifier: String
    let action: () -> Void

    private static let symbol = "xmark.circle.fill"

    var body: some View {
        Image(systemName: Self.symbol)
            .hidden()
            .accessibilityHidden(true)
            .overlay {
                Button(action: action) {
                    Image(systemName: Self.symbol)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                        .minimumTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier(identifier)
            }
    }
}
