//
//  WeatherFocusModifier.swift
//  OpenHikes
//
//  The two edges in the root view that point the weather badge somewhere.
//
//  A modifier rather than two `.onChange` handlers written out in
//  `OpenHikesView`, for the reason ``DismissButton`` is one: a `ViewModifier`
//  is a boundary the same way a `View` is, so the recorder's phase and the
//  selected route's geometry are read *here* rather than becoming inputs of
//  the body that draws the map. The third edge — search — is not here because
//  it is not a change handler: `MapSheet` sets the subject in the same breath
//  as it zooms the map, which is the moment it belongs to.
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
    ///     pass — the position changes at roughly 1 Hz, and this modifier must
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
