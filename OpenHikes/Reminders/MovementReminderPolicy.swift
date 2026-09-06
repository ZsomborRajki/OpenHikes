//
//  MovementReminderPolicy.swift
//  OpenHikes
//
//  When a paused walk has stopped looking like a pause, and when a running
//  recording has stopped looking like walking.
//
//  Both questions are the same shape and neither is answerable from a single
//  fix. A walker who steps out of a restaurant to find the toilets has moved;
//  so has one who put the phone down at a viewpoint and had the GPS wander
//  eighty metres around them. Neither is a hike being recorded with the
//  recorder paused, and a reminder for either is the app crying wolf at
//  somebody whose phone is in a pocket.
//
//  So the decision is made against *where the pause began*, over two rules
//  that answer to different things:
//
//  * **Distance** — straight-line displacement from the anchor. Straight-line
//    rather than accumulated, deliberately: an accumulated total is the sum of
//    every GPS wobble as well as every step, so a phone left on a table for an
//    hour walks half a kilometre on its own. Displacement cannot, because
//    noise around one spot has nowhere to go.
//  * **Pace** — how much of that displacement arrived inside one short
//    window. This is the bicycle clause. A walker who genuinely wandered off
//    trips the distance rule eventually; somebody who set off at cycling pace
//    covers the same ground in two minutes and should hear about it then,
//    not half an hour later at the bottom of the valley.
//
//  The cost of being wrong is asymmetric and the numbers below are chosen for
//  it. A missed reminder costs a walker a kilometre of track. A spurious one
//  costs them a banner they did not need, in the middle of a hike, having
//  already told the app they were stopping — which is the worse failure, and
//  the reason the thresholds are on the conservative side of the issue's own
//  "a kilometre or a fast pace".
//

import Foundation

/// The thresholds every reminder in this folder is decided by.
///
/// One enum rather than constants on the two watches below, because the pair
/// of them describe one policy and the settings screen, the tests and the
/// wording all have to be talking about the same numbers.
nonisolated enum MovementReminderPolicy {
    /// How far from the pause anchor is no longer a pause.
    ///
    /// Chosen against the two cases the issue names. A trip from a restaurant
    /// to the toilets is tens of metres and a large car park is barely more;
    /// a walker who has genuinely set off again clears this inside ten
    /// minutes at hiking pace. Well above any plausible fix error too — the
    /// coarse watch below is a hundred-metre configuration, and significant
    /// location changes are coarser still.
    static let awayMeters = 500.0

    /// The pace rule's distance, and the window it has to arrive in.
    ///
    /// 250 m inside two minutes is a shade over 2 m/s — a bicycle, a jog, or
    /// a bus, and comfortably above a stroll around a car park. It exists to
    /// shorten the *time* to a reminder for exactly the case the issue raises,
    /// not to lower the bar: the walker still has to have covered real ground.
    static let paceMeters = 250.0
    static let paceWindow: TimeInterval = 120

    /// How long after a reminder the next one may be sent, and how many a
    /// single pause may produce at all.
    ///
    /// A reminder the walker ignored is information: either they meant to
    /// pause, or their phone is in a pocket and a fourth banner will not
    /// reach them any better than the third did. Both bounds apply — another
    /// reminder needs another ``awayMeters`` *and* another quarter of an hour.
    static let quietFor: TimeInterval = 15 * 60
    static let maximumReminders = 3

    /// How long a *running* recording has to see no movement before the app
    /// suggests pausing it.
    ///
    /// Deliberately longer than most stops. A lunch, a summit photo and a
    /// boot re-lace are all normal parts of a walk and none of them wants a
    /// notification; a quarter of an hour without moving is a rest the walker
    /// might genuinely rather have out of their moving average.
    static let stillFor: TimeInterval = 15 * 60

    /// The loosest fix the watch will measure a displacement with.
    ///
    /// A significant-location-change delivery can report accuracy in the
    /// hundreds of metres, and a displacement measured between two of those is
    /// not evidence of anything. Sized so a fix can be worse than the coarse
    /// watch asks for and still be usable, while one that cannot tell
    /// ``awayMeters`` from standing still is dropped.
    static let maximumFixAccuracy = 200.0
}

