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
//  the hiker's position: `hiker` is a closure, called only by the change
//  handler when `isRecording` is true as the view appears or turns true, so
//  no body reads a value that changes with every fix.
//
//  `isRecording` is a closure too, called by this modifier's own body, which
//  is a boundary for what it reads (*Render isolation, in practice* in
//  AGENTS.md). The root passes the recorder's `isActive`, which reads its
//  phase, and the phase moves at the first fix, at every pause and resume
//  and at every stop Auto-Pause calls. Passed as a value, it was an input of
//  `OpenHikesView`: each of those re-ran the root and the sheet under it,
//  to compare a Bool that had not changed (traced on 2026-11-24). Now they
//  re-run this modifier and nothing it modifies.
//
//  `trail:` is still an argument, evaluated by the body that applies it: the
//  selected hike's name and displayed route stay inputs of `OpenHikesView`.
//  They move with the selection, its line or its name, which re-run that
//  body anyway.
//
//  The third edge — search — is not here because it is not a change handler:
//  `MapSheet` sets the subject in the same breath as it zooms the map, which
//  is the moment it belongs to. Nor is the fourth, the map's location button,
//  for the same reason: the map hears itself turn to follow the hiker, in
//  `MapCoordinator+TrackingButton.swift`.
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
    ///   - isRecording: whether a recording owns the badge right now. A
    ///     closure, read by this modifier's body rather than by the caller's
    ///     — see the file's header.
    ///   - hiker: where the hiker is, asked only at the moment a recording
    ///     starts. A closure rather than a value so it is not read on every
    ///     pass — the position changes with every fix, and this modifier must
    ///     not be a reason anything re-renders at that rate.
    func weatherFocus(
        _ focus: WeatherFocus,
        trail: WeatherSubject?,
        isRecording: @escaping () -> Bool,
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
    let isRecording: () -> Bool
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
            .onChange(of: isRecording(), initial: true) { _, isRecording in
                guard isRecording else {
                    focus.unpinFromHiker()
                    return
                }
                focus.pinToHiker(at: hiker())
            }
    }
}
