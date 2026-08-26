//
//  MapEntitlementStore.swift
//  OpenHikes
//
//  The StoreKit half of the Pro unlock: loads the product, resolves the
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
    /// The `.yearly` suffix is deliberate even though there is only one plan.
    /// Adding a monthly option later means a second product in the same
    /// subscription group, and a bare `.maps` would by then be the wrong name
    /// for one of them — while being the one string that cannot be renamed.
    static let productID = "tappium.com.OpenHikes.pro.maps.yearly"

    enum PurchaseOutcome: Equatable {
        case purchased
        case cancelled
        /// Ask-to-buy, or a payment awaiting approval. The entitlement will
        /// arrive through ``updates`` if it is ever approved.
        case pending
        case failed(String)
    }

    private(set) var state: MapEntitlementState = .unknown
    private(set) var product: Product?
    /// The offer in the words the paywall shows, or `nil` until the product
    /// has loaded. Built once per load, since intro-offer eligibility is an
    /// `await` and a SwiftUI body cannot make one.
    private(set) var terms: MapSubscriptionTerms?
    /// Set while a purchase or restore is in flight, so the paywall can
    /// disable its buttons rather than let a second tap start a second one.
    private(set) var isWorking = false

    var isEntitled: Bool { state == .entitled }

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
    private static let logger = Logger(subsystem: "com.openhikes", category: "Purchases")

    /// Injectable so a suite can drive the store without StoreKit. The default
    /// reads the real one.
    private let currentEntitlements: @Sendable () async -> Bool

    init(
        currentEntitlements: @escaping @Sendable () async -> Bool = {
            await MapEntitlementStore.hasProEntitlement()
        }
    ) {
        self.currentEntitlements = currentEntitlements
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
        Task { await loadProduct() }
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

    func loadProduct() async {
        do {
            let loaded = try await Product.products(for: [Self.productID]).first
            product = loaded
            terms = await Self.terms(for: loaded)
        } catch {
            // Not fatal and not surfaced: the paywall falls back to describing
            // the unlock without a price rather than showing an error for a
            // screen the user may only be browsing.
            Self.logger.error(
                "Couldn't load the Pro product: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func purchase() async -> PurchaseOutcome {
        guard let product else { return .failed("The store is unavailable right now.") }
        guard !isWorking else { return .cancelled }
        isWorking = true
        defer { isWorking = false }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard let transaction = Self.verified(verification) else {
                    return .failed("That purchase couldn’t be verified.")
                }
                await transaction.finish()
                publish(.entitled)
                return .purchased
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed("That purchase couldn’t be completed.")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Restores on a new device. `AppStore.sync()` prompts for a password, so
    /// it belongs behind an explicit button and not on launch — the launch
    /// path reads `currentEntitlements`, which needs no authentication.
    func restore() async -> Bool {
        guard !isWorking else { return isEntitled }
        isWorking = true
        defer { isWorking = false }
        do {
            try await AppStore.sync()
        } catch {
            Self.logger.error(
                "Restore failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        await refresh()
        return isEntitled
    }

    private func handle(_ update: VerificationResult<Transaction>) async {
        guard let transaction = Self.verified(update) else { return }
        await transaction.finish()
        await refresh()
    }

    /// Writes to the observable half and the process-wide half together, so a
    /// view and the tile pipeline can never be looking at different answers.
    private func publish(_ newValue: MapEntitlementState) {
        state = newValue
        MapEntitlement.set(newValue)
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

    /// Translates the loaded product into the sentences the paywall shows.
    ///
    /// Returns `nil` for a product with no subscription info, which in a
    /// correct build means the App Store served something that is not this
    /// subscription. The paywall then describes the unlock without quoting a
    /// price, rather than inventing one.
    private static func terms(for product: Product?) async -> MapSubscriptionTerms? {
        guard let product, let subscription = product.subscription else { return nil }
        guard let unit = SubscriptionPeriodUnit(subscription.subscriptionPeriod.unit) else {
            return nil
        }
        return MapSubscriptionTerms(
            price: product.displayPrice,
            period: MapSubscriptionTerms.periodNoun(
                unit: unit,
                count: subscription.subscriptionPeriod.value
            ),
            freeTrial: await freeTrial(in: subscription)
        )
    }

    /// The trial's length, or `nil` when this account cannot have it.
    ///
    /// `isEligibleForIntroOffer` is the whole point of the check: eligibility
    /// is spent once per subscription group per Apple Account and never comes
    /// back, so a lapsed subscriber returning to this screen would otherwise
    /// be offered a free week that the App Store will refuse to give them.
    private static func freeTrial(in subscription: Product.SubscriptionInfo) async -> String? {
        guard let offer = subscription.introductoryOffer,
              offer.paymentMode == .freeTrial,
              let unit = SubscriptionPeriodUnit(offer.period.unit),
              await subscription.isEligibleForIntroOffer
        else { return nil }
        return MapSubscriptionTerms.durationPhrase(unit: unit, count: offer.period.value)
    }
}

private extension SubscriptionPeriodUnit {
    /// Fails only on a unit added to StoreKit after this was written, which
    /// the caller turns into "describe the unlock without a period" rather
    /// than a guess.
    init?(_ unit: Product.SubscriptionPeriod.Unit) {
        switch unit {
        case .day: self = .day
        case .month: self = .month
        case .week: self = .week
        case .year: self = .year
        @unknown default: return nil
        }
    }
}
