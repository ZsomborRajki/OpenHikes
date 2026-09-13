//
//  MapEntitlementProductRetryTests.swift
//  OpenHikesTests
//
//  Getting a price after the first attempt failed.
//
//  The product lookup used to run once, from `start()`, and a launch with no
//  signal left `product` nil and the purchase button dead for the life of the
//  process: restoring connectivity, foregrounding the app and reopening the
//  paywall all changed nothing, so the only way to buy the subscription was to
//  force-quit. These pin the two halves of the fix — that a later attempt
//  actually reaches the App Store, and that several callers wanting the same
//  answer at once produce one query rather than several.
//
//  A real `Product` cannot be built in a unit bundle, so what is asserted here
//  is the query and the state around it rather than a successful purchase.
//  `MapEntitlementStoreLaunchTests` explains, in its header, why the StoreKit
//  parts of this object are otherwise unreachable from here.
//

import Foundation
@testable import OpenHikes
import StoreKit
import Synchronization
import Testing

@MainActor
@Suite("Map entitlement product retry", .serialized, .timeLimit(.minutes(1)))
struct MapEntitlementProductRetryTests {
    /// Its own defaults suite per test: the store persists its resolved
    /// entitlement, like its sibling suites.
    private static func defaults() throws -> UserDefaults {
        let name = "MapEntitlementProductRetryTests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    /// A lookup that counts what it was asked, and can be told to fail.
    nonisolated private final class Lookup: Sendable {
        private struct State {
            var attempts = 0
            var failing = true
        }

        private let state = Mutex(State())

        var attempts: Int { state.withLock(\.attempts) }

        func stopFailing() { state.withLock { state in state.failing = false } }

        func load(_: [String]) throws -> [Product] {
            let failing = state.withLock { state in
                state.attempts += 1
                return state.failing
            }
            if failing { throw CocoaError(.fileNoSuchFile) }
            // An empty answer rather than a product: a `Product` cannot be
            // constructed outside StoreKit. The store's own behaviour is the
            // same either way — see `productAvailability`.
            return []
        }
    }

    private func store(_ lookup: Lookup, defaults: UserDefaults) -> MapEntitlementStore {
        MapEntitlementStore(
            defaults: defaults,
            currentEntitlements: { false },
            loadProducts: { try lookup.load($0) }
        )
    }

    @Test("a failed lookup can be asked again")
    func aFailedLookupIsRetried() async throws {
        let lookup = Lookup()
        let store = store(lookup, defaults: try Self.defaults())

        await store.loadProduct()
        #expect(lookup.attempts == 1)
        #expect(store.productAvailability == .unavailable)

        lookup.stopFailing()
        await store.loadProduct()

        #expect(lookup.attempts == 2, "the second attempt is what recovery means")
    }

    /// Before anything has answered, the screen is waiting rather than out of
    /// luck — the distinction the paywall draws between a spinner and an
    /// offer to try again.
    @Test("a lookup that has not answered yet reads as loading")
    func anUnansweredLookupReadsAsLoading() async throws {
        let lookup = Lookup()
        let store = store(lookup, defaults: try Self.defaults())

        #expect(store.productAvailability == .loading)
        #expect(!store.canPurchase)

        await store.loadProduct()

        #expect(store.productAvailability == .unavailable)
        #expect(store.canRestore, "restoring never needed a product")
    }

    /// The paywall asks on presentation, the foreground asks again and the
    /// launch fires one of its own. Several callers is the ordinary case;
    /// several queries is the bug.
    @Test("callers arriving together share one query")
    func concurrentCallersShareOneQuery() async throws {
        let lookup = Lookup()
        let store = store(lookup, defaults: try Self.defaults())

        let callers = (0..<4).map { _ in Task { await store.loadProduct() } }
        for caller in callers {
            await caller.value
        }

        #expect(lookup.attempts == 1)
    }

    /// And a foreground with nothing to show asks again, which is the entry
    /// point a customer reaches by walking back into signal.
    @Test("returning to the app asks again while there is no price")
    func foregroundingRetriesWhileUnavailable() async throws {
        let lookup = Lookup()
        let store = store(lookup, defaults: try Self.defaults())
        await store.loadProduct()
        #expect(lookup.attempts == 1)

        store.sceneDidBecomeActive()

        await settleDelegateHop(until: "the foreground's lookup to run") {
            lookup.attempts == 2
        }
    }
}
