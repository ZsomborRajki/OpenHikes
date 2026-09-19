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
//  * **A trail request** goes out as a message when the phone is reachable and
//    as a user-info transfer when it is not, so tapping a trail out of range
//    is a request that arrives later rather than a tap that does nothing.
//  * **The trail package** comes back as a user-info transfer. It is tens of
//    kilobytes, which is past what an interactive message is for, and it must
//    survive the app being backgrounded while it crosses.
//  * **A finished walk** goes out as a user-info transfer and nothing else.
//    `transferUserInfo` queues to disk in the system's own container and keeps
//    trying across relaunches and reboots, which is the only guarantee worth
//    having for the one payload that exists nowhere else. See ``WatchStore``
//    for the half of that promise this app keeps itself.
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
    case library(WatchLibraryDigest)
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
    func requestTrail(_ hikeID: UUID) {
        transfer { try WatchLink.message(WatchTrailRequest(hikeID: hikeID)) }
    }

    /// Sends a finished walk. Guaranteed delivery, and the receipt is what
    /// takes it off ``WatchStore``'s queue.
    func send(_ walk: WatchRecordedWalk) {
        transfer { try WatchLink.message(walk) }
    }

    /// Sends whatever `build` encodes, or logs why nothing went.
    ///
    /// Encoding fails only on a non-finite `Double` — a receiver that reported
    /// `nan` — which is worth a log and is not worth a crash. Written as one
    /// function that both encodes *and* transfers rather than as one that
    /// hands an optional dictionary back, because there is nothing a caller
    /// could do with the `nil` except this.
    private func transfer(_ build: () throws -> [String: Any]) {
        guard let session else { return }
        do {
            session.transferUserInfo(try build())
        } catch {
            Self.logger.error(
                "A message to the phone could not be encoded: \(error.localizedDescription, privacy: .public)"
            )
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
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        onMainActor { [weak self] in
            self?.isReachable = reachable
            self?.onDelivery?(.reachabilityChanged(reachable))
        }
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
            case .libraryDigest:
                let digest = try WatchLink.libraryDigest(from: message)
                onMainActor { [weak self] in self?.onDelivery?(.library(digest)) }
            case .trailPackage:
                let package = try WatchLink.trailPackage(from: message)
                onMainActor { [weak self] in self?.onDelivery?(.trail(package)) }
            case .walkReceipt:
                let receipt = try WatchLink.walkReceipt(from: message)
                onMainActor { [weak self] in self?.onDelivery?(.walkKept(receipt.sessionID)) }
            case .trailRequest, .recordedWalk:
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
