//
//  MapModesPresentation.swift
//  OpenHikes
//
//  Whether *Map Modes* is up.
//
//  The button is on the map and the sheet is presented from inside the map
//  sheet's contents, so the flag has to be reachable from both without either
//  becoming an input of the root view's body — what
//  ``WeatherDetailPresentation`` is for the weather badge. Which sheet
//  presents it, the map sheet's contents or a place card over them, is
//  ``MapControlModals``'s to say, for both of them and the location alert.
//

import SwiftUI

/// Whether *Map Modes* is up.
///
/// A reference type the map holds and the sheet's contents present, as
/// ``WeatherDetailPresentation`` is and for its reason: the root view that
/// would have declared a `@State` flag is the one drawing the map.
@Observable
final class MapModesPresentation {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    private(set) var isPresented = false

    /// The flag, for ``MapControlModals/binding(_:for:)`` to drive the sheet
    /// from. Building it reads the flag, so the modifier that builds it in
    /// its body is the flag's reader.
    var isPresentedBinding: Binding<Bool> {
        Binding(get: { self.isPresented }, set: { self.isPresented = $0 })
    }

    /// Raised from the map's own button.
    func present() {
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }
}
