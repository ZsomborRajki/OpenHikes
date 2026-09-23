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
#if canImport(UserNotifications)
import UserNotifications
#endif

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
    /// A severe-weather alert stands over the place the hiker is looking at.
    ///
    /// The second one that is not a disagreement at all, and it stretches this
    /// type's name further than ``leftTheTrail`` does — it is not about
    /// movement in any sense. The name stays because every raw value here is a
    /// storage contract a delivered banner carries (see this file's header),
    /// and because what the type actually models is *the things this app
    /// interrupts a walk to say*, which is a set the wording, the categories
    /// and the transport already handle identically. What it is not is a
    /// reason to route it through ``MovementReminderController``: that
    /// controller is driven by the recorder and the walk session, and an alert
    /// is driven by the weather poll. The policy lives in
    /// ``WeatherAlertWatch``; only the value and the transport are shared.
    case severeWeather = "severeWeather"
    /// The hiker is on a trail in their library and nothing is being walked:
    /// start a hike along it? See ``WalkOffer``.
    ///
    /// The one kind that asks rather than reminds, and the one with two
    /// buttons — Start and Ignore — plus a tap that opens the trail, where the
    /// third answer, Don't Ask Again, lives. Clearing it away counts as
    /// Ignore, which is what ``reportsDismissal`` is for.
    case walkNearby = "walkNearby"

    var notificationIdentifier: String { "openhikes.reminder.\(rawValue)" }
    var categoryIdentifier: String { "openhikes.category.\(rawValue)" }

    /// The buttons the banner offers, which are the reason the hiker does not
    /// have to unlock the phone at all — or none, for a reminder that has no
    /// verb to offer.
    ///
    /// **Empty for leaving the trail, because no button would settle
    /// anything.** Pause and Resume each end the disagreement they are about,
    /// in the app's own process, without the phone coming out of a pocket.
    /// There is no equivalent for being off the route: the app cannot put the
    /// hiker back on it, *Open the map* is a foreground action where both
    /// existing ones are deliberately `background`, and a button that only
    /// silenced the banner would be offering to stop saying the one thing
    /// this reminder exists to say. So the banner is the whole of it, and
    /// tapping it opens the app the way any notification does.
    var actions: [MovementReminderAction] {
        switch self {
        // Nothing a button could settle, for the same reason leaving the
        // trail has none: the app cannot call off the weather, and a button
        // that only silenced the banner would offer to stop saying the one
        // thing this reminder exists to say. The alert's own link is in the
        // detail sheet, which is where the authority's advice is.
        case .leftTheTrail, .severeWeather: []
        case .pauseRecording: [.pause]
        case .resumeRecording, .resumeWalk: [.resume]
        case .walkNearby: [.startWalk, .ignoreWalk]
        }
    }

    /// Whether clearing the banner away is itself an answer the app should
    /// hear — registered as `customDismissAction`, which is the only way the
    /// delegate is told.
    ///
    /// Only for the question. Every other kind describes something the app
    /// can see for itself, and a hiker clearing it has said nothing about the
    /// walk; clearing the offer is a hiker saying no, and one that is not
    /// heard is asked again from the next relaunch.
    var reportsDismissal: Bool { self == .walkNearby }

    #if canImport(UserNotifications)
    /// How hard this reminder may knock, which is the difference between a
    /// warning and a piece of bookkeeping.
    ///
    /// The default is `.active`, and `.active` is precisely the level a Focus
    /// silences. Every one of these is posted to a phone in a pocket, on a
    /// walk — the single most likely time for Do Not Disturb or a custom
    /// Focus to be on — so the default loses the two that are not
    /// bookkeeping at exactly the moment they are worth the most.
    /// ``severeWeather`` is an agency's warning about the ground the hiker is
    /// standing on and ``leftTheTrail`` is a fork taken wrong in fog; a
    /// warning a Focus eats is a feature that exists only for hikers who
    /// happen not to use one. The other three are the app and the hiker
    /// disagreeing about whether a walk is being recorded, and a Focus is
    /// right to hold those until it is over — this is deliberately not
    /// "raise everything".
    ///
    /// `.timeSensitive` is a claim the app has to be entitled to make:
    /// `com.apple.developer.usernotifications.time-sensitive` is in
    /// `OpenHikes.entitlements` for this property's sake and nothing else's.
    /// A build that lost it is delivered at `.active` with no error and no
    /// log, and no test in this tree can say so — iOS has no `SecTask`, the
    /// archive CI builds is unsigned and therefore carries no entitlements
    /// at all, and `timeSensitiveSetting` reads `.notSupported` on an
    /// unauthorized host as well as an unentitled one. The entitlement line
    /// is the whole of the record. `.critical` is deliberately not on the
    /// table: it is granted by request rather than by checkbox, it overrides
    /// the ringer switch, and a hiking app's weather banner is not what that
    /// is for.
    var interruptionLevel: UNNotificationInterruptionLevel {
        switch self {
        case .leftTheTrail, .severeWeather: .timeSensitive
        case .pauseRecording, .resumeRecording, .resumeWalk, .walkNearby: .active
        }
    }
    #endif

    /// Where this sorts inside a Notification Summary, the one place several
    /// of these are ever seen side by side.
    ///
    /// Unset is zero for every kind, and a tie is ordered arbitrarily — so a
    /// summary can lead with "Taking a break?" and bury the storm warning
    /// under it. The ladder is ``interruptionLevel``'s argument at a finer
    /// grain: the warning about the ground outranks the warning about the
    /// route, both outrank anything about bookkeeping, and among the three
    /// bookkeeping reminders the two that are losing track of a walk outrank
    /// the one that is only spoiling a moving-time average.
    var relevanceScore: Double {
        switch self {
        case .severeWeather: Relevance.weatherWarning
        case .leftTheTrail: Relevance.offTheRoute
        case .resumeRecording, .resumeWalk, .walkNearby: Relevance.walkGoingUnrecorded
        case .pauseRecording: Relevance.stopCountedAsMoving
        }
    }

    /// The four rungs of that ladder, named rather than written into the
    /// switch as literals: the gaps between them are the argument, and a
    /// bare `0.8` beside a bare `0.5` says nothing about which pair of
    /// reminders it is keeping apart.
    private enum Relevance {
        /// Somebody else's warning about the ground, which is the one thing
        /// here this app did not decide to say.
        static let weatherWarning = 1.0
        /// A fact about where the hiker is, worth more than anything about
        /// bookkeeping and less than a warning from an agency.
        static let offTheRoute = 0.8
        /// A walk that is happening and is not being written down. The
        /// kilometres lost to it cannot be recovered afterwards.
        static let walkGoingUnrecorded = 0.5
        /// A moving-time average being spoiled by a lunch stop, which the
        /// hiker can still correct once they are home.
        static let stopCountedAsMoving = 0.3
    }
}

