//
//  MovementReminderNotifying.swift
//  OpenHikes
//
//  The seam between the app's reminder policy and `UserNotifications`.
//
//  It exists for the reason ``HikeActivityPresenting`` does, and the case is
//  the same one: the framework half cannot be exercised by a hosted unit test
//  — the test host is not a walker's phone, authorization is whatever the
//  developer's simulator happens to have been told once, and a posted banner
//  has nothing a suite can read — while the interesting half is entirely
//  policy. When a pause stops looking like a pause, which of two subjects the
//  reminder belongs to, how often one may be repeated and when a stale one is
//  taken back down are all decided in ``MovementReminderController``, above
//  this protocol, and every one of them is visible through a stub.
//

import Foundation

/// What the controller needs from the notification centre, and nothing more.
///
/// `@MainActor` rather than an actor: `UNUserNotificationCenter` is its own
/// synchronisation, the only state behind this is a flag saying whether the
/// categories have been registered, and the controller that drives it is
/// main-actor isolated because the recorder and the walk session are.
@MainActor
protocol MovementReminderNotifying: AnyObject {
    /// Asks for permission if it has not been asked for yet, and reports
    /// whether reminders may be posted at all.
    ///
    /// Asked at the moment a pause begins rather than at launch, which is the
    /// same argument the photo-library permission is granted by: a prompt that
    /// arrives while the walker is holding the phone, having just tapped
    /// Pause, is a question about something they are doing. One at launch is a
    /// question about something they may never do.
    func authorize() async -> Bool

    /// Puts one reminder on the walker's screen, replacing any earlier one of
    /// the same kind. Silent on failure, for the reason a Live Activity
    /// refusal is silent: it is the system's answer about a banner, and there
    /// is nothing to be done about it in the middle of a hike.
    func post(_ reminder: MovementReminder) async

    /// Takes a reminder back down — pending and already delivered.
    ///
    /// The delivered half is what matters. A walker who resumed the recording
    /// from the recording screen has answered the question, and a banner still
    /// sitting in Notification Centre asking them to resume is the app
    /// disagreeing with itself about a walk it can see the state of.
    func withdraw(_ kind: MovementReminderKind)
}
