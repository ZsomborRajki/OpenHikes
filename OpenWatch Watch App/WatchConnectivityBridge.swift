//
//  WatchConnectivityBridge.swift
//  OpenWatch Watch App
//
//  Receives the trail snapshot pushed from the iPhone (see the phone-side
//  file of the same name in OpenTrails/Managers/), writes it into this
//  Watch's own local App Group container — shared with OpenWatchWidgetExtension,
//  and physically separate from the iPhone's App Group container even though
//  both use the same group identifier — and republishes it locally so
//  TrailWatchView updates live while open.
//

import Foundation
import WidgetKit
import WatchConnectivity
import Observation
import OpenTrailsShared

@MainActor
@Observable
final class WatchConnectivityBridge: NSObject {
    private(set) var snapshot: SharedTrailSnapshot?

    private let session: WCSession? = WCSession.isSupported() ? .default : nil

    override init() {
        super.init()
        snapshot = SharedStore.load()
        session?.delegate = self
        session?.activate()
    }

    private func apply(_ payload: [String: Any]) {
        guard let data = payload["snapshot"] as? Data,
              let decoded = try? JSONDecoder().decode(SharedTrailSnapshot.self, from: data) else {
            snapshot = nil
            SharedStore.clear()
            WidgetCenter.shared.reloadTimelines(ofKind: TrailWidgetKind.id)
            return
        }
        snapshot = decoded
        SharedStore.save(decoded)
        WidgetCenter.shared.reloadTimelines(ofKind: TrailWidgetKind.id)
    }
}

extension WatchConnectivityBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in
            // Covers "the phone already sent a snapshot before this launch" —
            // `receivedApplicationContext` holds the latest delivery
            // regardless of whether this delegate was listening when it arrived.
            apply(session.receivedApplicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in apply(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in apply(userInfo) }
    }
}
