//
//  BackgroundTrackingOutcome.swift
//  OpenHikes
//
//  What the background-tracking switch is allowed to claim.
//
//  Its own file rather than a nested type on ``BackgroundTrailTracker``
//  because its reader is ``SettingsView`` — the tracker only ever returns it —
//  and because that file is at its length limit. See
//  `BackgroundTrailTracker.swift` for the feature itself.
//

/// What ``BackgroundTrailTracker/setEnabled(_:)`` was able to do about the
/// switch being turned on.
///
/// Returned because the answer used to be swallowed. Turning the switch on
/// with Always access refused reached the end of that method having asked
/// nothing and started nothing, while the switch itself stayed on — so the
/// app showed an enabled feature that could never run, kept showing it across
/// launches, and told the hiker nothing. Reported by the user 2026-09-20.
///
/// Three cases rather than a `Bool` because the middle one is not a failure:
/// the grant is being asked for and the answer arrives later, through
/// `locationManagerDidChangeAuthorization`. A switch that flicked itself off
/// while the system's own prompt was on top of it would be the app answering
/// the prompt for the hiker.
nonisolated enum BackgroundTrackingOutcome: Equatable {
    /// A system prompt is up. Nothing to report until it is answered.
    case awaitingPrompt
    /// Always access is refused, and nothing in this app can ask again — the
    /// only place it can change is the Settings app.
    case needsSettings
    /// The switch means what it says: armed, or stood down.
    case settled
}
