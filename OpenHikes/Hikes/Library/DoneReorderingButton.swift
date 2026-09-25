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
        Button {
            withAnimation { action() }
        } label: {
            Label("Done Reordering", systemImage: "checkmark")
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityIdentifier(identifier)
    }
}
