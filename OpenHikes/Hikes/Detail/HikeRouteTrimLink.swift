//
//  HikeRouteTrimLink.swift
//  OpenHikes
//
//  *Edit Route* on a hike's screen: the way to the screen that cuts and
//  changes its line — see ``RouteTrimView``.
//
//  The same row on every hike, recorded, imported or drawn in the maker,
//  because they are the same thing by the time they are saved: a line, with
//  walks on it. A drawn trail keeps nothing of how it was drawn, so there are
//  no stops to reopen — see ``TrailDraftSave`` — and its line is edited where
//  it lies, keeping every point the hiker does not ask to change
//  (``RouteStep``).
//

import OpenHikesData
import SwiftUI

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
