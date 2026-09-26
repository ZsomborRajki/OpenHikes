//
//  PhoneLink.swift
//  OpenHikesWatch
//
//  The watch's half of the `WCSession` link, and the only place this target
//  touches WatchConnectivity.
//
//  ## What crosses, and by which door
//
//  `WCSession` offers several, and they are not interchangeable:
//
//  * **The library digest** arrives as the *application context*, which is
//    latest-wins and delivered whenever the watch next wakes. That is exactly
//    what a list of trails is: there is one current answer, an older one is
//    worthless, and nobody needs the ones in between.
//  * **A trail request** goes out as a user-info transfer, so tapping a trail
//    out of range is a request that arrives later rather than a tap that does
//    nothing. A newer one replaces any still queued, and each names the
//    revision already held so an unchanged trail is not sent twice.
//  * **The trail package** comes back as a user-info transfer. It is tens of
//    kilobytes, which is past what an interactive message is for, and it must
//    survive the app being backgrounded while it crosses.
//  * **The phone's own recording** arrives as a message and is dropped when
//    it cannot be delivered, which is the right shape for the one payload
//    here that is only meaningful *now*: a reading queued while the watch app
//    was closed would describe a recording that has since moved on.
//  * **A button for the phone's recorder** goes out as a message with a reply
//    handler and has no transfer fallback. A fact delivered late is still a
//    fact; a button delivered late is a hike that starts ten minutes after
//    the hiker gave up. Out of range, the watch says so and disables them.
//  * **A finished walk** goes out as a user-info transfer and nothing else.
//    `transferUserInfo` queues to disk in the system's own container and keeps
//    trying across relaunches and reboots, which is the only guarantee worth
//    having for the one payload that exists nowhere else. See ``WatchStore``
//    for the half of that promise this app keeps itself, and
//    ``WatchWalkDelivery`` for when a walk the phone has not acknowledged is
//    offered again.
//
//  ## Isolation
//
//  Every `WCSessionDelegate` callback is `nonisolated` and arrives on a
//  background queue. Each one decodes to a `Sendable` value *before* hopping,
//  which is the rule the repository instructions set for the app's own
//  delegates and is what keeps a `[String: Any]` — which is not `Sendable` —
//  from ever crossing an isolation boundary.
//

import Foundation
import OpenHikesShared
import os
import WatchConnectivity

/// What the link hands back to the model, already decoded.
enum PhoneDelivery: Sendable {
    /// The phone's answer to a button, carrying the state that resulted and
    /// the refusal sentence if there was one.
    case commandOutcome(WatchCommandOutcome)
    case library(WatchLibraryDigest)
    /// What the phone's own recorder is doing, pushed or answered.
    case phoneRecording(WatchPhoneRecording)
    /// The link's own state changed — reachability, or an activation that
    /// finished. Carried so the model can drain its queue the moment a phone
    /// comes back rather than on a timer.
    case reachabilityChanged(Bool)
    case trail(WatchTrailPackage)
    case walkKept(UUID)
}

/// The watch's `WCSession`.
@MainActor
@Observable
final class PhoneLink: NSObject {
    nonisolated private static let logger = Logger(subsystem: "OpenHikesWatch", category: "PhoneLink")

    /// Whether the phone can be spoken to *right now*. Not the same as paired:
    /// a phone in a rucksack is paired and unreachable, which is the ordinary
    /// state on a walk and the reason nothing here waits for it.
    private(set) var isReachable = false
    /// Whether there is a phone at all. `false` on a watch whose companion app
    /// has been deleted, which is worth saying differently from "out of range"
    /// — one is waiting, the other is never.
    private(set) var isCompanionInstalled = true

    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private var onDelivery: (@MainActor (PhoneDelivery) -> Void)?
    /// Which finished walks are crossing, and when an unacknowledged one is
    /// due another offer.
    ///
    /// ``WatchStore``'s queue is what a walk lives on until the *phone* says
    /// it has it, so it is still there on every drain — and a drain runs on
    /// every reachability change, which on a walk is a phone going in and out
    /// of a rucksack all afternoon. This is what stops each one handing the
    /// same multi-thousand-fix transfer to the system again beside the copy
    /// already crossing, while still letting a walk the phone refused, or
    /// whose transfer failed, be offered again. See ``WatchWalkDelivery``.
    @ObservationIgnored private var delivery = WatchWalkDelivery()

