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
//  * Mirrors *this phone's* recording to the watch and performs the buttons
//    the watch sends back, both through ``WatchRecordingMirror``.
//
//  ## What it deliberately does not do
//
//  The last of those is the phone→watch direction, and it is the only
//  direction in which a recording is shared. A watch recording is never
//  mirrored here: it is the watch's from the first fix to the last, and the
//  phone learns about it as a finished track. ``WatchRecordedWalk``'s header
//  argues why, and ``WatchPhoneRecording``'s argues why the reverse is safe —
//  the short of it is that going this way there is still exactly one
//  authority, `HikeRecorder`, and the watch is a fourth surface on it rather
//  than a fourth answer beside it.
//
//  Nothing here reaches that recorder directly. Every read and every command
//  goes through `HikeIntentCoordinator`, which is what the Control Center
//  toggle and every Siri phrase already go through.
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

/// `WCSession`'s reply handler, carried to the main actor.
///
/// The handler is `([String: Any]) -> Void` and `[String: Any]` is not
/// `Sendable`, so the closure is not either and cannot cross an isolation
/// boundary on its own — while the work that produces the answer is the
/// recorder's and is main-actor by definition. This is the same box
/// `SystemHikeActivityPresenter` puts an `Activity` in for the same reason,
/// and it is safe on the same grounds: `WCSession` documents the handler as
/// callable from any queue, and every path through ``WatchSessionCoordinator``
/// calls it exactly once.
///
/// `nonisolated` on the struct is load-bearing, not decoration:
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would otherwise make the box
/// itself main-actor isolated and unable to leave.
nonisolated struct ReplyBox: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func send(_ message: [String: Any]) { handler(message) }
}

@MainActor
@Observable
final class WatchSessionCoordinator: NSObject {
    nonisolated private static let logger = Logger(subsystem: "OpenHikes", category: "WatchLink")

    /// Whether a watch is paired and has OpenHikes on it. Read by Settings, so
    /// a hiker can tell "no watch" from "watch that has not synced yet".
    private(set) var isWatchAppInstalled = false

    @ObservationIgnored private let container: ModelContainer
    /// The phone's recording, as the watch sees and drives it. Built lazily
    /// because it needs the intent coordinator, which is registered after
    /// this object exists — see ``register(_:)``.
    @ObservationIgnored private var mirror: WatchRecordingMirror?
    /// The seam a fresh reading of the library is taken through, kept for
    /// ``republishLibrary()``. Weak for the reason ``WatchRecordingMirror``
    /// holds it weakly: it is registered with `AppDependencyManager` and this
    /// object must not be what keeps it alive.
    @ObservationIgnored private weak var intents: HikeIntentCoordinator?

    /// Walks whose import is in flight, by the session they came from.
    ///
    /// ``WatchWalkImport``'s ledger recognises a repeat that arrives *after*
    /// the first was saved; this is what recognises one that arrives while it
    /// is still being saved. `transferUserInfo` can deliver the same walk
    /// twice — a lost receipt is the ordinary cause — and two arrivals land as
    /// two tasks that would both fetch before either inserted.
    @ObservationIgnored private var importsInFlight: Set<UUID> = []

    #if canImport(WatchConnectivity)
    @ObservationIgnored private var session: WCSession?
    /// The library that arrived before the session could take one.
    ///
    /// `updateApplicationContext` is refused until activation has completed,
    /// and the one sweep that publishes runs from `OpenHikesApp.init` — before
    /// `activate()` has even been called, let alone finished. Without this the
    /// watch's list would miss the launch that produced it, and there is no
    /// second sweep behind it.
    @ObservationIgnored private var pendingCatalogue: SharedHikeCatalogue?
    #endif

    init(container: ModelContainer) {
        self.container = container
        super.init()
    }

