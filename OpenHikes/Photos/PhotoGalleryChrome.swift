//
//  PhotoGalleryChrome.swift
//  OpenHikes
//
//  The dark screen a full-size photograph is shown on.
//
//  Both galleries — the hiker's own and a community listing's — are the same
//  surface: black to the edges, a navigation bar with no background of its
//  own, and that bar told which colour scheme it is standing in.
//
//  The last of those three is the one that is easy to get wrong and invisible
//  until it is. The backdrop is black whatever the device is set to, so a bar
//  left to follow the system renders its title in the light scheme's label
//  colour — black on black. It has to be told, in both galleries, and it was
//  told in both galleries by hand.
//
//  The backdrop is not decoration either: the pages letterbox rather than
//  crop, so this is what the un-filled edges of a portrait shot on a landscape
//  screen become.
//

import CoreLocation
import SwiftUI

extension View {
    /// Puts this on the black, bar-less surface both photo galleries use.
    ///
    /// Applied to the pages rather than wrapping them, so each gallery keeps
    /// its own empty state, overlay and toolbar — which are the parts that
    /// genuinely differ.
    func photoGalleryChrome() -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            self
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
    }
}

/// The button that takes the map to where a photograph was taken, and gets out
/// of the way so it can be seen.
///
/// The same control in both galleries, down to the label a reader hears. What
/// differs is which pin is asked to open — the hiker's own photo pins, or a
/// community listing's — and those are different controllers answering the same
/// question, so they are handed in.
///
/// The camera is framed on the coordinate at a fixed, close span rather than
/// re-fitted to the whole route: the point of the button is to see where one
/// photograph was taken, and a route-wide fit would put it back in the middle
/// of everything. See ``MapController/showPhotoSpot(_:)``.
///
/// **The order is the reason this is one type rather than two that look
/// alike.** The pin is asked for before the dismiss, never after: the pins
/// belong to the screen this one is pushed over, so they are off the map until
/// it comes back, and a selection asked for afterwards would arrive at a map
/// that had already settled. `beforeFraming` keeps its slot for the same kind
/// of reason — the hiker's own gallery moves the selection dot first, and
/// folding that in after the camera move would be reordering two writes to
/// save a line.
///
/// "Out of the way" is the whole sheet rather than just this screen. Popping
/// alone restores the height the gallery was being read at, which on a screen
/// that had been at `.large` is a sheet closing straight back over the pin — so
/// each caller's `thenSelecting` collapses the sheet as well.
struct ShowPhotoSpotButton: View {
    let coordinate: CLLocationCoordinate2D
    var mapController: MapController
    let identifier: String
    /// Anything that has to happen before the camera moves.
    var beforeFraming: () -> Void = { /* nothing, for a gallery with no dot */ }
    /// Opens this photograph's pin, and does whatever else the screen needs
    /// before it goes.
    let thenSelecting: () -> Void

    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        Button {
            beforeFraming()
            mapController.showPhotoSpot(coordinate)
            thenSelecting()
            dismiss()
        } label: {
            Image(systemName: "mappin.and.ellipse")
        }
        .accessibilityLabel("Show where this photo was taken")
        .accessibilityIdentifier(identifier)
    }
}
