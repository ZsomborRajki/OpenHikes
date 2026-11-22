//
//  HikeRouteEditButton.swift
//  OpenHikes
//
//  *Edit Route* on a trail drawn in the maker: reopens the maker on the stops
//  it was drawn from — see ``DrawnRoute`` and ``TrailDraftController/edit(_:)``.
//
//  Drawn only for a hike that carries a ``DrawnRoute``. A recording or an
//  import has no stops, and re-routing the whole of a line somebody walked
//  would replace it with a guess — the owner's decision. Its *Edit Route* is
//  the row below, ``HikeRouteTrimLink``, which keeps every point it is not
//  asked to change and marks what it redraws as a guess (``RouteStep``).
//
//  The maker holds one drawing at a time, so a half-drawn *other* trail is
//  asked about before it is replaced, the way the maker's own ✕ asks before a
//  drawing is thrown away. Its own view, for the reason every row in the
//  detail's closing list of actions is: the dialog's state belongs here and
//  nowhere above.
//

import OpenHikesData
import SwiftUI

struct HikeRouteEditButton: View {
    let hike: Hike
    let maker: TrailDraftController

    @State private var isConfirmingReplace = false

    var body: some View {
        Button(action: tapped) {
            PlaceCardActionLabel(title: String(localized: "Edit Route"), systemImage: "scribble.variable")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hike-edit-route")
        .confirmationDialog(
            "Replace the trail you’re drawing?",
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

/// *Edit Route* on a hike that was recorded or imported: the way to the
/// screen that cuts and changes its line — see ``RouteTrimView``. The same row and the
/// same words as the maker's, because to the hiker it is the same thing to
/// want.
struct HikeRouteTrimLink: View {
    let hike: Hike

    var body: some View {
        NavigationLink(value: SheetRoute.routeEdit(hike)) {
            PlaceCardActionLabel(title: String(localized: "Edit Route"), systemImage: "scribble.variable")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hike-edit-route")
    }
}
