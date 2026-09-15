//
//  MapEntitlementStore.swift
//  OpenHikes
//
//  The StoreKit half of the Pro unlock: resolves the
//  current entitlement, listens for changes, and publishes each answer to
//  ``MapEntitlement`` so the off-main tile code sees the same one.
//
//  An auto-renewable subscription rather than a one-off, because what it buys
//  is a recurring cost: Stadia and Thunderforest bill OpenHikes every month
//  for as long as a customer keeps using their maps, and a single payment in
//  2026 does not pay for a map view in 2029.
//
//  That choice brings the two things a non-consumable does not have, and both
//  are handled here rather than left to the views. A subscription *lapses*,
//  and StoreKit raises no transaction when it does — see ``statusTask``. And
//  its introductory offer can be spent, so the trial is advertised only to an
//  account that can still take it.
//

import Foundation
import Observation
import OSLog
import StoreKit

/// Drives the paywall and the locked rows in Settings.
///
/// Main-actor isolated because everything it feeds is: the store is created
/// once by ``OpenHikesModel`` and read from SwiftUI bodies. The answer that
/// off-main code needs goes through ``MapEntitlement`` instead.
@MainActor
@Observable
final class MapEntitlementStore {
    /// The App Store product identifier for the Pro unlock.
    ///
    /// A persisted identifier in the sense the repository means it: it is
    /// recorded against every past purchase in the App Store, so it can never
    /// change without stranding every existing customer's entitlement. The
    /// same string appears in `OpenHikes.storekit` and in App Store Connect,
    /// and all three have to agree.
    ///
    /// The `.monthly` suffix is deliberate even though there is only one plan.
    /// Adding a yearly option later means a second product in the same
    /// subscription group, and a bare `.maps` would by then be the wrong name
    /// for one of them — while being the one string that cannot be renamed.
    ///
    /// The `.maps` in the middle is what the subscription unlocks today, and
    /// it stays whether or not that keeps being true: the identifier is
    /// recorded against every past purchase and is the one string here that can
    /// never be corrected. What a customer *reads* is not this — see
    /// ``MapPaywallView``'s title, which says "OpenHikes Pro".
    static let productID = "tappium.com.OpenHikes.pro.maps.monthly"

    /// What a tap on **Restore Purchases** turned out to be.
    ///
    /// A `Bool` cannot say this, and saying it wrongly is expensive. Restoring
    /// is two steps — `AppStore.sync()`, then a re-read of what this account
    /// owns — and only the *second* one can report an empty purchase history.
    /// Collapsing them meant an offline device, an unreachable App Store or a
    /// failed authentication all arrived at the paywall as "no previous
    /// purchase was found for this Apple Account", which told a paying
    /// customer to go and sign in to a different account over a dropped
    /// connection.
    ///
    /// The restore path exists to satisfy App Review's requirement that a
    /// restorable purchase be restorable, so it is a customer contract as much
    /// as a feature: reporting its failures accurately is part of honouring it.
    enum RestoreOutcome: Equatable {
        /// The sync landed and this Apple Account owns the subscription.
        case restored
        /// The sync landed and it does not. The only outcome entitled to say
        /// that nothing was found.
        case nothingToRestore
        /// The password prompt was dismissed, or a restore was already
        /// running. Says nothing to the user: they know what they just did.
        case cancelled
        /// The App Store could not be reached, or refused. The entitlement is
        /// left exactly as it was — a failure to *ask* is not an answer.
        case failed(String)
    }

    private(set) var state: MapEntitlementState = .unknown
    /// Set while a purchase or restore is in flight, so the paywall can
    /// disable its buttons rather than let a second tap start a second one.
    private(set) var isWorking = false

    var isEntitled: Bool { state == .entitled }

    /// Whether the paywall's Restore button is live.
    ///
    /// Deliberately *not* gated on the product. ``restore()`` reads what this
    /// Apple Account already owns, through `AppStore.sync()` and
    /// `currentEntitlements`, and never touches `product` — and a returning
    /// subscriber whose product query just failed is exactly the person who
    /// needs the button, so a failed load must not take it away.
    var canRestore: Bool { !isWorking }

