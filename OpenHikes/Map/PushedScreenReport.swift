//
//  PushedScreenReport.swift
//  OpenHikes
//
//  Tells the map's controllers whether a screen is pushed over the sheet, and
//  whether that screen is the trail maker.
//
//  A modifier of its own rather than two `onChange`s in `MapSheet`'s body, and
//  that is the point of it. An `onChange(of:)` reads its value in the body it
//  is attached to, so those two made every push and every pop a pass of
//  `MapSheet` — the body that builds the sheet's `NavigationStack`. That is
//  wasted work on any push, and a real fault on a push that changes the
//  selection too: opening the maker writes the path and clears the selected
//  hike, the flag and the selection each ran the body once, and the stack
//  was updated twice in one frame. SwiftUI reports that as "Update
//  NavigationRequestObserver tried to update multiple times per frame", and
//  `TrailMakerUITests` raised it every time the maker opened. Read here, the
//  flags wake only this modifier, and the selection is left as the one change
//  that reaches `MapSheet`.
//

import SwiftUI

struct PushedScreenReport: ViewModifier {
    var presentation: SheetPresentation
    var photoCapture: PhotoCaptureController
    var photoPins: PhotoMapPinController
    var placePins: TrailPlacePinController
    var trailMaker: TrailDraftController

    func body(content: Content) -> some View {
        content
            // The map's photo controls belong to whatever screen is pushed,
            // and a pushed screen's `onDisappear` arrives only once the pop
            // animation has finished — which left the camera pill and this
            // hike's photo pins over the map, fully opaque and answering taps,
            // for the whole of a back navigation. Reported here as a function
            // of the path rather than as a pop event, so an abandoned
            // back-swipe recomputes to the same answer rather than withdrawing
            // them for good.
            //
            // "A screen, any screen" is deliberately all this asks: a hike and
            // the photo viewer pushed on top of it are both a screen that can
            // offer the pill, so moving between them changes nothing here.
            .onChange(of: presentation.hasPushedScreen, initial: true) { _, isPushed in
                photoCapture.setHostScreenPresent(isPushed)
                photoPins.setHostScreenPresent(isPushed)
                placePins.setHostScreenPresent(isPushed)
                // The inverse of the same signal, which is the whole of what
                // keeps the maker's pill and the camera's out of each other's
                // way — see ``TrailDraftController``.
                trailMaker.setHostScreenPresent(isPushed)
            }
            // And whether the map is the maker's canvas, which is a narrower
            // question than "is anything pushed" and has to be asked
            // separately: pushing a hike over the maker would leave the map
            // taking waypoints for a screen nobody is looking at.
            .onChange(of: presentation.isTrailDraftPresented, initial: true) { _, isDrafting in
                trailMaker.setEditing(isDrafting)
            }
    }
}