    /// Starts the session.
    ///
    /// - Parameter onDelivery: where decoded payloads go. Handed in rather
    ///   than published as state, because these are events rather than values:
    ///   a digest that arrived twice must be applied twice, and an
    ///   `@Observable` property would collapse the second one.
    func activate(onDelivery: @escaping @MainActor (PhoneDelivery) -> Void) {
        guard WCSession.isSupported() else {
            // Not reachable on any watch that runs this app, and not something
            // to crash over if it ever is.
            Self.logger.error("WCSession is unsupported on this device")
            return
        }
        self.onDelivery = onDelivery
        let shared = WCSession.default
        session = shared
        shared.delegate = self
        shared.activate()
    }

    /// Asks the phone for a trail's geometry.
    ///
    /// `transferUserInfo` rather than `sendMessage`, even with the phone
    /// reachable. The interactive door is a second or two faster and buys
    /// nothing here: what comes back is a package of tens of kilobytes that
    /// has to cross as a transfer either way, and `sendMessage` fails outright
    /// the moment the phone goes out of range — which on a walk is most of the
    /// time. Queued, tapping a trail out of range is a trail that arrives
    /// later rather than a button that did nothing.
    ///
    /// - Parameter held: the trail this watch already has, which may be a
    ///   different one. Named in the request so the phone can stay silent
    ///   when the route has not changed — see ``WatchTrailRequest/heldRevision``.
    func requestTrail(_ hikeID: UUID, holding held: WatchTrailPackage?) {
        // Latest wins, the way it does for the library. The watch holds one
        // trail, so a request still queued from an earlier tap asks for
        // something that will be replaced the moment it lands — and a hiker
        // who opened the same trail five times out of range would otherwise
        // be answered five times with the same package when the phone is back.
        for outstanding in session?.outstandingUserInfoTransfers ?? []
        where WatchLink.kind(of: outstanding.userInfo) == .trailRequest {
            outstanding.cancel()
        }
        transfer { try WatchLink.message(WatchTrailRequest(hikeID: hikeID, holding: held)) }
    }

    /// Sends a finished walk. Guaranteed delivery, and the receipt is what
    /// takes it off ``WatchStore``'s queue.
    ///
    /// A no-op for a walk already crossing, or one that went unacknowledged
    /// too recently to be worth the whole payload again.
    func send(_ walk: WatchRecordedWalk) {
        let sessionID = walk.sessionID
        // The first offer in this process may find the last one's transfer
        // still queued: `WCSession` keeps it across the relaunch this set
        // did not survive. Adopted rather than duplicated, and its finish
        // arrives here like any other.
        if delivery.hasNeverOffered(sessionID), isCrossing(sessionID) {
            delivery.handedOver(sessionID)
            return
        }
        guard delivery.shouldOffer(sessionID, at: .now) else { return }
        // Marked only once the system has actually taken it. A build that
        // threw was never handed over, and a walk recorded as crossing on
        // the strength of an attempt that failed would sit on the disk queue
        // unoffered until the app was relaunched.
        guard transfer({ try WatchLink.message(walk) }) else { return }
        delivery.handedOver(sessionID)
    }

    /// Forgets that a walk was ever sent.
    ///
    /// Called when the phone's receipt takes it off the disk queue — at which
    /// point nothing will offer it again anyway — and that is the point: the
    /// record is bounded by what is genuinely still waiting rather than
    /// growing for the life of the process.
    func forget(_ sessionID: UUID) {
        delivery.receiptArrived(sessionID)
    }

    /// Whether `WCSession` still holds a transfer of this walk.
    ///
    /// Decodes each queued walk to read its ID, which is why it is asked once
    /// per walk per process rather than on every drain.
    private func isCrossing(_ sessionID: UUID) -> Bool {
        guard let session else { return false }
        return session.outstandingUserInfoTransfers.contains { pending in
            WatchLink.kind(of: pending.userInfo) == .recordedWalk
                && (try? WatchLink.recordedWalk(from: pending.userInfo))?.sessionID == sessionID
        }
    }

    /// `WCSession` is done with a walk's transfer, delivered or not, and no
    /// receipt has taken it off the queue. See ``WatchWalkDelivery`` for why
    /// both wait out the same growing delay.
    private func walkTransferFinished(_ sessionID: UUID) {
        delivery.transferFinished(sessionID, at: .now)
    }

