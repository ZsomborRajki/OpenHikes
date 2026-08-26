//
//  MapEntitlement.swift
//  OpenHikes
//
//  Whether this device may draw the two commercial tile sources, and the
//  process-wide answer that the off-main tile code reads.
//
//  Deliberately shaped like `Secrets`: a `nonisolated` lookup any thread can
//  ask, because the question "which map may we draw" is asked from
//  `AutoSaveController` and `OpenHikesModel` as well as from SwiftUI, and
//  those callers have no view environment to reach a store through. The
//  `@Observable` half — `MapEntitlementStore` — is what drives the UI; it
//  writes here so both halves can never disagree.
//

import Foundation
import Synchronization

/// What is known about the Pro unlock right now.
///
/// Three states rather than a `Bool`, and the third one is the whole point.
/// `Transaction.currentEntitlements` is asynchronous, so at cold launch the
/// app genuinely does not yet know. Answering "not entitled" during that
/// window would drop a paying user's map to OpenStreetMap and then swap it
/// back a moment later — a visible flash, a discarded tile overlay, and a
/// wasted round of fetches for tiles that were about to be replaced.
nonisolated enum MapEntitlementState: Sendable, Equatable {
    case entitled
    case notEntitled
    /// StoreKit has not answered yet. Treated as entitled, see ``allows(_:)``.
    case unknown

    /// Whether `provider` may be drawn.
    ///
    /// ``unknown`` allows. The cost of being briefly wrong in this direction is
    /// that a non-paying user sees a paid map until StoreKit answers, which
    /// takes a moment and costs a handful of tiles; the cost of being wrong in
    /// the other direction is that every paying user watches their map change
    /// underneath them on every launch. Settings resolves before it offers the
    /// choice, so this window cannot be used to *select* a paid source.
    func allows(_ provider: TileProvider) -> Bool {
        guard provider.requiresPaidAccess else { return true }
        return self != .notEntitled
    }

    /// Whether the answer is settled. Settings waits for this before deciding
    /// which rows to lock, so a row never flips from unlocked to locked under
    /// the user's finger.
    var isResolved: Bool { self != .unknown }
}

/// The process-wide entitlement, readable from any thread.
nonisolated enum MapEntitlement {
    private static let state = Mutex<MapEntitlementState>(.unknown)

    /// The current answer. Cheap: one uncontended lock acquisition, read on
    /// provider resolution rather than per tile.
    static var current: MapEntitlementState { state.withLock { $0 } }

    /// Publishes a newly resolved entitlement. Called by ``MapEntitlementStore``
    /// and by nothing else in the app — a second writer would make the two
    /// halves disagree, which is the one failure this indirection exists to
    /// prevent.
    static func set(_ newValue: MapEntitlementState) {
        state.withLock { $0 = newValue }
    }

    #if DEBUG
    /// Restores the launch state. Test-only: a suite that drives entitlement
    /// through the explicit `entitlement:` parameters never touches this, and
    /// should not — the global is shared by every suite in the process.
    static func resetForTesting() {
        set(.unknown)
    }
    #endif
}
