//
//  MapSheet+Equatable.swift
//  OpenHikes
//
//  When a pass of `OpenHikesView` is allowed to rebuild the sheet.
//
//  `MapSheet`'s body is the sheet's `NavigationStack`, and without this every
//  pass of the root view ran it — the root reads the selected hike to draw
//  its route, so any write to that hike was one. SwiftData notifies on every
//  write to a `@Model`, equal or not, and importing a published hike writes
//  the new one many times while its screen is being pushed. Any of those
//  writes that landed in the frame the push finished gave the stack a second
//  update in it, and SwiftUI reported it: "Update NavigationRequestObserver
//  tried to update multiple times per frame" — about one import in six,
//  measured. Compared like this, a root pass that hands the sheet nothing new
//  is not one of its passes, and six imports ran the body 43 times rather
//  than 96.
//
//  The shape ``MapSheetHikes`` already has, and the closures are left out for
//  the reason it gives: they are methods on the root view, or write to its
//  `@State`, so everything they reach is storage that outlives any one copy of
//  it and an older closure does exactly what a newer one would. The rest are
//  the same instances on every pass, compared by identity; their contents
//  changing is something this view's own body observes.
//

import SwiftUI

extension MapSheet: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedHike === rhs.selectedHike
            && lhs.presentation === rhs.presentation
            && lhs.highlight === rhs.highlight
            && lhs.walkHighlight === rhs.walkHighlight
            && lhs.mapController === rhs.mapController
            && lhs.photoCapture === rhs.photoCapture
            && lhs.photoPins === rhs.photoPins
            && lhs.placePins === rhs.placePins
            && lhs.trailMaker === rhs.trailMaker
    }
}