/// What a button on a reminder does when it is tapped.
///
/// All are *background* actions: they run in this app's process without
/// bringing it to the front, which is the point — the hiker's hands are busy
/// and the phone is in a pocket, the same case
/// ``RecordingIntents`` declares `IntentModes.background` for. The raw values
/// are the action identifiers a delivered banner carries, and are as much a
/// storage contract as the kinds' — see this file's header.
nonisolated enum MovementReminderAction: String, CaseIterable, Sendable {
    case ignoreWalk = "ignoreWalk"
    case pause = "pause"
    case resume = "resume"
    case startWalk = "startWalk"

    var title: String {
        switch self {
        case .ignoreWalk: "Ignore"
        case .pause: "Pause"
        case .resume: "Resume"
        // The walk controls' own word, so the button and the card it stands
        // in for say the same thing.
        case .startWalk: "Start Hike"
        }
    }
}

/// One reminder, ready to post.
nonisolated struct MovementReminder: Equatable, Sendable {
    let kind: MovementReminderKind
    let title: String
    let body: String
    /// The walk a ``MovementReminderKind/walkNearby`` offers, carried in the
    /// notification so its buttons can start or decline it from a process
    /// that did not post it. `nil` for every other kind.
    var walkOffer: WalkOfferSubject?

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

    /// The authority's own headline, with nothing added to it.
    ///
    /// No paraphrase and no advice of this app's own: the summary is what a
    /// meteorological agency chose to say, and re-wording somebody else's
    /// storm warning to fit a banner is the one place in this app where being
    /// creative could get a hiker hurt. The place is named for the reason
    /// ``leftTheTrail(trailTitle:offRouteMeters:)`` names the trail — a hiker
    /// comparing three routes needs to know which ridge this is about.
    ///
    /// The `detailsURL` is deliberately not in the body. A banner cannot make
    /// a URL tappable as a link, and pasting one in as text would be asking
    /// somebody in weather to read out an address; tapping the banner opens
    /// the app, where the sheet draws it as the link WeatherKit's terms
    /// require.
    static func severeWeather(
        _ alert: WeatherAlertSummary,
        placeName: String
    ) -> MovementReminder {
        let subject = placeName.isEmpty ? "your route" : placeName
        return MovementReminder(
            kind: .severeWeather,
            title: "Weather warning",
            body: "\(alert.summary) — \(subject). Issued by \(alert.source)."
        )
    }

    /// The question, rather than a reminder: the hiker is on a trail they
    /// have and is not walking it. Named, because the library can hold two
    /// trails that share a car park, and says what Start will do rather than
    /// that something went wrong — nothing has.
    static func walkNearby(_ subject: WalkOfferSubject, trailTitle: String) -> MovementReminder {
        let place = trailTitle.isEmpty ? "one of your trails" : trailTitle
        return MovementReminder(
            kind: .walkNearby,
            title: "Hike nearby",
            body: "Looks like you're on \(place). Start the hike to keep track of your progress?",
            walkOffer: subject
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
