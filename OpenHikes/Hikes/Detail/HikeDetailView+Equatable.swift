//
//  HikeDetailView+Equatable.swift
//  OpenHikes
//
//  When a pass of the sheet's navigation stack is allowed to rebuild the hike
//  detail screen.
//
//  `MapSheet` builds every pushed screen in one closure, and that closure
//  reads the sheet's path: a screen's depth decides whose claim on the map is
//  in force — see `ScreenClaims`. So every push and every pop over a hike, and
//  every pass of the sheet itself — a drag between detents is one — hands this
//  screen a new copy of itself. Five of its inputs are closures, which SwiftUI
//  cannot compare, so every copy was a different view, and each one re-ran this
//  body and, through the `ScrollViewReader` it draws the card in, the whole
//  card: pushing *Route Style* rebuilt the card it was pushed over, and popping
//  back rebuilt it again.
//
//  The shape `MapSheet` and `MapSheetHikes` already have, and the closures are
//  left out for the reason they give: each one appends to the sheet's path or
//  calls a method on the sheet, so everything it reaches is storage that
//  outlives any one copy of it, and an older closure does exactly what a newer
//  one would. The trail graph and the community transport are left out too,
//  for a plainer reason: both are `let`s of the one `OpenHikesModel`, fixed
//  when it was built, and some of what stands behind them is a struct that
//  has no identity to compare. Everything else is the same instance on every
//  pass, compared by identity; its contents changing is something this body
//  observes directly — as it observes the hike.
//

import SwiftUI

extension HikeDetailView: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hike === rhs.hike
            && lhs.isSheetCompact == rhs.isSheetCompact
            && lhs.interaction === rhs.interaction
            && lhs.highlight === rhs.highlight
            && lhs.mapController === rhs.mapController
            && lhs.autoSave === rhs.autoSave
            && lhs.entitlement === rhs.entitlement
            && lhs.settings === rhs.settings
            && lhs.locationManager === rhs.locationManager
            && lhs.backgroundTracker === rhs.backgroundTracker
            && lhs.walkSession === rhs.walkSession
            && lhs.photoCapture === rhs.photoCapture
            && lhs.photoPins === rhs.photoPins
            && lhs.placePins === rhs.placePins
            && lhs.trailMaker === rhs.trailMaker
    }
}
