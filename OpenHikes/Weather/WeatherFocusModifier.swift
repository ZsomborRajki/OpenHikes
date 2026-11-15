//
//  WeatherFocusModifier.swift
//  OpenHikes
//
//  The two edges in the root view that point the weather badge somewhere.
//
//  A modifier rather than two `.onChange` handlers written out in
//  `OpenHikesView`, so what a new selection, or a recording starting or
//  stopping, does to the badge is kept with the weather rather than in the
//  body that draws the map. That handling is what it isolates, and with it
//  the hiker's position: `hiker` is a closure, called only when a recording
//  starts, so no body reads a value that changes with every fix.
//
//  The two values it compares are not isolated. `trail:` and `isRecording:`
//  are arguments, and a modifier's arguments are evaluated by the body that
//  applies it (*Render isolation, in practice* in AGENTS.md): the selected
//  hike's name and displayed route, and the recorder's phase behind
//  `isActive`, stay inputs of `OpenHikesView` however they are compared
//  here. They move with the selection, its line or its name, and the
//  recording's phase, not with each fix, and no trace has put a cost on
//  them; taking them out of that body would mean moving the observation
//  itself, and measuring it.
//
//  The third edge — search — is not here because it is not a change handler:
//  `MapSheet` sets the subject in the same breath as it zooms the map, which
//  is the moment it belongs to.
//
//  The precedence between the two is not here either. `WeatherFocus` decides
//  what a search may do while a recording is running; a call site that decided
//  it for itself is exactly how that rule would come apart.
//

import CoreLocation
import SwiftUI

extension View {
    /// Keeps `focus` pointed at what the app is showing: the selected trail,
    /// or the hiker for as long as a recording is running.
    ///
    /// - Parameters:
    ///   - trail: the subject the current selection implies, or `nil` when
    ///     nothing is selected. Built by the caller because the route's
    ///     geometry belongs to the map, not to the weather domain.
    ///   - isRecording: whether a recording owns the badge right now.
    ///   - hiker: where the hiker is, asked only at the moment a recording
    ///     starts. A closure rather than a value so it is not read on every
    ///     pass — the position changes with every fix, and this modifier must
    ///     not be a reason anything re-renders at that rate.
    func weatherFocus(
        _ focus: WeatherFocus,
        trail: WeatherSubject?,
        isRecording: Bool,
        hiker: @escaping () -> CLLocationCoordinate2D?
    ) -> some View {
        modifier(
            WeatherFocusModifier(
                focus: focus,
                trail: trail,
                isRecording: isRecording,
                hiker: hiker
            )
        )
    }
}

private struct WeatherFocusModifier: ViewModifier {
    let focus: WeatherFocus
    let trail: WeatherSubject?
    let isRecording: Bool
    let hiker: () -> CLLocationCoordinate2D?

    func body(content: Content) -> some View {
        content
            .onChange(of: trail) { _, trail in
                // A deselection leaves the badge on whatever it was showing
                // rather than blanking it: the map going empty is not a reason
                // to stop answering "what is the weather".
                guard let trail else { return }
                focus.focus(on: trail)
            }
            // Keyed on whether a recording is running rather than on its phase,
            // so a pause doesn't hand the badge back to a search the hiker
            // made an hour ago.
            .onChange(of: isRecording, initial: true) { _, isRecording in
                guard isRecording else {
                    focus.unpinFromHiker()
                    return
                }
                focus.pinToHiker(at: hiker())
            }
    }
}
