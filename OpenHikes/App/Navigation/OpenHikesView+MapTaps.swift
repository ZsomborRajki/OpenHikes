//
//  OpenHikesView+MapTaps.swift
//  OpenHikes
//
//  Where a tap on something MapKit drew ends up.
//
//  A pin and a line are drawn by MapKit, and what they open is a push into a
//  navigation stack the map cannot see. This view owns that stack and is never
//  taken down, so it claims both once and the map calls back — the same
//  arrangement ``PhotoMapPinController`` takes its `onOpen` from, for the same
//  reason.
//
//  Here rather than inline in `onAppear` because a `.onAppear` closure is
//  inlined into the body that declares it, so anything read inside one is an
//  input of *that* body — see the render-isolation rules. Nothing below reads
//  an observable, but the file it came out of is at its length limit and this
//  is the shape that keeps a later line from being written in the one place
//  where reading `selectedHike` would cost the whole map screen a render.
//

import OpenHikesData
import SwiftUI

extension OpenHikesView {
    /// Points the map's pins and lines at the sheet's navigation stack.
    ///
    /// Called once, from the map's `onAppear`.
    ///
    /// Everything these closures reach is **captured rather than read off
    /// `self`**, because they outlive every copy of this struct: the sheet's
    /// presentation and the model context, both references to something that
    /// outlives the view anyway, and the selection's own projection — whose
    /// storage does too, for the reason ``MapSheetHikes``'s `==` gives for the
    /// closures it excludes.
    func claimMapTaps() {
        appModel.community.onOpenListing { [sheet, selection = $selectedHike, context = modelContext] listing in
            sheet.open(
                listing,
                // Fetched here, where the sheet's rows read it off the
                // `@Query` they are already drawn from: a pin is one tap and
                // one listing, and there is no list in front of it to derive
                // it from.
                importedAs: try? CommunityImport.existingImport(of: listing.id, in: context),
                selectedHike: &selection.wrappedValue
            )
        }
        // And the hiker's own line, which the same recognizer answers for —
        // see `MapCoordinator+RouteTap.swift`. The selection is read when the
        // tap arrives rather than captured by value, because the line drawn is
        // whatever is selected *now*; a captured hike would be the one that
        // happened to be selected when the map first appeared, which is
        // usually none at all.
        drawnRouteTap.onOpen { [sheet, selection = $selectedHike] in
            guard let hike = selection.wrappedValue else { return }
            sheet.showDrawnRoute(hike)
        }
    }
}
