//
//  CloudSyncStatus.swift
//  OpenHikes
//
//  What the settings screen is allowed to say about sync, and the only place
//  that decides how to say it.
//
//  Separate from ``CloudSyncCoordinator`` because the two answer different
//  questions. The coordinator owns the container, the switch and the mirroring
//  observer; this owns the sentence. Splitting them is what lets the reducer
//  be driven straight from a test — see ``CloudSyncCoordinator/apply(_:)`` —
//  without a settings screen, and keeps every string the row can show in one
//  file.
//
//  Both are `@MainActor` and `@Observable`, and the coordinator holds this as
//  a plain `let`, so a SwiftUI body reads it directly with nothing to await.
//

import CloudKit
import Foundation
import Observation

/// Whether iCloud is usable at all, in the terms a person would recognise.
///
/// Deliberately not `CKAccountStatus` itself: two of its cases mean "ask again
/// later" and the screen has nothing useful to say about the difference.
nonisolated enum CloudAccountStatus: Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case unknown

    init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        default: self = .unknown
        }
    }

    var isUsable: Bool { self == .available }
}

/// What sync is doing right now.
nonisolated enum CloudSyncActivity: Equatable, Sendable {
    /// This launch's store was never built to mirror: the switch is off, or
    /// storage fell back to memory.
    ///
    /// Its own case rather than ``paused`` because of what it says about the
    /// account: nothing asked iCloud about one, and nothing is going to. A
    /// launch in this state is settled, so the row answers from here instead
    /// of waiting on a round-trip nobody started.
    case disabled
    /// Something went wrong that isn't going to fix itself by waiting.
    case failed(String)
    case idle
    /// There is no Apple Account this device can sync with.
    case paused
    /// A pass ended on a transient failure — no signal, rate limiting, a busy
    /// zone — that mirroring will retry on its own.
    ///
    /// Its own case rather than ``idle`` because the two differ in the only
    /// way that matters here: nothing was transferred. Folding it into
    /// ``idle`` put "Synced with iCloud" and a freshly stamped time on a pass
    /// that never left the device. It is deliberately not ``failed`` either —
    /// the retry is silent and succeeds on its own, so "Sync Problem" would
    /// be a headline nobody can act on and nothing would come along to clear.
    case retrying
    case working
}

@MainActor
@Observable
final class CloudSyncStatus {
    var account: CloudAccountStatus = .unknown
    var activity: CloudSyncActivity = .paused
    var lastSyncedAt: Date?

    /// Whether the user's switch and this launch's store disagree — see
    /// ``CloudSyncCoordinator/pendingRelaunch``.
    ///
    /// Outranks everything else the row could say. A store that is mirroring
    /// while the switch reads off is not "Synced with iCloud", and saying so
    /// would be the one sentence a person in that state would be right to call
    /// a lie.
    ///
    /// This is a state the app is designed to reach, not one it is waiting to
    /// stop reaching, so the strings below are the feature rather than a
    /// stopgap: the relaunch is what applies the switch, and the row is where
    /// a person finds that out.
    var pendingRelaunch = false

    /// What the pass currently running has raised, if anything.
    ///
    /// A pass is one mirroring event's start/end bracket. Without this,
    /// ``finished()`` had no way to tell a clean pass from one that failed a
    /// moment earlier, so every failure raised during an export was erased by
    /// the event immediately after it: "Sync Problem", its detail line and
    /// ``CloudSyncSection``'s warning icon were unreachable, and
    /// ``lastSyncedAt`` was stamped for passes that had just failed.
    ///
    /// Transient problems are held here too, for the same reason and with the
    /// same consequence: a pass the network cut short has not synced, so it
    /// must not stamp a time either.
    private var passProblem: PassProblem?

    /// The two kinds of thing a pass can raise, ranked. A permanent failure
    /// outranks a transient one within the same pass: the user can act on the
    /// first and there is nothing to act on in the second.
    private enum PassProblem {
        case transient
        case permanent
    }