    /// Hands over the seam a watch's buttons reach the recorder through.
    ///
    /// Separate from `init` because the two are built at different moments:
    /// this object is the model's and the coordinator is assembled in
    /// `OpenHikesApp.init` from the model's own recorder. Until this is
    /// called the watch can still fetch trails and send walks; what it cannot
    /// do is see or drive a recording, which is the correct behaviour for a
    /// launch that has not registered one — a hosted test bundle's, for
    /// instance.
    func register(_ coordinator: HikeIntentCoordinator) {
        intents = coordinator
        mirror = WatchRecordingMirror(coordinator: coordinator) { [weak self] recording in
            self?.send(recording)
        }
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
        guard let session, session.activationState == .activated else {
            pendingCatalogue = catalogue
            return
        }
        pendingCatalogue = nil
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
        guard importsInFlight.insert(walk.sessionID).inserted else {
            Self.logger.debug("A walk from the watch arrived while the same one was still being saved")
            return
        }
        Task { [container] in
            let outcome = await WatchWalkImport.store(walk, in: container)
            importsInFlight.remove(walk.sessionID)
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
    /// A fresh *sweep* rather than a re-read of the App Group's copy, which is
    /// the difference between this working and this being a no-op:
    /// `SharedHikeCataloguePublisher` has exactly one caller, at launch, so
    /// the file on disk is by construction the library as it stood *before*
    /// the walk that just arrived. Sending it again would send the same list
    /// without the new hike in it, and the watch would not see the walk it
    /// had recorded until the phone was launched again.
    ///
    /// Still one reading feeding both consumers, which is the property that
    /// argument was really about: the sweep writes the App Group's copy and
    /// hands the watch the same list, so the widget's picker and the watch
    /// cannot disagree.
    ///
    /// Silent when nothing has registered an intent coordinator — a launch
    /// that cannot read the library is one where nothing was saved either.
    private func republishLibrary() async {
        guard let coordinator = intents else { return }
        // Detached for the reason the publisher's own entry point is: the
        // sweep encodes the library and writes the App Group's file, and a
        // `nonisolated async` call made from here would run on *this* actor
        // under approachable concurrency — which is the main one.
        await Task.detached(priority: .utility) { [weak self] in
            await SharedHikeCataloguePublisher.publishCatalogue(from: coordinator, watch: self)
        }.value
    }

    /// Publishes the library that arrived before the session was activated.
    ///
    /// Silent when there is none, and harmless when activation failed:
    /// ``publish(_:)`` simply holds it again.
    private func flushPendingCatalogue() {
        #if canImport(WatchConnectivity)
        guard let pending = pendingCatalogue else { return }
        pendingCatalogue = nil
        publish(pending)
        #endif
    }

    private func send(_ package: WatchTrailPackage) {
        transfer { try WatchLink.message(package) }
    }

    private func send(_ receipt: WatchWalkReceipt) {
        transfer { try WatchLink.message(receipt) }
    }

    /// Performs a command and replies with what happened.
    ///
    /// An empty reply on any failure rather than none at all: the watch has
    /// disabled the button it pressed until an answer arrives, and a reply
    /// handler that is never called leaves it that way until the system times
    /// it out.
    private func answer(_ command: WatchRecordingCommand, through reply: ReplyBox) {
        guard let mirror else {
            reply.send([:])
            return
        }
        Task {
            let outcome = await mirror.perform(command)
            do {
                reply.send(try WatchLink.message(outcome))
            } catch {
                Self.logger.error(
                    "A command outcome could not be encoded: \(error.localizedDescription, privacy: .public)"
                )
                reply.send([:])
            }
        }
    }

    /// Pushes a recording reading to the watch.
    ///
    /// `sendMessage` rather than a transfer, and dropped outright when the
    /// watch is not reachable. This is the one payload here that is *only*
    /// meaningful now: a reading queued while the watch app was closed would
    /// arrive describing a recording that has since moved on, and the watch
    /// has nothing to draw it on anyway. The mirror only runs while the watch
    /// is reachable for the same reason.
    private func send(_ recording: WatchPhoneRecording) {
        #if canImport(WatchConnectivity)
        guard let session, session.isReachable else { return }
        do {
            session.sendMessage(try WatchLink.message(recording), replyHandler: nil) { error in
                Self.logger.debug(
                    "A recording reading did not reach the watch: \(error.localizedDescription, privacy: .public)"
                )
            }
        } catch {
            Self.logger.error(
                "A recording reading could not be encoded: \(error.localizedDescription, privacy: .public)"
            )
        }
        #endif
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
        let reachable = session.isReachable
        onMainActor { [weak self] in
            guard let self else { return }
            isWatchAppInstalled = installed
            // This is the first moment either of the next two can work.
            // `publish(_:)` was called from `OpenHikesApp.init` before
            // `activate()` was, so it had nothing to send through; and the
            // mirror is otherwise started only by a *change* of reachability,
            // which a watch app already in the foreground when this process
            // launched never produces.
            flushPendingCatalogue()
            mirror?.reachabilityChanged(to: reachable)
        }
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

    /// On iOS this says the watch app is in the *foreground*, which is exactly
    /// the window in which mirroring a recording is worth anything.
    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        onMainActor { [weak self] in self?.mirror?.reachabilityChanged(to: reachable) }
    }

    /// A message that expects an answer, which is only ever a command.
    ///
    /// Commands take this door and nothing else — no transfer fallback. A
    /// *fact* delivered late is still a fact; a **button** delivered late is a
    /// hike that starts ten minutes after the hiker gave up and put their
    /// watch down. When the phone is out of range the watch says so and
    /// disables the buttons, which is the honest answer.
    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard WatchLink.kind(of: message) == .recordingCommand else {
            deliver(message)
            replyHandler([:])
            return
        }
        let reply = ReplyBox(replyHandler)
        do {
            let command = try WatchLink.recordingCommand(from: message)
            onMainActor { [weak self] in
                guard let self else {
                    reply.send([:])
                    return
                }
                answer(command, through: reply)
            }
        } catch {
            Self.logger.error(
                """
                A command from the watch was refused: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            reply.send([:])
        }
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
            case .recordingCommand:
                // Handled by the reply-taking door above, which is the only
                // one a command may arrive through. Reaching here means the
                // watch sent one without a reply handler, and performing it
                // would leave the watch with no answer.
                Self.logger.debug("A recordingCommand arrived without a reply handler and was ignored")
            case .commandOutcome, .libraryDigest, .phoneRecording, .trailPackage, .walkReceipt:
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
