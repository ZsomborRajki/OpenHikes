//
//  WatchConnectivityBridge.swift
//  OpenTrails
//
//  Phone-side push of the current trail snapshot to a paired Watch. Owned
//  internally by BackgroundTrailTracker — nothing else needs to know this
//  exists. iOS-only: WatchConnectivity doesn't exist on macOS/visionOS, and
//  this app builds for both, so this type (and its call sites) must still
//  compile cleanly there — see the stub in the `#else` branch below.
//

import Foundation
import OpenTrailsShared

#if os(iOS)
import WatchConnectivity

@MainActor
final class WatchConnectivityBridge: NSObject {
    private let session: WCSession? = WCSession.isSupported() ? .default : nil

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    /// Pushes the current trail state to the Watch, or clears it when
    /// `snapshot` is `nil` (no trail selected). Best-effort: silently does
    /// nothing without a paired Watch that has the app installed.
    func send(_ snapshot: SharedTrailSnapshot?) {
        guard let session, session.activationState == .activated, session.isWatchAppInstalled else { return }

        var context: [String: Any] = [:]
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            context = ["snapshot": data]
        }
        try? session.updateApplicationContext(context)

        // Gives complication-relevant updates elevated background-wake
        // priority on the Watch side, on top of the context update above.
        // Skipped when there's no active complication to wake, or a transfer
        // is already in flight.
        if session.isComplicationEnabled, session.outstandingUserInfoTransfers.isEmpty {
            session.transferCurrentComplicationUserInfo(context)
        }
    }
}

extension WatchConnectivityBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}

#else

/// No-op stub so `BackgroundTrailTracker`'s call sites don't need to spread
/// `#if os(iOS)` through their own logic.
@MainActor
final class WatchConnectivityBridge {
    func send(_ snapshot: SharedTrailSnapshot?) {}
}

#endif
