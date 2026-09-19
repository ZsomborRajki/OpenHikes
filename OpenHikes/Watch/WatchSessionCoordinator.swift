//
//  WatchSessionCoordinator.swift
//  OpenHikes
//
//  The phone's half of the watch link, and the only place this target touches
//  WatchConnectivity.
//
//  ## What it does
//
//  Three things, and deliberately no more:
//
//  * Publishes the hiker's library as the session's *application context*, so
//    a watch that wakes up out of range still has a list of trails. Latest
//    wins, which is what a list of trails is.
//  * Answers a ``WatchTrailRequest`` with the trail's geometry.
//  * Takes a ``WatchRecordedWalk`` and keeps it, then sends a receipt so the
//    watch can let go of it.
//
//  ## What it deliberately does not do
//
//  It does not know that a recording exists. `HikeRecorder` is the single
//  authority on whether *this phone* is recording, and a watch recording is
//  not this phone's — see ``WatchRecordedWalk``'s header for why there is one
//  owner per recording rather than a shared phase. Nothing here reads the
//  recorder, and nothing here can start or stop one.
//
//  It also holds no `ModelContext`. Everything it writes goes through
//  ``WatchWalkImport``, off the main actor, against a context built and
//  discarded inside one call — the shape the repository instructions require
//  of anything touching the store from a delegate.
//
//  ## Isolation
//
//  Every `WCSessionDelegate` callback is `nonisolated` and arrives on a
//  background queue. Each decodes to a `Sendable` value before hopping, which
//  is what keeps a `[String: Any]` — not `Sendable` — from crossing an
//  isolation boundary.
//

import Foundation
import OpenHikesShared
import os
import SwiftData
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

@MainActor
@Observable
final class WatchSessionCoordinator: NSObject {
    nonisolated private static let logger = Logger(subsystem: "OpenHikes", category: "WatchLink")

    /// Whether a watch is paired and has OpenHikes on it. Read by Settings, so
    /// a hiker can tell "no watch" from "watch that has not synced yet".
    private(set) var isWatchAppInstalled = false

    @ObservationIgnored private let container: ModelContainer

    #if canImport(WatchConnectivity)
    @ObservationIgnored private var session: WCSession?
    #endif

    init(container: ModelContainer) {
        self.container = container
        super.init()
    }

