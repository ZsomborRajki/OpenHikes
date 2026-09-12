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
    /// underneath them on every launch. Selecting is stricter — see
    /// ``tapAction(for:)``, which is what keeps this window from being used to
    /// *choose* a paid source.
    func allows(_ provider: TileProvider) -> Bool {
        guard provider.requiresPaidAccess else { return true }
        return self != .notEntitled
    }

    /// What a tap on `provider`'s row in Settings should do.
    ///
    /// Stricter than ``allows(_:)`` in exactly one state, and that asymmetry is
    /// the point. Drawing a paid source through the unresolved window costs a
    /// handful of tiles and is undone the moment StoreKit answers; *selecting*
    /// one writes an id that outlives the window. ``SettingsKey/tileProviderID``
    /// is persisted and travels through iCloud, and ``TileProvider/renderable(id:entitlement:)``
    /// deliberately never rewrites it — so a tap taken before the answer
    /// arrives leaves a paid id on every device of a user who may never have
    /// been entitled to it.
    ///
    /// Three answers rather than a `Bool` because "not allowed" covers two
    /// different rows: one that has not been bought, where the tap has
    /// somewhere useful to go, and one whose entitlement has not resolved,
    /// where it has not.
    func tapAction(for provider: TileProvider) -> PaidFeatureTap {
        guard provider.requiresPaidAccess else { return .allow }
        return paidTap
    }

    /// What a tap on the community share button should do.
    ///
    /// The same three answers as a paid provider row, from the same property,
    /// because it is the same rule and not a second one that happens to agree:
    /// a lapsed subscriber and a subscriber StoreKit has not answered for yet
    /// are different people to a screen that has to decide what a tap does.
    ///
    /// It takes the **strict** reading of ``unknown`` for a reason of its own,
    /// and a heavier one than the provider row's. Selecting a map writes an id
    /// that can be written again; publishing hands a route, a set of
    /// photographs and a name to a public database that this app has no method
    /// to delete from — see ``CommunityTransporting``, which deliberately has
    /// no way to withdraw a submission. An action that cannot be taken back
    /// must not be taken on an entitlement nobody has confirmed.
    var publishTap: PaidFeatureTap { paidTap }

    /// The three-way answer for anything behind the Pro unlock, written once.
    private var paidTap: PaidFeatureTap {
        switch self {
        case .entitled: return .allow
        case .notEntitled: return .unlock
        case .unknown: return .wait
        }
    }

    /// Whether the answer is settled — the name for the window `unknown`
    /// stands for, which is what both halves of the gate above are shaped
    /// around and what the store's own suites assert against.
    var isResolved: Bool { self != .unknown }
}

/// What tapping something behind the Pro unlock should do.
///
/// Switched over exhaustively in ``MapEntitlementState/tapAction(for:)`` and
/// ``MapEntitlementState/publishTap``, so a fourth entitlement state cannot be
/// added without deciding what a tap on a paid control does while the app is
/// in it.
///
/// Not named for the map, though the map was its first caller: two features
/// are behind this subscription now — the commercial tile sources and
/// publishing a hike to the community — and one enum with one mapping is what
/// stops the second quietly disagreeing with the first about what the
/// unresolved window means.
nonisolated enum PaidFeatureTap: Equatable {
    /// Do the thing: persist the tapped provider, or open the share form.
    case allow
    /// Open the paywall: the feature is real and available, just not bought.
    case unlock
    /// Nothing, yet. StoreKit has not answered, so the control is disabled
    /// until it does rather than swallowing the tap and looking broken.
    case wait
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
