//
//  MapEntitlementStoreLaunchTests.swift
//  OpenHikesTests
//
//  What ``MapEntitlementStore/start()`` does the one time it is called.
//
//  ``MapEntitlementStoreTests`` drives `refresh()` directly and explains, in
//  its header, which parts of the store are unreachable from a hosted unit
//  bundle and why. This file covers the launch entry point that wraps it — the
//  listener guard that keeps a second `start()` from opening a second pair of
//  subscriptions.
//
//  ## Why every test here carries a time limit
//
//  These are the only tests in the bundle that touch StoreKit at all: `start()`
//  opens `Transaction.updates` and `Product.SubscriptionInfo.Status.updates`,
//  which are real framework sequences however thoroughly the rest is stubbed.
//  A StoreKit call with no store behind it is the shape that hangs rather than
//  returning, and a hang would take the whole host down — every other suite in
//  this one shared process with it — instead of failing one test. The limit
//  converts that into a normal failure. It is the same reason `GPXFuzzTests`
//  carries one, and the budget is deliberately enormous compared to what these
//  actually take: it is a backstop against a hang, not an assertion about
//  latency.
//
//  This suite was once reported as having crashed the host. It had not: the
//  same bundle was measured restarting just as often with this file deleted
//  outright, and the restarts were traced to several test hosts contending for
//  one shared simulator. On a dedicated device the full bundle runs green with
//  this file present. The limit stays anyway, because the reasoning above does
//  not depend on that report having been true.
//
//  ## One thing this suite cannot clean up after itself
//
//  `start()` opens a `Transaction.updates` and a
//  `Product.SubscriptionInfo.Status.updates` iterator that are deliberately
//  never cancelled — the store is a process-lifetime object owned by
//  ``OpenHikesModel`` and documents that choice. So a test that calls it
//  leaves two parked iterators behind for whatever suite runs next — there is
//  no longer a product query among them, since `SubscriptionStoreView` loads
//  its own. Nothing here can prevent that; covering `start()` at all means
//  accepting it. It is recorded rather than hidden so that a future
//  investigation into cross-suite state starts with this file already ruled in.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

@MainActor
@Suite("Map entitlement launch", .serialized, .timeLimit(.minutes(1)))
struct MapEntitlementStoreLaunchTests {
    /// Its own defaults suite per test, for the same reason the sibling suite
    /// has one: `start()` persists its resolved answer.
    private static func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "MapEntitlementStoreLaunchTests-\(UUID().uuidString)"))
    }

    /// `start()` publishes to the process-wide answer, which the whole bundle
    /// shares.
    private static func restoreProcessEntitlement() {
        MapEntitlement.resetForTesting()
    }

    @Test("starting the store resolves the entitlement and publishes it")
    func startResolvesAndPublishes() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        let store = MapEntitlementStore(
            defaults: defaults,
            currentEntitlements: { true }
        )
        #expect(store.state == .unknown)

        store.start()

        await settleDelegateHop(until: "the launch resolve to land") {
            store.state == .entitled
        }
        #expect(store.state == .entitled)
        #expect(MapEntitlement.current == .entitled)
        #expect(defaults.bool(forKey: SettingsKey.lastKnownMapEntitlement))
    }

    /// The guard that stops a second `start()` opening a second
    /// `Transaction.updates` and a second status listener — two of each would
    /// finish every transaction twice and re-resolve on every renewal twice.
    ///
    /// Counted through the resolve rather than the listeners, which are
    /// private: one `start()` resolves once. The explicit `refresh()` at the
    /// end is the barrier — it is awaited, and both stray tasks would have
    /// been enqueued on this actor before it, so a broken guard could not
    /// still be pending by the time it returns.
    @Test("starting twice resolves once")
    func startIsIdempotent() async throws {
        defer { Self.restoreProcessEntitlement() }
        let resolves = Mutex(0)
        let store = MapEntitlementStore(
            defaults: try Self.defaults(),
            currentEntitlements: {
                resolves.withLock { $0 += 1 }
                return true
            }
        )

        store.start()
        store.start()
        await settleDelegateHop(until: "the launch resolve to land") {
            store.state == .entitled
        }
        await store.refresh()

        #expect(resolves.withLock { $0 } == 2)
    }
}
