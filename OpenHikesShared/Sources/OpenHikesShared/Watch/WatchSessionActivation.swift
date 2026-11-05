//
//  WatchSessionActivation.swift
//  OpenHikesShared
//
//  When the phone may hand `WCSession` a transfer, and what waits until then:
//  the phone's half of what ``WatchLinkActivation`` is for the watch.
//
//  ## Why the phone has to wait too
//
//  `transferUserInfo` may only be called on a session that has activated, and
//  everything the phone sends that way — a trail package, a walk's receipt —
//  is the end of an asynchronous job: a route read off the store, an import
//  saved. Neither knows what the session is doing by the time it finishes
//  (issue #1306).
//
//  On iOS that is not only a launch's problem. A session that has activated
//  can stop being usable: when the hiker switches to another paired watch it
//  becomes inactive, then deactivated, and only a second `activate()` brings
//  it back, for the watch now selected. A package or a receipt that finishes
//  in between would be handed to a session that is taking nothing new.
//
//  ## What waits, and in what shape
//
//  * **A trail package** waits whole, and every one does, in the order they
//    were packaged — the same queue `WCSession` would have kept. Which answer
//    the watch wants is the watch's to say: it matches a package to the
//    request it made last (``WatchTrailSelection``), which the phone cannot
//    see, so keeping only the newest package could keep the one it drops.
//  * **A receipt** waits once per walk. A second receipt for the same walk
//    says nothing the first does not.
//
//  ## Two things say whether a transfer may go
//
//  What the delegate last reported, and the session's own state at that
//  moment. A switch moves the state before `sessionDidBecomeInactive` has
//  reached the main actor, so the state alone says no in that window. The
//  report alone says no for the moment after an activation completes and
//  before its answer has released what waited for it, so nothing sent then
//  overtakes what was held.
//
//  ## How it ends
//
//  An activation that succeeds lets everything go, once. One that fails, or
//  a switch, lets nothing go and keeps what it holds for the next activation
//  that succeeds. After a switch that is the watch now selected, which is the
//  one the hiker is wearing. A receipt for the other watch's walk is one this
//  watch has no walk for, and the watch that does offers it again when it is
//  back: the import is idempotent, so that walk earns a second receipt. A
//  package is the trail the hiker last opened on the other watch, and the new
//  watch takes it in place of the trail it holds, unless it has opened or
//  received a trail of its own since it launched
//  (``WatchTrailSelection/accepts(_:replacing:)``).
//
//  ## Why it is here
//
//  `WatchSessionCoordinator` holds a `WCSession`, which a hosted test cannot
//  drive through activation or a switch. It keeps one of these, asks it
//  before every transfer and tells it how the session moved, so the decision
//  runs under `swift test`.
//

import Foundation

/// Whether the phone's session can take a transfer, and what waits for it.
public struct WatchSessionActivation: Equatable, Sendable {
    /// What a successful activation lets go. Send it in this order.
    public struct Release: Equatable, Sendable {
        /// Every package that could not be sent, oldest first.
        public let packages: [WatchTrailPackage]
        /// One receipt per walk that could not be acknowledged, oldest first.
        public let receipts: [WatchWalkReceipt]
    }

    /// Whether the last thing the session reported is that it activated.
    /// False before the first answer, after a failed one, and from the
    /// moment a switch to another watch begins until it has activated again.
    private var isActivated = false
    private var heldPackages: [WatchTrailPackage] = []
    private var heldReceipts: [WatchWalkReceipt] = []

    public init() {
        // Not activated: nothing may cross and nothing is waiting yet.
    }

    /// Whether `transferUserInfo` may be called now.
    ///
    /// - Parameter sessionActivated: whether the session's own
    ///   `activationState` is `.activated` at this moment. When it is not and
    ///   the delegate has not said so yet, a switch has begun: the transfer
    ///   is held, ``becameInactive()`` follows, and the activation that ends
    ///   the switch lets it go.
    public func allowsTransfers(sessionActivated: Bool) -> Bool {
        isActivated && sessionActivated
    }

    /// Keeps a trail package for the next activation, behind any already
    /// held.
    public mutating func hold(_ package: WatchTrailPackage) {
        heldPackages.append(package)
    }

    /// Keeps a walk's receipt for the next activation, unless one for the
    /// same walk is already waiting.
    public mutating func hold(_ receipt: WatchWalkReceipt) {
        guard !heldReceipts.contains(where: { $0.sessionID == receipt.sessionID }) else { return }
        heldReceipts.append(receipt)
    }

    /// The session became inactive, which on iOS is the start of a switch
    /// to another watch. What is held stays held, and so does anything that
    /// arrives until the session has activated again.
    public mutating func becameInactive() {
        isActivated = false
    }

    /// The session answered `activate()`, at launch or at the end of a
    /// switch.
    ///
    /// - Parameter activated: whether the session's state is `.activated`.
    ///   `.inactive` is a state the session cannot transfer in either.
    /// - Returns: what to send now, or `nil` if this answer opened nothing:
    ///   a failure, or a repeat of the success that already released
    ///   everything.
    public mutating func finished(activated: Bool) -> Release? {
        guard activated else {
            isActivated = false
            return nil
        }
        guard !isActivated else { return nil }
        isActivated = true
        defer {
            heldPackages = []
            heldReceipts = []
        }
        return Release(packages: heldPackages, receipts: heldReceipts)
    }
}
