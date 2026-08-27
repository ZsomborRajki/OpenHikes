//
//  CloudSyncStatus.swift
//  OpenHikes
//
//  What the settings screen is allowed to say about sync, and the only place
//  that decides how to say it.
//
//  Separate from the engine because the engine is an `actor` — the delegate
//  protocol requires `Sendable` — and a SwiftUI body cannot await one. This is
//  the small, main-actor, observable surface it publishes into.
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
    /// Something went wrong that isn't going to fix itself by waiting.
    ///
    /// The transient failures — no signal, rate limiting, a busy zone — do
    /// reach ``CloudSyncCoordinator``; its `isWorthReporting(_:)` filter is
    /// what keeps them from reaching here. Mirroring retries those itself, so
    /// they are logged rather than turned into a headline nobody can act on.
    case failed(String)
    case idle
    /// Sync is off, or there is no Apple Account signed in on this device.
    case paused
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
    var pendingRelaunch = false

    /// Whether the pass currently running has raised anything.
    ///
    /// A pass is one mirroring event's start/end bracket. Without this,
    /// ``finished()`` had no way to tell a clean pass from one that failed a
    /// moment earlier, so every failure raised during an export was erased by
    /// the event immediately after it: "Sync Problem", its detail line and
    /// ``CloudSyncSection``'s warning icon were unreachable, and
    /// ``lastSyncedAt`` was stamped for passes that had just failed.
    private var passRaisedAFailure = false

    /// The headline the settings row shows.
    var title: String {
        if pendingRelaunch { return "Restart to Apply" }
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
        case .failed: "Sync Problem"
        case .idle: "Synced with iCloud"
        case .paused: "Sync Off"
        case .working: "Syncing…"
        }
    }

    private var activityDetail: String {
        switch activity {
        case .failed(let reason):
            reason
        case .idle:
            lastSyncedAt.map { date in
                "Last synced \(HikeFormat.timestamp(date))."
            } ?? "Your hikes and photos are kept in your private iCloud storage."
        case .paused:
            "Your hikes stay on this device only."
        case .working:
            "Sending and receiving your hikes and photos."
        }
    }

    /// Starts a pass. Clearing the flag here rather than in ``finished()`` is
    /// what lets a failure outlive the pass that raised it while still being
    /// cleared by the next attempt.
    func began() {
        passRaisedAFailure = false
        activity = .working
    }

    /// Ends a pass. One that raised something goes on saying so, and does not
    /// claim a sync time it did not earn.
    func finished() {
        guard !passRaisedAFailure else { return }
        activity = .idle
        lastSyncedAt = .now
    }

    func failed(_ reason: String) {
        passRaisedAFailure = true
        activity = .failed(reason)
    }

    func paused() {
        passRaisedAFailure = false
        activity = .paused
    }
}
