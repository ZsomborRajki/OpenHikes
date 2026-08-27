//
//  MapEntitlementStoreTests.swift
//  OpenHikesTests
//
//  The lifecycle of the one subsystem in this app that takes money: free →
//  subscribed → lapsed, and what each transition leaves behind for the next
//  cold launch to read.
//
//  Driven entirely through the injected `currentEntitlements` closure, which is
//  why that seam exists. Nothing here reaches StoreKit: `purchase()` and
//  `restore()` end in `Product.purchase()` and `AppStore.sync()`, neither of
//  which a hosted unit bundle can answer without a StoreKit test session, and a
//  test that waited on the real App Store would be measuring the network.
//
//  ``MapEntitlement`` is process-wide and shared with every other suite in this
//  bundle, so each test here restores it — see ``restoreProcessEntitlement()``.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@MainActor
@Suite("Map entitlement lifecycle", .serialized)
struct MapEntitlementStoreTests {
    /// Its own defaults suite per test: these assert on a persisted value, and
    /// the bundle runs against one `UserDefaults` otherwise.
    private static func defaults() throws -> UserDefaults {
        let name = "MapEntitlementStoreTests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    /// Puts the process-wide answer back to its launch value.
    ///
    /// Unlike ``MapEntitlementTests``, this suite cannot pass the entitlement
    /// as a parameter — publishing to the global *is* what it is testing — so
    /// it has to hand it back instead.
    private static func restoreProcessEntitlement() {
        MapEntitlement.resetForTesting()
    }

    private static func store(
        defaults: UserDefaults,
        entitled: @escaping @Sendable () async -> Bool
    ) -> MapEntitlementStore {
        MapEntitlementStore(defaults: defaults, currentEntitlements: entitled)
    }

    // MARK: - Resolution

    /// The launch window the three-state enum exists for: until StoreKit has
    /// answered on a device that has never asked, nothing is known and the paid
    /// maps draw.
    @Test("a store with nothing remembered starts unresolved")
    func startsUnknownWithNothingRemembered() throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()

        let store = Self.store(defaults: defaults) { true }

        #expect(store.state == .unknown)
        #expect(!store.isEntitled)
        #expect(
            defaults.object(forKey: SettingsKey.lastKnownMapEntitlement) == nil
        )
    }

    @Test("resolving a free account publishes and remembers the refusal")
    func refreshPublishesNotEntitled() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        let store = Self.store(defaults: defaults) { false }

        await store.refresh()

        #expect(store.state == .notEntitled)
        #expect(!store.isEntitled)
        #expect(MapEntitlement.current == .notEntitled)
        #expect(!defaults.bool(forKey: SettingsKey.lastKnownMapEntitlement))
    }

    @Test("resolving a subscriber publishes and remembers the grant")
    func refreshPublishesEntitled() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        let store = Self.store(defaults: defaults) { true }

        await store.refresh()

        #expect(store.state == .entitled)
        #expect(store.isEntitled)
        #expect(MapEntitlement.current == .entitled)
        #expect(defaults.bool(forKey: SettingsKey.lastKnownMapEntitlement))
    }

    // MARK: - The transition nothing covered

    /// Free → subscribed → lapsed, against one store, in the order a customer
    /// actually moves through it.
    ///
    /// The last leg is the one a non-consumable would not have: StoreKit raises
    /// no transaction when a subscription expires, so the downgrade can only
    /// arrive from a re-resolve. If this ever stops holding, a lapsed
    /// subscriber keeps the paid maps.
    @Test("a subscription that is bought and then lapses moves both ways")
    func freeThenSubscribedThenExpired() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        let entitled = Mutex(false)
        let store = Self.store(defaults: defaults) { entitled.withLock { $0 } }

        await store.refresh()
        #expect(store.state == .notEntitled)
        #expect(!defaults.bool(forKey: SettingsKey.lastKnownMapEntitlement))

        entitled.withLock { $0 = true }
        await store.refresh()
        #expect(store.state == .entitled)
        #expect(MapEntitlement.current == .entitled)
        #expect(defaults.bool(forKey: SettingsKey.lastKnownMapEntitlement))

        entitled.withLock { $0 = false }
        await store.refresh()
        #expect(store.state == .notEntitled)
        #expect(MapEntitlement.current == .notEntitled)
        #expect(!defaults.bool(forKey: SettingsKey.lastKnownMapEntitlement))
    }

    /// The backstop for a lapse that happened while the process was not
    /// running: nothing is delivered to a listener that did not exist, so
    /// coming back to the foreground has to ask again.
    @Test("returning to the foreground re-resolves the entitlement")
    func sceneDidBecomeActiveReResolves() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        let entitled = Mutex(true)
        let store = Self.store(defaults: defaults) { entitled.withLock { $0 } }

        await store.refresh()
        #expect(store.state == .entitled)

        entitled.withLock { $0 = false }
        store.sceneDidBecomeActive()
        await settleDelegateHop(until: "the foreground re-resolve to land") {
            store.state == .notEntitled
        }

        #expect(store.state == .notEntitled)
        #expect(MapEntitlement.current == .notEntitled)
    }

    // MARK: - What the next cold launch starts from

    /// The leak this remembering exists to close. Without it every launch
    /// serves billed Stadia and Thunderforest tiles to a user who has never
    /// subscribed, for as long as `currentEntitlements` takes to return.
    @Test("a remembered refusal is what the next launch starts from")
    func rememberedRefusalSeedsTheNextLaunch() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        await Self.store(defaults: defaults) { false }.refresh()
        Self.restoreProcessEntitlement()

        let relaunched = Self.store(defaults: defaults) { false }

        #expect(relaunched.state == .notEntitled)
        #expect(MapEntitlement.current == .notEntitled)
        #expect(!MapEntitlementState.notEntitled.allows(.stadiaOutdoors))
    }

    /// The other half of the asymmetry, and the reason it is one: a subscriber
    /// must start `.unknown` rather than `.entitled`, so that the *only*
    /// behaviour this feature can change is a refusal. `.unknown` already draws
    /// the paid map, so their launch is identical either way — and if the
    /// remembered grant were ever wrong, it could not outlive the resolve.
    @Test("a remembered grant leaves the next launch unresolved")
    func rememberedGrantLeavesTheNextLaunchUnknown() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        await Self.store(defaults: defaults) { true }.refresh()
        Self.restoreProcessEntitlement()

        let relaunched = Self.store(defaults: defaults) { true }

        #expect(relaunched.state == .unknown)
        #expect(!relaunched.state.isResolved)
        #expect(relaunched.state.allows(.stadiaOutdoors))
    }

    /// A device that resubscribes elsewhere still comes back: the remembered
    /// refusal decides only what is drawn before the answer arrives.
    @Test("a resolve overrides a remembered refusal")
    func resolveOverridesRememberedRefusal() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        defaults.set(false, forKey: SettingsKey.lastKnownMapEntitlement)

        let store = Self.store(defaults: defaults) { true }
        #expect(store.state == .notEntitled)

        await store.refresh()

        #expect(store.state == .entitled)
        #expect(MapEntitlement.current == .entitled)
        #expect(defaults.bool(forKey: SettingsKey.lastKnownMapEntitlement))
    }

    // MARK: - Purchase

    /// The paywall can be on screen before ``MapEntitlementStore/loadProduct()``
    /// has returned, and a tap in that window must not read as a failed
    /// purchase attempt against the account — or move the entitlement.
    @Test("buying before the product loads fails without changing anything")
    func purchaseWithoutAProductFails() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        let store = Self.store(defaults: defaults) { false }
        await store.refresh()

        let outcome = await store.purchase()

        guard case .failed = outcome else {
            Issue.record("Expected a failure with no product loaded, got \(outcome)")
            return
        }
        #expect(store.state == .notEntitled)
        #expect(!store.isWorking)
    }
}