    /// Asks the phone for the library, for a watch that has not been sent one.
    ///
    /// `transferUserInfo` rather than `sendMessage`, because the moment this
    /// is needed most is a first launch where the phone may not be reachable
    /// yet — a message would fail outright, a transfer waits. The answer comes
    /// back as an ordinary application context, so nothing here has to match a
    /// reply to a request.
    ///
    /// At most one at a time. ``WatchModel/askForLibraryIfEmpty()`` asks at
    /// launch, on every reachability change and every time the app comes to
    /// the front, and the case it exists for is exactly the one where no
    /// answer arrives — a companion that is gone, or a phone that is never
    /// brought near. `transferUserInfo` keeps what it is handed across
    /// relaunches and reboots, so without this a watch in that state builds
    /// an unbounded pile of identical requests that all arrive at once the
    /// day a phone finally appears. One outstanding request already says
    /// everything a second would.
    func requestLibrary() {
        guard !hasOutstandingLibraryRequest else { return }
        transfer { try WatchLink.message(WatchLibraryRequest()) }
    }

    /// Whether a library request is already sitting in `WCSession`'s queue.
    private var hasOutstandingLibraryRequest: Bool {
        guard let session else { return false }
        return session.outstandingUserInfoTransfers.contains { pending in
            WatchLink.kind(of: pending.userInfo) == .libraryRequest
        }
    }

    /// Presses a button on the phone's recorder.
    ///
    /// No transfer fallback, deliberately — see this file's header. A command
    /// that cannot be delivered now is reported as refused rather than queued,
    /// because the honest answer to "start a hike on a phone that is not
    /// there" is that it did not happen.
    func send(_ command: WatchRecordingCommand) {
        guard let session, session.isReachable else {
            deliverRefusal(of: command, saying: "Your iPhone is out of range.")
            return
        }
        let encoded: [String: Any]
        do {
            encoded = try WatchLink.message(command)
        } catch {
            Self.logger.error("A command could not be encoded: \(error.localizedDescription, privacy: .public)")
            deliverRefusal(of: command, saying: "That didn't reach your iPhone.")
            return
        }
        session.sendMessage(encoded) { [weak self] reply in
            // The reply arrives on a background queue and is decoded there,
            // for the reason every delivery below is: `[String: Any]` is not
            // `Sendable` and must not cross to the main actor.
            guard let outcome = try? WatchLink.commandOutcome(from: reply) else {
                // The phone answers with an *empty* dictionary on every path
                // it cannot encode an outcome on, precisely so this watch is
                // not left waiting — so a reply that will not decode has to
                // end the wait here too. Dropped, it would leave
                // `pendingCommand` set and every button disabled until
                // reachability moved.
                onMainActor { self?.deliverRefusal(of: command, saying: "Your iPhone couldn't answer that.") }
                return
            }
            onMainActor { self?.onDelivery?(.commandOutcome(outcome)) }
        } errorHandler: { [weak self] error in
            Self.logger.debug("A command failed: \(error.localizedDescription, privacy: .public)")
            onMainActor { self?.deliverRefusal(of: command, saying: "That didn't reach your iPhone.") }
        }
    }

    /// Answers a command the watch could not send, in the shape the phone
    /// would have answered in.
    ///
    /// One path out for every failure, so the screen has exactly one thing to
    /// handle: an outcome always arrives, and it always carries a state.
    private func deliverRefusal(of command: WatchRecordingCommand, saying reason: String) {
        onDelivery?(
            .commandOutcome(
                WatchCommandOutcome(
                    commandID: command.id,
                    // Idle rather than a guess: the watch cannot see the
                    // phone, so it must not claim to know what its recorder
                    // is doing.
                    recording: .idle(),
                    refusal: reason
                )
            )
        )
    }