    /// Starts the session, if this device can have one.
    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
        #endif
    }

    /// Publishes the library to whatever watch is paired.
    ///
    /// The *application context* rather than a transfer, because there is one
    /// current answer and the ones in between are worthless — the same
    /// argument `SharedStore.saveHikeCatalogue` makes for replacing the App
    /// Group's copy wholesale rather than writing per change.
    ///
    /// Silent on failure, like the catalogue sweep it rides beside: nothing a
    /// hiker does depends on this having worked this second, and the next
    /// sweep puts it right.
    func publish(_ catalogue: SharedHikeCatalogue) {
        #if canImport(WatchConnectivity)
        guard let session, session.activationState == .activated else { return }
        let digest = WatchLibraryDigest(
            hikes: Array(catalogue.hikes.prefix(WatchLibraryDigest.hikeBudget))
        )
        do {
            try session.updateApplicationContext(WatchLink.message(digest))
        } catch {
            Self.logger.debug(
                "The watch library could not be published: \(error.localizedDescription, privacy: .public)"
            )
        }
        #endif
    }

    // MARK: Answering the watch

    private func sendTrail(_ hikeID: UUID) {
        Task { [container] in
            let input = await MainActor.run { () -> WatchTrailPackaging.Input? in
                let context = ModelContext(container)
                var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
                descriptor.fetchLimit = 1
                // A hike deleted since the watch's list was published. Nothing
                // to send and nothing to report: the watch draws its waiting
                // state, and the next digest takes the row off its list.
                guard let hike = try? context.fetch(descriptor).first else { return nil }
                return WatchTrailPackaging.Input(hike: hike)
            }
            guard let input, let package = await WatchTrailPackaging.package(from: input) else { return }
            await MainActor.run { self.send(package) }
        }
    }

    private func keep(_ walk: WatchRecordedWalk) {
        Task { [container] in
            let outcome = await WatchWalkImport.store(walk, in: container)
            guard outcome.deservesReceipt else {
                Self.logger.error(
                    "A walk from the watch was refused; no receipt sent, so the watch keeps it"
                )
                return
            }
            await MainActor.run { self.send(WatchWalkReceipt(sessionID: walk.sessionID)) }
            // The library the watch holds now names a trail it does not have.
            // Republishing is what closes that, and is cheap: it is a list of
            // at most fifty rows replacing a list of at most fifty rows.
            await republishLibrary()
        }
    }

    /// Republishes the catalogue after this coordinator changed the library.
    ///
    /// Reads the App Group's own copy rather than the store, because
    /// `SharedHikeCataloguePublisher` has already written one and two
    /// independent readings of the same library is how the two come to
    /// disagree. The publisher's sweep runs at launch and is what fills it.
    private func republishLibrary() async {
        // Off the main actor: this is a file read, and the caller is a
        // delegate's task rather than anything on screen.
        let catalogue = await Task.detached(priority: .utility) {
            SharedStore.loadHikeCatalogue()
        }.value
        publish(catalogue)
    }

    private func send(_ package: WatchTrailPackage) {
        transfer { try WatchLink.message(package) }
    }

    private func send(_ receipt: WatchWalkReceipt) {
        transfer { try WatchLink.message(receipt) }
    }

    /// `transferUserInfo` for everything the phone sends back.
    ///
    /// Queued to the system's own container and retried across relaunches,
    /// which both of these need: a package is tens of kilobytes, and a receipt
    /// that never arrives leaves the watch holding a walk forever.
    ///
    /// Encoding fails only on a non-finite `Double` — a route carrying a `nan`
    /// latitude — which is worth a log and is not worth a crash.
    private func transfer(_ build: () throws -> [String: Any]) {
        #if canImport(WatchConnectivity)
        guard let session else { return }
        do {
            session.transferUserInfo(try build())
        } catch {
            Self.logger.error(
                "A message to the watch could not be encoded: \(error.localizedDescription, privacy: .public)"
            )
        }
        #endif
    }
}

#if canImport(WatchConnectivity)
/// `nonisolated` on the extension rather than on the members, which is the
/// spelling the repository instructions require under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated extension WatchSessionCoordinator: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            Self.logger.error("Watch session activation failed: \(error.localizedDescription, privacy: .public)")
        }
        let installed = session.isWatchAppInstalled
        onMainActor { [weak self] in self?.isWatchAppInstalled = installed }
    }

    /// Required on iOS, where a session can be handed to a different watch.
    ///
    /// Reactivated rather than left dormant: the paired watch is a new device
    /// with none of this hiker's trails on it, and a session nobody
    /// reactivated is a watch that stays empty forever.
    func sessionDidBecomeInactive(_ session: WCSession) {
        // Nothing to tear down: this type holds no per-watch state, and the
        // reactivation below is what matters.
    }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        let installed = session.isWatchAppInstalled
        onMainActor { [weak self] in self?.isWatchAppInstalled = installed }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        deliver(userInfo)
    }

    /// Decodes on the delivering queue and hands a `Sendable` value across.
    private func deliver(_ message: [String: Any]) {
        guard let kind = WatchLink.kind(of: message) else {
            Self.logger.debug("A message from the watch carried no kind this build knows")
            return
        }
        do {
            switch kind {
            case .trailRequest:
                let request = try WatchLink.trailRequest(from: message)
                onMainActor { [weak self] in self?.sendTrail(request.hikeID) }
            case .recordedWalk:
                let walk = try WatchLink.recordedWalk(from: message)
                onMainActor { [weak self] in self?.keep(walk) }
            case .libraryDigest, .trailPackage, .walkReceipt:
                // The phone's own outgoing kinds. Arriving here means the
                // watch echoed one back, which nothing does.
                Self.logger.debug(
                    "Ignoring \(kind.rawValue, privacy: .public), which the phone sends rather than receives"
                )
            }
        } catch {
            Self.logger.error(
                """
                A \(kind.rawValue, privacy: .public) message was refused: \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }
}
#endif
