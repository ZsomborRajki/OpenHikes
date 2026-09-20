//
//  BackgroundTrackingSection.swift
//  OpenHikes
//
//  The settings section for background trail tracking: the switch, what it
//  says when the system will not let it run, and the way back to Settings.
//
//  Its own file rather than another computed property on ``SettingsView`` for
//  the reason ``CloudSyncSection`` is one — it is a section with live state,
//  and now with two of them: the hiker's preference, which is stored, and the
//  grant CoreLocation will give it, which is not. What it exists to show is
//  the two disagreeing.
//
//  **The footer and `NSLocationAlwaysAndWhenInUseUsageDescription` say the
//  same thing on purpose**, and both name both surfaces. That string is the
//  whole of what App Review reads about Always access — see *Notes for App
//  Review* in `APP_REVIEW.md` — and a switch whose own description claimed
//  less than the prompt would be the app disagreeing with itself in the one
//  place a reviewer compares the two.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// iOS-only: this is what feeds the Home Screen widget and the Live Activity
/// while OpenHikes isn't open. Off by default — turning it on is what first
/// triggers the system's Always-location prompt.
struct BackgroundTrackingSection: View {
    let tracker: BackgroundTrailTracker
    /// Read for the grant, not for a fix. See
    /// ``LocationManager/hasAlwaysAccess`` for why the app's one authorization
    /// observer answers for a feature it serves none of.
    let locationManager: LocationManager

    @AppStorage(SettingsKey.backgroundTrackingEnabled)
    private var backgroundTrackingEnabled = false
    /// Raised when the switch is turned on and Always access is refused — the
    /// one case the app can neither ask about nor work around.
    @State private var showAccessDenied = false

    var body: some View {
        #if os(iOS)
        Section {
            Toggle("Background Trail Tracking", isOn: binding)
            // Two warnings, in the order the hiker can act on them. Location
            // first: without the grant the feature does nothing at all, while
            // Background App Refresh only decides how *promptly* it does it.
            //
            // A row rather than a second alert. An alert is gone the moment it
            // is dismissed, and this state can be arrived at without any tap
            // to attach one to — the grant can be withdrawn in Settings while
            // the switch sits on, and the Always prompt is one-shot, so a
            // hiker who declined the upgrade once will never be asked again
            // however many times they flick the switch. What all of those have
            // in common is a switch that is on and a feature that is off, and
            // the only honest way to show that is a line that stays.
            if backgroundTrackingEnabled, !locationManager.hasAlwaysAccess {
                warning(
                    "OpenHikes doesn't have Always location access, so this can't run. "
                        + "Turn it on in Settings."
                )
                .accessibilityIdentifier("background-tracking-needs-always")
            }
            if backgroundTrackingEnabled, UIApplication.shared.backgroundRefreshStatus != .available {
                warning("Background App Refresh is off, so this may not update while OpenHikes is closed.")
            }
        } header: {
            Text("Background Tracking")
        } footer: {
            Text(
                """
                Keeps your Home Screen widget and Live Activity showing your \
                progress along the selected trail even when OpenHikes isn't \
                open, using occasional, low-power location updates.
                """
            )
        }
        // The same wording the map's refused location button raises, one case
        // along — see ``LocationAccessNeed``, which is where both live so the
        // two screens cannot drift apart.
        .locationAccessAlert(.always, isPresented: $showAccessDenied)
        #endif
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    /// The switch, and what it does when the answer is no.
    ///
    /// It used to write the new value and drop whatever the tracker made of
    /// it, so turning it on with Always access refused left a switch that was
    /// on, stayed on across launches, and armed nothing — the app claiming a
    /// feature it could not run. Now the one outcome nothing can be done about
    /// puts the switch back and says why.
    ///
    /// ``BackgroundTrackingOutcome/awaitingPrompt`` deliberately does neither.
    /// The system's own alert is on screen at that moment and the hiker has
    /// not answered it yet; a switch that flicked itself off underneath it
    /// would be this app answering for them. `authorizationChanged()` hears
    /// the real answer, and if it is no, the warning row above is what says so
    /// — a refusal there leaves the switch on, which is truthful: the hiker
    /// did ask for this, and the row reports that they cannot have it yet.
    private var binding: Binding<Bool> {
        Binding(
            get: { backgroundTrackingEnabled },
            set: { newValue in
                backgroundTrackingEnabled = newValue
                guard tracker.setEnabled(newValue) == .needsSettings else { return }
                backgroundTrackingEnabled = false
                showAccessDenied = true
            }
        )
    }
}
