//
//  DoneReorderingButton.swift
//  OpenHikes
//
//  The way out of a list's reorder mode.
//
//  The hiker's own list and the Community list each drew this for
//  themselves, word for word apart from the identifier. It matters that they
//  stay alike: while either list is reordering, a row's tap belongs to the
//  `List` rather than to what the row is about, so this is the only way out
//  and a hiker who has met it on one list should recognise it on the other.
//

import SwiftUI

struct DoneReorderingButton: View {
    let identifier: String
    let action: () -> Void

    var body: some View {
        // Not the system's `Button(role: .confirm)`, though it is the one
        // place in the app a ✓ is drawn by hand. With it — icon-only, plain
        // or not, widened or not — the drag in `HikeOrderUITests` lifts the
        // row and never moves it, on every run; this button passes.
        Button {
            withAnimation { action() }
        } label: {
            Label("Done Reordering", systemImage: "checkmark")
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                // Widened to a finger but left its own height. Grown to the
                // full `minimumTapTarget()` square it holds the bar above the
                // list at the sort menu's height through the switch into
                // reorder mode, and the drag `HikeOrderUITests` makes from a
                // row's handle then never moves the row.
                .frame(minWidth: AccessibilityMetrics.minimumTapTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityIdentifier(identifier)
    }
}