    /// Never cancelled: the store is created once by ``OpenHikesModel`` and
    /// lives as long as the process, and a `deinit` cannot touch a main-actor
    /// property anyway. `guard updatesTask == nil` is what keeps ``start()``
    /// from opening a second one.
    private var updatesTask: Task<Void, Never>?
    /// The listener that a non-consumable did not need.
    ///
    /// `Transaction.updates` fires when a subscription *renews*, because a
    /// renewal is a new transaction — but nothing is issued when one expires,
    /// so an app watching only that sequence keeps showing paid maps to a
    /// lapsed subscriber until the next cold launch. Subscription status is
    /// the sequence that reports the end of a period, and
    /// ``sceneDidBecomeActive()`` is the backstop for a lapse that happened
    /// while the process was not running.
    private var statusTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "OpenHikes", category: "Purchases")

    /// Injectable so a suite can drive the store without StoreKit. The default
    /// reads the real one.
    private let currentEntitlements: @Sendable () async -> Bool
    /// The other half of that seam, and the one ``restore()`` is built on.
    ///
    /// `AppStore.sync()` never returns under `xcodebuild test` — observed
    /// still running after ten minutes — so a suite calling the real one would
    /// hang the whole hosted bundle rather than fail a single test. Behind
    /// this closure, every branch of ``restore()`` is reachable without an App
    /// Store: the throw is a thrown error, and the entitlement the sync would
    /// have revealed is whatever `currentEntitlements` is set to answer next.
    private let syncPurchases: @Sendable () async throws -> Void
    /// The third seam, for the same reason and one of its own.
    /// Where the last resolved answer is remembered across launches.
    private let defaults: UserDefaults

    /// Remembers the last answer, and starts from it when it was "no".
    ///
    /// Without this, *every* cold launch serves paid tiles to everybody until
    /// `currentEntitlements` returns — which on a cold start with poor
    /// connectivity is not instant, and which bills Stadia or Thunderforest
    /// against OpenHikes' own key for a user who never subscribed.
    ///
    /// Only the negative answer is acted on, and that asymmetry is the whole
    /// design. A remembered "entitled" leaves the state ``MapEntitlementState``
    /// starts in — `.unknown`, which already allows — so a subscriber's map is
    /// byte-for-byte what it was before this existed and never flickers. A
    /// remembered "not entitled" starts at `.notEntitled` instead, which draws
    /// the free source and locks the paid rows until StoreKit says otherwise;
    /// a row going from locked to *un*locked is not the transition Settings
    /// guards against. A device that has never launched has nothing remembered
    /// and stays permissive, which is one launch and cannot be closed without
    /// holding the map back on the App Store.
    ///
    /// Not a security control and not built as one. The tile keys ship in the
    /// binary, so the threat this addresses is accidental cost, not a
    /// determined attacker — which is also why a plain `UserDefaults` bool is
    /// the right weight for it.
    init(
        defaults: UserDefaults = .standard,
        currentEntitlements: @escaping @Sendable () async -> Bool = {
            await MapEntitlementStore.hasProEntitlement()
        },
        syncPurchases: @escaping @Sendable () async throws -> Void = {
            try await AppStore.sync()
        }
    ) {
        self.defaults = defaults
        self.currentEntitlements = currentEntitlements
        self.syncPurchases = syncPurchases
        if defaults.object(forKey: SettingsKey.lastKnownMapEntitlement) != nil,
           !defaults.bool(forKey: SettingsKey.lastKnownMapEntitlement) {
            publish(.notEntitled)
        }
    }

    /// Resolves the entitlement and begins listening for changes.
    ///
    /// Called once at launch. The listener is started *before* the first
    /// resolve, which is the order StoreKit documents: a transaction that
    /// arrives while the initial query is in flight — an interrupted purchase
    /// finishing, a family-sharing grant — would otherwise be missed until the
    /// next launch.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await handle(update)
            }
        }
        statusTask = Task { [weak self] in
            for await _ in Product.SubscriptionInfo.Status.updates {
                guard let self else { return }
                await refresh()
            }
        }
        Task { await refresh() }
    }

    /// Re-resolves on every foreground.
    ///
    /// A subscription can lapse while the app is not running, and can be
    /// cancelled or refunded entirely outside it — in the App Store, or on
    /// another device. Neither leaves anything for ``statusTask`` to receive
    /// in *this* process, so the entitlement is re-read whenever the app comes
    /// back. It is a cheap local query and does not prompt for a password.
    func sceneDidBecomeActive() {
        Task { await refresh() }
    }

    /// Re-reads the entitlement and publishes it.
    func refresh() async {
        let entitled = await currentEntitlements()
        publish(entitled ? .entitled : .notEntitled)
    }

    func restore() async -> RestoreOutcome {
        guard !isWorking else { return .cancelled }
        isWorking = true
        defer { isWorking = false }
        do {
            try await syncPurchases()
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch {
            Self.logger.error(
                "Restore failed: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        }
        await refresh()
        return isEntitled ? .restored : .nothingToRestore
    }

    private func handle(_ update: VerificationResult<Transaction>) async {
        guard let transaction = Self.verified(update) else { return }
        await transaction.finish()
        await refresh()
    }

    /// Writes to the observable half and the process-wide half together, so a
    /// view and the tile pipeline can never be looking at different answers —
    /// and remembers a resolved one for the next cold launch.
    ///
    /// `.unknown` is never written back: it is the absence of an answer, and
    /// overwriting a remembered one with it would reopen the window that
    /// ``init(defaults:currentEntitlements:)`` exists to close.
    private func publish(_ newValue: MapEntitlementState) {
        state = newValue
        MapEntitlement.set(newValue)
        switch newValue {
        case .entitled:
            defaults.set(true, forKey: SettingsKey.lastKnownMapEntitlement)
        case .notEntitled:
            defaults.set(false, forKey: SettingsKey.lastKnownMapEntitlement)
        case .unknown:
            break
        }
    }

    private static func verified(_ result: VerificationResult<Transaction>) -> Transaction? {
        guard case .verified(let transaction) = result else {
            Self.logger.error("Ignoring an unverified transaction")
            return nil
        }
        return transaction
    }

    private static func hasProEntitlement() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.productID == productID else { continue }
            guard transaction.revocationDate == nil else { continue }
            return true
        }
        return false
    }

}
