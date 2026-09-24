//
//  HikeRouteEditButton.swift
//  OpenHikes
//
//  *Edit Route* on a trail drawn in the maker: reopens the maker on the stops
//  it was drawn from — see ``DrawnRoute`` and ``TrailDraftController/edit(_:)``.
//
//  Drawn only for a hike that carries a ``DrawnRoute``. A recording or an
//  import has no stops, and re-routing a line somebody walked would replace
//  it with a guess — the owner's decision.
//
//  The maker holds one drawing at a time, so a half-drawn *other* trail is
//  asked about before it is replaced, the way the maker's own ✕ asks before a
//  drawing is thrown away. Its own view, for the reason every glyph on the
//  header row is: the dialog's state belongs here and nowhere above.
//

import SwiftUI

struct HikeRouteEditButton: View {
    let hike: Hike
    let maker: TrailDraftController

    @State private var isConfirmingReplace = false

    var body: some View {
        Button(action: tapped) {
            Image(systemName: "scribble.variable")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .minimumTapTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit Route")
        .accessibilityIdentifier("hike-edit-route")
        .confirmationDialog(
            "Replace the trail you're drawing?",
            isPresented: $isConfirmingReplace,
            titleVisibility: .visible
        ) {
            Button("Replace Drawing", role: .destructive) { maker.edit(hike) }
            Button("Cancel", role: .cancel) { /* the drawing stays */ }
        } message: {
            Text("The maker holds one trail at a time, and the one you left half-drawn will be discarded.")
        }
    }

    private func tapped() {
        let isOtherDrawing = !maker.draft.isEmpty && maker.editingHikeID != hike.id
        if isOtherDrawing {
            isConfirmingReplace = true
        } else {
            maker.edit(hike)
        }
    }
}
