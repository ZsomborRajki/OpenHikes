//
//  MapModesPresentation.swift
//  OpenHikes
//
//  Whether *Map Modes* is up, and which sheet presents it.
//
//  The button is on the map and the sheet is presented from inside the map
//  sheet's contents, so the flag has to be reachable from both without either
//  becoming an input of the root view's body — what
//  ``WeatherDetailPresentation`` is for the weather badge.
//
//  One thing the badge never meets: a place card that leaves the map live
//  behind it, the button included. The map sheet is already presenting that
//  card, so *Map Modes* asked for from under it waited, and came up when the
//  card was closed. So a card says when it is up, and presents *Map Modes*
//  over itself while it is.
//

import SwiftUI

/// Whether *Map Modes* is up.
///
/// A reference type the map holds and the sheet's contents present, as
/// ``WeatherDetailPresentation`` is and for its reason: the root view that
/// would have declared a `@State` flag is the one drawing the map.
@Observable
final class MapModesPresentation {
    /// A sheet that can present *Map Modes*.
    enum Presenter {
        /// The map sheet's contents, where nothing else is over the map.
        case mapSheet
        /// A place card that leaves the map live behind it.
        case card
    }

    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    private(set) var isPresented = false
    /// How many place cards are up over the map sheet: one or none.
    private(set) var cardsInFront = 0

    /// Raised from the map's own button.
    func present() {
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }

    func cardDidAppear() {
        cardsInFront += 1
    }

    func cardDidDisappear() {
        cardsInFront = max(0, cardsInFront - 1)
    }

    /// Whether `presenter` is the one to put the sheet up: the card while
    /// there is one, and the map sheet otherwise.
    func isPresented(by presenter: Presenter) -> Bool {
        guard isPresented else { return false }
        return switch presenter {
        case .mapSheet: cardsInFront == 0
        case .card: true
        }
    }

    /// Drives `.sheet(isPresented:)`. Building it reads the flag, so the
    /// modifier that builds it in its body is the flag's reader.
    func binding(for presenter: Presenter) -> Binding<Bool> {
        Binding(
            get: { self.isPresented(by: presenter) },
            set: { if !$0 { self.isPresented = false } }
        )
    }
}
