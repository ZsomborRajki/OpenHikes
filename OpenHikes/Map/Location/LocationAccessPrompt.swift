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
        case .always: "Background Location Off"
        case .whileUsing: "Location Access Off"
        }
    }

    /// Names the three things the grant buys and the one place it can be
    /// given back. Deliberately not a list of settings taps: the path through
    /// the Settings app is Apple's to change, and a stale set of directions
    /// is worse than none when the button beside this text goes straight
    /// there.
    var message: String {
        switch self {
        case .always:
            """
            Background Trail Tracking needs Always location access, which \
            OpenHikes doesn't have. Without it your widget and Live Activity \
            stop updating as soon as you close the app. You can grant it in \
            Settings.
            """
        case .whileUsing:
            """
            OpenHikes can't show where you are, centre the map on you, or \
            report the weather where you're standing. Turn on Location \
            Access for OpenHikes in Settings to use the location button.
            """
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
/// the hiker actually taps into. It is presented by ``MapScreenAlerts``, from
/// inside the sheet's contents — see that file for why the root view is the
/// one place this alert cannot be attached, and ``isShowingBinding`` for which
/// body attaching it there makes a reader of this flag.
@MainActor
@Observable
final class LocationAccessPrompt {
    var isShowing = false

    /// Drives `.alert(isPresented:)`. Building it reads the flag —
    /// `Binding(get:set:)` calls its getter as it is made — so whichever body
    /// builds it is a reader of this flag, and runs again on the two changes
    /// a refusal makes. It is built with the sheet's contents. In portrait
    /// that is inside the `.sheet` modifier's body, around them, and the root
    /// view's own body is not a reader; in landscape it is the root view's
    /// body, because ``MapSidePanel`` takes its contents as a view built
    /// there rather than as a closure of its own to call. See *Render
    /// isolation, in practice* in the repository instructions.
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
