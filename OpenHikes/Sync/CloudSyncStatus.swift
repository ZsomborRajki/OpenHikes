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
    /// Something went wrong that isn't going to fix itself by waiting — the
    /// transient failures (no signal, rate limiting, a busy zone) are retried
    /// by ``CKSyncEngine`` and never reach here.
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

    /// The headline the settings row shows.
    var title: String {
        switch account {
        case .available: activityTitle
        case .noAccount: "No Apple Account"
        case .restricted: "iCloud Restricted"
        case .unknown: "Checking iCloud…"
        }
    }

    /// The line underneath it. Always says something concrete: "why isn't this
    /// working" is the only question this section exists to answer.
    var detail: String {
        switch account {
        case .available:
            activityDetail
        case .noAccount:
            "Sign in to iCloud in the Settings app to sync your hikes across your devices."
        case .restricted:
            "This device's settings don't allow iCloud, so hikes stay on this device."
        case .unknown:
            "Asking iCloud whether it's available on this device."
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
                "Last synced \(date.formatted(date: .abbreviated, time: .shortened))."
            } ?? "Your hikes and photos are kept in your private iCloud storage."
        case .paused:
            "Your hikes stay on this device only."
        case .working:
            "Sending and receiving your hikes and photos."
        }
    }

    func began() {
        activity = .working
    }

    func finished() {
        activity = .idle
        lastSyncedAt = .now
    }

    func failed(_ reason: String) {
        activity = .failed(reason)
    }

    func paused() {
        activity = .paused
    }
}
