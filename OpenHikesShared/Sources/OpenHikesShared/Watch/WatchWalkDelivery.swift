//
//  WatchWalkDelivery.swift
//  OpenHikesShared
//
//  Whether the watch should offer a finished walk to the phone again.
//
//  ## Three different kinds of "not acknowledged"
//
//  A walk sits on the watch's disk queue until the phone's receipt takes it
//  off, and a drain offers everything on that queue. Between an offer and a
//  receipt the walk can be in one of three states, and they want three
//  different answers:
//
//  * **Still crossing.** `WCSession` holds the transfer and keeps trying on
//    its own. Offering it again queues a second copy of a multi-thousand-fix
//    payload beside the first — and a drain runs on every reachability change,
//    which on a walk is a phone going in and out of a rucksack all afternoon.
//    So: never.
//  * **The transfer failed.** Nothing is crossing and nothing will. Offering it
//    again is the only way it ever arrives.
//  * **Delivered, but no receipt came back.** The phone had it and either
//    refused to keep it — its save failed, and it withholds the receipt so the
//    watch keeps the only copy — or kept it and the receipt was lost. Either
//    way offering it again is safe, because the phone's import is keyed on the
//    walk's session ID, and it is the only way a phone that can save again
//    ever gets the walk.
//
//  The last two are retried, but not on every drain: a phone that refused a
//  walk a second ago will refuse it again, and each attempt is the whole
//  payload. Each attempt that ends without a receipt doubles the wait before
//  the next, from ``firstRetryDelay`` up to ``longestRetryDelay`` — bounded in
//  rate rather than in count, because a count that ran out would strand the
//  walk exactly as keeping it in flight forever did.
//
//  Kept in memory, deliberately. A relaunch loses what `WCSession` reported
//  too, and offering everything once after one is the retry the disk queue is
//  for.
//

import Foundation

/// The watch's record of the walks it has offered the phone in this process.
public struct WatchWalkDelivery: Sendable {
    /// How long after the first unacknowledged attempt the walk is offered
    /// again.
    public static let firstRetryDelay: TimeInterval = 60
    /// The longest a walk waits between attempts, however many have failed.
    public static let longestRetryDelay: TimeInterval = 30 * 60

    private enum Stage: Sendable {
        /// Handed to `WCSession`, which has not yet said how it went.
        case crossing
        /// Not crossing, not acknowledged, and not to be offered before this.
        case waiting(until: Date)
    }

    private struct Attempt: Sendable {
        var stage: Stage
        /// Attempts that ended without a receipt — the exponent of the wait.
        var unanswered: Int
    }

    private var attempts: [UUID: Attempt] = [:]

    public init() {
        // Nothing offered yet: every walk on the disk queue is due.
    }

    /// Whether a drain at `now` should hand this walk to `WCSession`.
    public func shouldOffer(_ sessionID: UUID, at now: Date) -> Bool {
        switch attempts[sessionID]?.stage {
        case nil: true
        case .crossing: false
        case .waiting(let until): now >= until
        }
    }

    /// Whether this process has never offered the walk. The one moment worth
    /// asking `WCSession` whether a previous process left it crossing.
    public func hasNeverOffered(_ sessionID: UUID) -> Bool {
        attempts[sessionID] == nil
    }

    /// Records that `WCSession` took the walk, whether from this process's
    /// offer or found still queued from an earlier one.
    public mutating func handedOver(_ sessionID: UUID) {
        attempts[sessionID, default: Attempt(stage: .crossing, unanswered: 0)].stage = .crossing
    }

    /// Records that `WCSession` finished with a transfer, delivered or not.
    ///
    /// Either way nothing is crossing any more and no receipt has arrived —
    /// a receipt that had would already have forgotten the walk — so both
    /// start the wait before the next attempt. A walk this process was not
    /// tracking is left alone: its receipt came first, or it was never ours.
    public mutating func transferFinished(_ sessionID: UUID, at now: Date) {
        guard var attempt = attempts[sessionID] else { return }
        attempt.unanswered += 1
        let delay = min(
            Self.firstRetryDelay * pow(2, Double(attempt.unanswered - 1)),
            Self.longestRetryDelay
        )
        attempt.stage = .waiting(until: now.addingTimeInterval(delay))
        attempts[sessionID] = attempt
    }

    /// Forgets the walk: the phone's receipt took it off the disk queue, so
    /// nothing will offer it again, and the record stays bounded by what is
    /// genuinely still waiting.
    public mutating func receiptArrived(_ sessionID: UUID) {
        attempts[sessionID] = nil
    }
}
