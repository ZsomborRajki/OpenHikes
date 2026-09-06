//
//  MovementReminder.swift
//  OpenHikes
//
//  What a reminder says, and the identifiers the system knows it by.
//
//  A value rather than a call into `UserNotifications`, for the reason
//  `HikeActivityPresentation` is a value rather than a call into ActivityKit:
//  the wording is the half of this feature worth asserting on, and a hosted
//  test can read a struct where it cannot read a banner.
//
//  Every identifier here is a *storage* contract in the same sense a widget
//  kind is. A delivered notification carries its category, and the walker's
//  phone may hold one for hours before they take it out of a pocket — so a
//  category renamed in a later build arrives at a delegate that no longer
//  knows the buttons it is drawing, and the Resume button quietly does
//  nothing. Rename none of them.
//

import Foundation

/// Which of the three disagreements between the walk and the walker this is.
///
/// One identifier per kind, and that identifier is also the notification's
/// own: posting a second reminder of a kind *replaces* the banner already on
/// the Lock Screen rather than stacking a third one under it. That is the
/// whole reason the identifier is derived rather than made unique per post.
nonisolated enum MovementReminderKind: String, CaseIterable, Sendable {
    /// The recording is running and the walker has not moved in a while.
    case pauseRecording = "pauseRecording"
    /// The recording is paused and the walker is plainly walking.
    case resumeRecording = "resumeRecording"
    /// The walk along a followed trail is paused and the trail is being
    /// covered anyway.
    case resumeWalk = "resumeWalk"

    var notificationIdentifier: String { "openhikes.reminder.\(rawValue)" }
    var categoryIdentifier: String { "openhikes.category.\(rawValue)" }

    /// The button the banner offers, which is the reason the walker does not
    /// have to unlock the phone at all.
    var action: MovementReminderAction {
        switch self {
        case .pauseRecording: .pause
        case .resumeRecording, .resumeWalk: .resume
        }
    }
}

/// What a button on a reminder does when it is tapped.
///
/// Both are *background* actions: they run in this app's process without
/// bringing it to the front, which is the point — the walker's hands are busy
/// and the phone is in a pocket, the same case
/// ``RecordingIntents`` declares `IntentModes.background` for.
nonisolated enum MovementReminderAction: String, CaseIterable, Sendable {
    case pause = "pause"
    case resume = "resume"

    var title: String {
        switch self {
        case .pause: "Pause"
        case .resume: "Resume"
        }
    }
}

/// One reminder, ready to post.
nonisolated struct MovementReminder: Equatable, Sendable {
    let kind: MovementReminderKind
    let title: String
    let body: String

    var notificationIdentifier: String { kind.notificationIdentifier }
    var categoryIdentifier: String { kind.categoryIdentifier }
}

/// The words themselves.
///
/// Two rules run through all three. Each says *what the app noticed* before it
/// says what to do about it, because a walker who did mean to pause has to be
/// able to dismiss the banner without wondering what the app is confused
/// about. And none of them claims anything the app has not measured: the
/// distance is the displacement the watch actually saw, not an estimate of how
/// far the walker has hiked.
nonisolated enum MovementReminderWording {
    /// Metres, rendered the way every other distance in this app is — in the
    /// reader's own units, at road precision.
    static func distance(_ meters: Double) -> String {
        guard meters.isFinite else { return "—" }
        return Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    static func resumeRecording(movedMeters: Double, pausedFor: TimeInterval) -> MovementReminder {
        MovementReminder(
            kind: .resumeRecording,
            title: "Still hiking?",
            body: "Your recording has been paused for \(HikeFormat.duration(pausedFor))"
                + " and you've moved \(distance(movedMeters)) since."
                + " Resume to put the rest of the walk on the track."
        )
    }

    /// Named, when there is a name to use. A walker with one trail open knows
    /// which walk this is; one who has been comparing three does not, and the
    /// title is the only thing on the banner that could tell them.
    static func resumeWalk(trailTitle: String, movedMeters: Double) -> MovementReminder {
        let subject = trailTitle.isEmpty ? "Your walk" : trailTitle
        return MovementReminder(
            kind: .resumeWalk,
            title: "Still on the trail?",
            body: "\(subject) is paused, but you've covered \(distance(movedMeters))"
                + " of it since. Resume to keep your progress."
        )
    }

    static func pauseRecording(stillFor: TimeInterval) -> MovementReminder {
        MovementReminder(
            kind: .pauseRecording,
            title: "Taking a break?",
            body: "You haven't moved for \(HikeFormat.duration(stillFor))."
                + " Pause the recording to keep the stop out of your moving time."
        )
    }
}
