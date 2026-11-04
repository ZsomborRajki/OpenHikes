//
//  WatchLinkActivation.swift
//  OpenHikesShared
//
//  When the watch may hand `WCSession` a transfer, and what waits until then.
//
//  ## Why a launch has to wait
//
//  `WCSession.activate()` returns at once and reports through its delegate
//  some time later, and `transferUserInfo` may only be called on a session
//  that has activated: Apple calls anything else a programmer error. A launch
//  does not wait of its own accord. `WatchModel` asks for the library the
//  moment it has called `activate()`, and a queue read that came back quickly
//  would hand over a finished walk and record it as crossing when nothing was
//  (issue #1277).
//
//  ## What waits, and in what shape
//
//  * **A library request** is a flag, because a second one says nothing the
//    first does not.
//  * **A trail request** is the latest one, as it is in `WCSession`'s own
//    queue. It is kept whole, because an answer is matched on its identity —
//    see ``WatchTrailSelection``.
//  * **A finished walk** does not wait here at all. It is already on the disk
//    queue, which outlives this process, so all it needs is not to be marked:
//    ``WatchWalkDelivery/offer(_:at:on:isCrossing:transfer:)`` turns it away,
//    it stays never offered, and the drain that follows activation finds it
//    due.
//
//  ## How it ends
//
//  An activation that succeeds opens the gate and lets the requests go, once.
//  One that fails lets nothing go and keeps what it was holding, so a retry
//  has the same work to release. Only `activationDidCompleteWith` ends the
//  wait, and watchOS has neither of the callbacks that take a session back
//  down, so the gate stays open from then on.
//
//  ## Why it is here
//
//  The watch has no test bundle. `PhoneLink` keeps one of these, asks it before
//  every transfer and tells it how activation ended, so the whole decision
//  runs on the host.
//

import Foundation

/// Whether the session has finished activating, and the requests waiting for it.
public struct WatchLinkActivation: Equatable, Sendable {
    private enum Stage: Equatable, Sendable {
        /// `activate()` has not been called: a launch before ``begin()``, or
        /// a device with no session to activate.
        case notStarted
        /// `activate()` has been called and the delegate has not answered.
        case activating
        case activated
        /// The delegate answered with anything but activated.
        case failed
    }

    /// What a successful activation lets go, which is the moment to drain the
    /// walk queue too.
    public struct Release: Equatable, Sendable {
        /// Whether something asked for the library while it could not be sent.
        public let asksForLibrary: Bool
        /// The latest trail request that could not be sent. Send it unchanged.
        public let trailRequest: WatchTrailRequest?
    }

    private var stage = Stage.notStarted
    private var isLibraryRequestHeld = false
    private var heldTrailRequest: WatchTrailRequest?

    public init() {
        // Not started: nothing may cross and nothing is waiting yet.
    }

    /// Whether `transferUserInfo` may be called.
    public var allowsTransfers: Bool { stage == .activated }

    /// Whether to call `activate()`, which is once to start and once after
    /// each failure. A call while one is in flight would only add a second
    /// answer to wait for, and one that has activated has nothing to gain.
    public mutating func begin() -> Bool {
        switch stage {
        case .notStarted, .failed:
            stage = .activating
            return true
        case .activating, .activated:
            return false
        }
    }

    /// Keeps a library request for the activation callback.
    public mutating func holdLibraryRequest() {
        isLibraryRequestHeld = true
    }

    /// Keeps a trail request for the activation callback, in place of any
    /// earlier one. The watch holds one trail, so an earlier request asks for
    /// something the later one has already replaced.
    public mutating func hold(_ request: WatchTrailRequest) {
        heldTrailRequest = request
    }

    /// The delegate answered.
    ///
    /// - Parameter activated: whether the session's state is `.activated`.
    ///   `.inactive` is a state the session cannot transfer in either.
    /// - Returns: what to send now and that the queue is to be drained, or
    ///   `nil` if this answer opened nothing: a failure, or a repeat of the
    ///   success that already released everything.
    public mutating func finished(activated: Bool) -> Release? {
        guard activated else {
            stage = .failed
            return nil
        }
        guard stage != .activated else { return nil }
        stage = .activated
        defer {
            isLibraryRequestHeld = false
            heldTrailRequest = nil
        }
        return Release(asksForLibrary: isLibraryRequestHeld, trailRequest: heldTrailRequest)
    }
}
