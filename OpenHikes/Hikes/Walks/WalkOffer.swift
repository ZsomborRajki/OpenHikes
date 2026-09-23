//
//  WalkOffer.swift
//  OpenHikes
//
//  Asking before a walk starts, rather than starting one.
//
//  A walk used to begin, silently, on the first matched fix with Follow This
//  Trail on. Being on a trail in the library is not the same as setting out
//  along it — a car park at the trailhead, a road that crosses the route, a
//  lunch stop on somebody else's walk — and each of those left a walk to be
//  ended by hand or swept as abandoned six hours later. So a match now
//  *offers* the walk, and the hiker answers: Start, Ignore, or Don't Ask
//  Again for this trail.
//
//  Two surfaces, because the hiker may or may not be looking. With the app in
//  front the offer is a card on the trail's detail — ``WalkOfferPrompt`` —
//  and nothing is posted over the screen they are already reading. Behind it
//  the offer is a notification with Start and Ignore on a long press, posted
//  by ``MovementReminderController``, and tapping it opens the same card.
//  ``TrailWalkSession`` holds the offer either way, so the two surfaces are
//  one answer rather than two that could disagree.
//

import Foundation

/// What the session is offering for a trail the hiker is on and not walking.
enum WalkOffer: Equatable {
    /// Asking: the card with Start, Ignore and Don't Ask Again, and — with
    /// the app not in front — the notification.
    case asking(hikeID: UUID)
    /// Not asking, but still on the trail. The hiker said Ignore, or Don't
    /// Ask Again, and a walk can still be started by hand while they are on
    /// it — an answer of "not now" must not become "not possible".
    case available(hikeID: UUID)

    var hikeID: UUID {
        switch self {
        case let .asking(hikeID), let .available(hikeID): hikeID
        }
    }

    var isAsking: Bool {
        if case .asking = self { return true }
        return false
    }
}

/// What a notification needs to carry for the walk it offers to be started
/// from it, by a process that may not be the one that posted it.
///
/// The route length rides along because a walk's coverage is measured on
/// ``RouteProfile``'s scale and no other, and a Start pressed on the Lock
/// Screen runs in a process with no profile in memory — building one would
/// materialise the whole route on the main thread to learn one number the
/// posting process already had.
nonisolated struct WalkOfferSubject: Equatable, Sendable {
    let hikeID: UUID
    let routeLengthMeters: Double

    private static let hikeIDKey = "walkOffer.hikeID"
    private static let routeLengthKey = "walkOffer.routeLengthMeters"

    init(hikeID: UUID, routeLengthMeters: Double) {
        self.hikeID = hikeID
        self.routeLengthMeters = routeLengthMeters
    }

    /// Read back from a delivered notification, or `nil` for one that does
    /// not carry a walk — every other kind of reminder.
    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Self.hikeIDKey] as? String,
              let id = UUID(uuidString: raw),
              let length = userInfo[Self.routeLengthKey] as? Double,
              length.isFinite, length > 0 else { return nil }
        self.init(hikeID: id, routeLengthMeters: length)
    }

    /// Plist types only: `userInfo` is serialised by the notification centre.
    var userInfo: [String: Any] {
        [Self.hikeIDKey: hikeID.uuidString, Self.routeLengthKey: routeLengthMeters]
    }
}

/// An Ignore, remembered — see ``SettingsKey/walkOfferDecline``.
///
/// It holds until the hiker leaves the trail, which is the boundary the
/// session clears it on, or for ``TrailWalkPolicy/abandonAfter`` at most. The
/// bound is for the leave nobody saw: the background feed stands down once
/// the hiker is out of the trail's region, so a drive home produces no
/// off-route fix at all, and without it an Ignore on Saturday would still be
/// silencing the same trail the following weekend.
nonisolated struct WalkOfferDecline: Codable, Equatable {
    let hikeID: UUID
    let declinedAt: Date

    func holds(for hikeID: UUID, at now: Date) -> Bool {
        self.hikeID == hikeID && now.timeIntervalSince(declinedAt) < TrailWalkPolicy.abandonAfter
    }
}

nonisolated enum WalkOfferPolicy {
    /// How far off the line counts as having left the trail, for the purpose
    /// of asking again.
    ///
    /// ``MovementReminderPolicy/offTrailMeters`` rather than the follow
    /// threshold, and for the reason that one gives: being wrong here costs a
    /// banner in a pocket. A fix under tree cover is routinely fifty metres
    /// out, and at seventy-five a switchback would clear the hiker's Ignore
    /// and have the next match ask them the same question again.
    static let leftTrailMeters = MovementReminderPolicy.offTrailMeters
}