    /// Sends whatever `build` encodes, or logs why nothing went.
    ///
    /// Encoding fails only on a non-finite `Double` — a receiver that reported
    /// `nan` — which is worth a log and is not worth a crash. Written as one
    /// function that both encodes *and* transfers rather than as one that
    /// hands an optional dictionary back, because there is nothing a caller
    /// could do with the `nil` except this.
    ///
    /// Answers whether the system took it, which is what ``send(_:)`` needs to
    /// decide whether a walk is genuinely crossing: `false` for a session
    /// that was never started and for a payload that could not be encoded,
    /// which are the two ways nothing went.
    @discardableResult private func transfer(_ build: () throws -> [String: Any]) -> Bool {
        guard let session else { return false }
        do {
            session.transferUserInfo(try build())
            return true
        } catch {
            Self.logger.error(
                "A message to the phone could not be encoded: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

/// `nonisolated` on the extension rather than on the members, which is the
/// spelling the repository instructions require: with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` an unannotated extension is a
/// main-actor context, and the two toolchains disagree about what that means
/// for what is nested inside one.
nonisolated extension PhoneLink: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            Self.logger.error("Session activation failed: \(error.localizedDescription, privacy: .public)")
        }
        let reachable = session.isReachable
        let installed = session.isCompanionAppInstalled
        onMainActor { [weak self] in
            self?.isReachable = reachable
            self?.isCompanionInstalled = installed
            self?.onDelivery?(.reachabilityChanged(reachable))
        }
        // The context that was already waiting, which nothing else will ever
        // hand us. `didReceiveApplicationContext` reports a *change*, and the
        // ordinary first launch has none to report: the phone published its
        // library while this app did not yet exist, so the newest context is
        // sitting in `receivedApplicationContext` and the delegate stays
        // silent. Without this the watch says "open OpenHikes on your iPhone"
        // at a phone that is open, until something on it publishes again.
        let waiting = session.receivedApplicationContext
        if !waiting.isEmpty { deliver(waiting) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        onMainActor { [weak self] in
            self?.isReachable = reachable
            self?.onDelivery?(.reachabilityChanged(reachable))
        }
    }

    /// A walk's transfer ended. Delivered is not kept: the phone may have
    /// refused to save it, which it says by withholding the receipt, so this
    /// only ends the transfer and never touches the disk queue.
    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        let userInfo = userInfoTransfer.userInfo
        guard WatchLink.kind(of: userInfo) == .recordedWalk,
              let sessionID = (try? WatchLink.recordedWalk(from: userInfo))?.sessionID else { return }
        if let error {
            Self.logger.error("A walk's transfer failed: \(error.localizedDescription, privacy: .public)")
        }
        onMainActor { [weak self] in self?.walkTransferFinished(sessionID) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        deliver(context)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        deliver(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        deliver(userInfo)
    }

    /// Decodes on the delivering queue and hands a `Sendable` value across.
    ///
    /// The decode is deliberately on *this* side of the hop: `[String: Any]`
    /// is not `Sendable`, so carrying one to the main actor is the thing Swift
    /// 6 will not allow and the thing that would be wrong anyway.
    private func deliver(_ message: [String: Any]) {
        guard let kind = WatchLink.kind(of: message) else {
            Self.logger.debug("A message arrived with no kind this build knows")
            return
        }
        do {
            switch kind {
            case .libraryRequest:
                // Watch → phone, and this is the watch. Its own request
                // coming back would mean the phone had echoed it.
                Self.logger.debug("A library request arrived at the watch, which is where they are sent from")
            case .libraryDigest:
                let digest = try WatchLink.libraryDigest(from: message)
                onMainActor { [weak self] in self?.onDelivery?(.library(digest)) }
            case .trailPackage:
                let package = try WatchLink.trailPackage(from: message)
                onMainActor { [weak self] in self?.onDelivery?(.trail(package)) }
            case .walkReceipt:
                let receipt = try WatchLink.walkReceipt(from: message)
                onMainActor { [weak self] in self?.onDelivery?(.walkKept(receipt.sessionID)) }
            case .phoneRecording:
                let recording = try WatchLink.phoneRecording(from: message)
                onMainActor { [weak self] in self?.onDelivery?(.phoneRecording(recording)) }
            case .commandOutcome:
                let outcome = try WatchLink.commandOutcome(from: message)
                onMainActor { [weak self] in self?.onDelivery?(.commandOutcome(outcome)) }
            case .recordingCommand, .recordedWalk, .trailRequest:
                // The watch's own outgoing kinds. Arriving here means the
                // phone echoed one back, which nothing does; ignoring it is
                // the whole of the correct response.
                Self.logger.debug(
                    "Ignoring \(kind.rawValue, privacy: .public), which the watch sends rather than receives"
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
