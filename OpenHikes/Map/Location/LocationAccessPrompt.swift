//
//  LocationAccessPrompt.swift
//  OpenHikes
//
//  What the app says when the hiker has turned location off, and the way the
//  map asks for it to be said.
//
//  One file for both surfaces on purpose. A refusal is visible in two places —
//  the "my location" button on the map, and the background-tracking switch in
//  Settings — and they are not the same grant: the button wants When In Use
//  and the switch wants Always, so a hiker can have granted one and refused
//  the other and each screen has to name the one it is missing. What they must
//  not do is drift apart on everything else, which is what happens when two
//  screens each write their own alert. So the wording lives in
//  ``LocationAccessNeed`` and both screens present it through the same
//  modifier; only the case differs.
//
//  The copy names what is lost rather than what is off. "Location Access Off"
//  is a status, and a hiker who turned it off knows it already; what they
//  cannot know is that it is the reason the button did nothing.
//

import Foundation
import SwiftUI

/// Which location grant is missing, from the point of view of the thing that
/// could not happen without it.
enum LocationAccessNeed {
    /// Background trail tracking, which is the widget and the Live Activity
    /// keeping up while the app is closed. Missing `.authorizedAlways`.
    case always
    /// The map's "my location" button, the first fix a launch centres on, the
    /// weather where the hiker is standing: everything the foreground feed
    /// serves. Missing `.authorizedWhenInUse`.
    case whileUsing

    var title: String {
        switch self {
        case .always: String(localized: "Background Location Off")
        case .whileUsing: String(localized: "Location Access Off")
        }
    }

    /// Names what the grant buys, in a sentence or two. Deliberately not a
    /// list of settings taps: the path through the Settings app is Apple's to
    /// change, and a stale set of directions is worse than none when the
    /// button beside this text goes straight there.
    var message: String {
        switch self {
        case .always:
            String(localized: """
            Background Trail Tracking needs Always location access to keep your \
            widget and Live Activity updating while OpenHikes is closed.
            """)
        case .whileUsing:
            String(localized: """
            OpenHikes needs location access to show where you are and the weather \
            around you. Turn it on in Settings.
            """)
        }
    }
}

/// The map's way of asking for the alert above.
///
/// A reference type the map holds and the screen presents, which is the shape
/// ``DrawnRouteTap`` already uses for the same problem: the tap happens inside
/// a `UIView` MapKit owns, and the thing it has to raise is SwiftUI state
/// belonging to a view that cannot see into the map. The difference is the
/// direction of the read — a tap has no state to carry, an alert does — so
/// this one is observed rather than handed a closure.
///
/// ``isShowing`` is the only thing on it, and it changes twice per refusal
/// the hiker actually taps into. It is presented from inside the sheet's
/// contents, or from a place card over them — see ``MapControlModals``, and
/// ``MapScreenAlerts`` for why the root view is the one place this alert
/// cannot be attached.
@MainActor
@Observable
final class LocationAccessPrompt {
    var isShowing = false

    /// The flag, for ``MapControlModals/binding(_:for:)`` to drive
    /// `.alert(isPresented:)` from. Building it reads the flag —
    /// `Binding(get:set:)` calls its getter as it is made — so whichever body
    /// builds it is a reader of this flag, and runs again on the two changes
    /// a refusal makes. A modifier builds it in its own body, so that is all
    /// that runs again: built along with the sheet's contents, it made a
    /// reader of the root view's body in landscape, where ``MapSidePanel``
    /// takes those contents as a view built there. See *Render isolation, in
    /// practice* in the repository instructions.
    var isShowingBinding: Binding<Bool> {
        Binding(get: { self.isShowing }, set: { self.isShowing = $0 })
    }

    /// Raised from the map's own button, which is the moment the hiker has
    /// just asked for the thing that cannot happen.
    func show() {
        isShowing = true
    }
}

extension View {
    /// Presents the map's refusal from `presenter` — the map sheet's contents,
    /// or a place card over them. See ``MapControlModals``.
    func locationAccessAlert(
        _ modals: MapControlModals,
        from presenter: MapControlModals.Presenter
    ) -> some View {
        modifier(MapLocationAccessAlert(modals: modals, presenter: presenter))
    }

    /// Presents ``LocationAccessNeed``'s wording, with the one button that can
    /// do anything about it — see ``OpenSettingsLink``.
    func locationAccessAlert(
        _ need: LocationAccessNeed,
        isPresented: Binding<Bool>
    ) -> some View {
        alert(need.title, isPresented: isPresented) {
            OpenSettingsLink.link
            Button("Not Now", role: .cancel) { /* dismiss */ }
        } message: {
            Text(need.message)
        }
    }
}

/// The map's refusal, as a modifier so that its own body, and nothing above
/// it, builds the binding and so reads the flag.
private struct MapLocationAccessAlert: ViewModifier {
    let modals: MapControlModals
    let presenter: MapControlModals.Presenter

    func body(content: Content) -> some View {
        content.locationAccessAlert(
            .whileUsing,
            isPresented: modals.binding(modals.locationAccess.isShowingBinding, for: presenter)
        )
    }
}