/// One paused subject's movement since it was paused.
///
/// Fed a distance from the anchor rather than a position, which is what lets
/// a recording (straight-line metres from the pause coordinate) and a followed
/// trail (metres along the route from where the walk was paused) share one
/// state machine and one set of thresholds.
///
/// A value type with no clock of its own: every decision is a function of what
/// it has been told, which is what makes the whole policy reachable from a
/// test without waiting out a quarter of an hour.
nonisolated struct MovementWatch: Equatable, Sendable {
    private struct Sample: Equatable, Sendable {
        let awayMeters: Double
        let at: Date
    }

    /// The reading the distance rule measures from. Starts at the anchor and
    /// moves to wherever the walker was each time a reminder is sent, so a
    /// second reminder means another ``MovementReminderPolicy/awayMeters``
    /// rather than the same ones being counted again.
    private var baselineMeters = 0.0
    /// The readings still inside the pace window. Never more than a handful:
    /// a paused recording is watched at a hundred-metre filter at best, and
    /// anything older than the window is dropped on the next observation.
    private var samples: [Sample] = []
    private(set) var remindersSent = 0
    private(set) var lastReminderAt: Date?

    /// Whether this pause has already said everything it is allowed to say.
    var isSpent: Bool {
        remindersSent >= MovementReminderPolicy.maximumReminders
    }

    /// Records how far from the anchor the walker now is.
    ///
    /// - Returns: whether this reading is reason to remind them now. Sending
    ///   the reminder is the caller's job; consuming the allowance is this
    ///   type's, which is why a `true` is returned exactly once per crossing.
    mutating func observe(awayMeters: Double, at date: Date) -> Bool {
        samples.removeAll { sample in
            date.timeIntervalSince(sample.at) > MovementReminderPolicy.paceWindow
        }
        // Read before the new reading joins them, so the burst below is
        // measured across the window rather than against itself.
        let oldest = samples.first
        samples.append(Sample(awayMeters: awayMeters, at: date))
        guard !isSpent else { return false }
        if let lastReminderAt,
           date.timeIntervalSince(lastReminderAt) < MovementReminderPolicy.quietFor {
            return false
        }
        let travelled = awayMeters - baselineMeters
        let burst = oldest.map { awayMeters - $0.awayMeters } ?? 0
        guard travelled >= MovementReminderPolicy.awayMeters
            || burst >= MovementReminderPolicy.paceMeters else { return false }
        remindersSent += 1
        lastReminderAt = date
        baselineMeters = awayMeters
        // The window belongs to the burst that has just been spent; keeping it
        // would let the same two hundred and fifty metres argue for the next
        // reminder as well.
        samples.removeAll()
        return true
    }
}

/// A *running* recording's stillness, which is the mirror of the watch above.
///
/// Fed the accumulator's own answer rather than a second opinion about
/// displacement: ``RecordingDistanceAccumulator/isStationary`` is already what
/// the recording screen, the energy policy and the saved distance are decided
/// by, and a stillness rule of its own here would be a fourth answer to a
/// question the app has settled three times.
nonisolated struct StillnessWatch: Equatable, Sendable {
    private var stillSince: Date?
    private var hasReminded = false

    /// - Returns: whether the walker should be asked whether they meant to
    ///   stop. Once per stop: moving again rearms it, and nothing else does.
    mutating func observe(isStationary: Bool, at date: Date) -> Bool {
        guard isStationary else {
            stillSince = nil
            hasReminded = false
            return false
        }
        let since = stillSince ?? date
        stillSince = since
        guard !hasReminded,
              date.timeIntervalSince(since) >= MovementReminderPolicy.stillFor else { return false }
        hasReminded = true
        return true
    }
}