    /// The headline the settings row shows.
    var title: String {
        if pendingRelaunch { return "Restart to Apply" }
        // Ahead of the account, which on a launch that does not mirror is
        // still `.unknown` and always will be: nothing asked iCloud about it,
        // and "Checking iCloud…" over a settled row is a wait that never ends.
        if activity == .disabled { return activityTitle }
        switch account {
        case .available: return activityTitle
        case .noAccount: return "No Apple Account"
        case .restricted: return "iCloud Restricted"
        case .unknown: return "Checking iCloud…"
        }
    }

    /// The line underneath it. Always says something concrete: "why isn't this
    /// working" is the only question this section exists to answer.
    var detail: String {
        if pendingRelaunch {
            return "Quit and reopen OpenHikes to finish changing this setting."
        }
        if activity == .disabled { return activityDetail }
        switch account {
        case .available:
            return activityDetail
        case .noAccount:
            return "Sign in to iCloud in the Settings app to sync your hikes across your devices."
        case .restricted:
            return "This device's settings don't allow iCloud, so hikes stay on this device."
        case .unknown:
            return "Asking iCloud whether it's available on this device."
        }
    }

    private var activityTitle: String {
        switch activity {
        case .disabled: "Sync Off"
        case .failed: "Sync Problem"
        case .idle: "Synced with iCloud"
        case .paused: "Sync Off"
        case .retrying: "Waiting for iCloud"
        case .working: "Syncing…"
        }
    }

    private var activityDetail: String {
        switch activity {
        case .disabled:
            "Your hikes stay on this device only."
        case .failed(let reason):
            reason
        case .idle:
            lastSyncedAt.map { date in
                "Last synced \(HikeFormat.timestamp(date))."
            } ?? "Your hikes and photos are kept in your private iCloud storage."
        case .paused:
            "Your hikes stay on this device only."
        case .retrying:
            lastSyncedAt.map { date in
                "iCloud can't be reached right now. This will finish on its own. "
                    + "Last synced \(HikeFormat.timestamp(date))."
            } ?? "iCloud can't be reached right now. This will finish on its own."
        case .working:
            "Sending and receiving your hikes and photos."
        }
    }

    /// Starts a pass. Clearing the flag here rather than in ``finished()`` is
    /// what lets a failure outlive the pass that raised it while still being
    /// cleared by the next attempt.
    func began() {
        passProblem = nil
        activity = .working
    }

    /// Ends a pass. One that raised something goes on saying so, and does not
    /// claim a sync time it did not earn.
    func finished() {
        guard passProblem == nil else { return }
        activity = .idle
        lastSyncedAt = .now
    }

    func failed(_ reason: String) {
        passProblem = .permanent
        activity = .failed(reason)
    }

    /// Records a transient failure: the pass is over, nothing was transferred,
    /// and mirroring will try again without being asked.
    func retrying() {
        guard passProblem != .permanent else { return }
        passProblem = .transient
        activity = .retrying
    }

    /// There is a usable account, mirroring is set up, and no event has
    /// arrived to say anything about it.
    ///
    /// The state the row opens in is ``CloudSyncActivity/paused``, and a quiet
    /// launch — everything already uploaded, nothing new to fetch — posts no
    /// mirroring event at all. Without an explicit transition here, a store
    /// that was mirroring perfectly well went on saying "Sync Off" until
    /// something happened to sync.
    ///
    /// Only ever moves a resting row forward: a pass in flight, or one that
    /// left a problem standing, has more to say than this does.
    func ready() {
        guard activity == .disabled || activity == .paused else { return }
        activity = .idle
    }

    /// Sync is off because this launch's store cannot mirror at all.
    ///
    /// See ``CloudSyncActivity/disabled`` for why that is not ``paused()``.
    func disabled() {
        passProblem = nil
        activity = .disabled
    }

    /// Sync is off because this device has no account it can use.
    func paused() {
        passProblem = nil
        activity = .paused
    }
}
