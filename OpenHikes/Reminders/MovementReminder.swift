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
//  kind is. A delivered notification carries its category, and the hiker's
//  phone may hold one for hours before they take it out of a pocket — so a
//  category renamed in a later build arrives at a delegate that no longer
//  knows the buttons it is drawing, and the Resume button quietly does
//  nothing. Rename none of them.
//

import Foundation

/// Which of the three disagreements between the walk and the hiker this is.
///
/// One identifier per kind, and that identifier is also the notification's
/// own: posting a second reminder of a kind *replaces* the banner already on
/// the Lock Screen rather than stacking a third one under it. That is the
/// whole reason the identifier is derived rather than made unique per post.
nonisolated enum MovementReminderKind: String, CaseIterable, Sendable {
    /// The walk is under way and the hiker is no longer on the route.
    ///
    /// The odd one out of the four, and deliberately. The other three are
    /// bookkeeping — the app and the hiker disagree about whether a walk is
    /// happening, and a button settles it. This one is not a disagreement at
    /// all: the app is telling the hiker something about the ground they are
    /// standing on, at the moment it is worth the most, which is a fork taken
    /// wrong in fog with the phone in a pocket.
    case leftTheTrail = "leftTheTrail"
    /// The recording is running and the hiker has not moved in a while.
    case pauseRecording = "pauseRecording"
    /// The recording is paused and the hiker is plainly walking.
    case resumeRecording = "resumeRecording"
    /// The walk along a followed trail is paused and the trail is being
    /// covered anyway.
    case resumeWalk = "resumeWalk"

    var notificationIdentifier: String { "openhikes.reminder.\(rawValue)" }
    var categoryIdentifier: String { "openhikes.category.\(rawValue)" }

    /// The button the banner offers, which is the reason the hiker does not
    /// have to unlock the phone at all — or `nil` for a reminder that has no
    /// verb to offer.
    ///
    /// **Optional because leaving the trail has no button that would settle
    /// anything.** Pause and Resume each end the disagreement they are about,
    /// in the app's own process, without the phone coming out of a pocket.
    /// There is no equivalent for being off the route: the app cannot put the
    /// hiker back on it, *Open the map* is a foreground action where both
    /// existing ones are deliberately `background`, and a button that only
    /// silenced the banner would be offering to stop saying the one thing
    /// this reminder exists to say. So the banner is the whole of it, and
    /// tapping it opens the app the way any notification does.
    var action: MovementReminderAction? {
        switch self {
        case .leftTheTrail: nil
        case .pauseRecording: .pause
        case .resumeRecording, .resumeWalk: .resume
        }
    }
}

/// What a button on a reminder does when it is tapped.
///
/// Both are *background* actions: they run in this app's process without
/// bringing it to the front, which is the point — the hiker's hands are busy
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
/// says what to do about it, because a hiker who did mean to pause has to be
/// able to dismiss the banner without wondering what the app is confused
/// about. And none of them claims anything the app has not measured: the
/// distance is the displacement the watch actually saw, not an estimate of how
/// far the hiker has hiked.
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
                + " Resume to put the rest of the hike on the track."
        )
    }

    /// Named, when there is a name to use. A hiker with one trail open knows
    /// which walk this is; one who has been comparing three does not, and the
    /// title is the only thing on the banner that could tell them.
    static func resumeWalk(trailTitle: String, movedMeters: Double) -> MovementReminder {
        let subject = trailTitle.isEmpty ? "Your hike" : trailTitle
        return MovementReminder(
            kind: .resumeWalk,
            title: "Still on the trail?",
            body: "\(subject) is paused, but you've covered \(distance(movedMeters))"
                + " of it since. Resume to keep your progress."
        )
    }

    /// Named for the same reason ``resumeWalk(trailTitle:movedMeters:)`` is,
    /// and the distance is the one the app actually measured — how far the
    /// fix was from the line, not a guess at how far there is to walk back.
    ///
    /// No instruction in the body. The other three end in one, because each
    /// has a button that carries it out; this one would be telling a hiker in
    /// fog what to do about terrain the app cannot see. What it owes them is
    /// the fact, at the moment they can still act on it.
    static func leftTheTrail(trailTitle: String, offRouteMeters: Double) -> MovementReminder {
        let subject = trailTitle.isEmpty ? "the trail" : trailTitle
        return MovementReminder(
            kind: .leftTheTrail,
            title: "Off the trail",
            body: "You're about \(distance(offRouteMeters)) from \(subject)."
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
