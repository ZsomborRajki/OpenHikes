//
//  MapEntitlementStoreRestoreTests.swift
//  OpenHikesTests
//
//  What a tap on **Restore Purchases** reports, for each of the four things it
//  can turn out to be.
//
//  The bug this suite exists to keep fixed: `restore()` used to swallow every
//  `AppStore.sync()` error and answer with a bare `Bool`, so an offline device
//  and an Apple Account that genuinely owns nothing arrived at the paywall as
//  the same sentence — one that told a paying customer no purchase was found
//  and suggested they sign in to a different account. The app had no evidence
//  for either half of that.
//
//  Everything here is driven through the two injected closures. The real
//  `AppStore.sync()` never returns under `xcodebuild test` — see the header of
//  ``MapEntitlementStoreTests`` — and the seam is what turns the sync from an
//  untestable hang into an ordinary throw or an ordinary success. What the sync
//  *would* have revealed is expressed as whatever `currentEntitlements` answers
//  next, which is exactly the two-step shape the outcome enum separates.
//
//  ``MapEntitlement`` is process-wide and shared with every other suite in this
//  bundle, so each test here restores it — see ``restoreProcessEntitlement()``.
//

import Foundation
@testable import OpenHikes
import StoreKit
import Synchronization
import Testing

@MainActor
@Suite("Map entitlement restore", .serialized)
struct MapEntitlementStoreRestoreTests {
    /// The error a suite throws in place of whatever StoreKit would have.
    ///
    /// Carries a message so the tests can assert the *reason* reaches the
    /// paywall rather than being replaced by a sentence the store invented.
    private struct SyncFailure: LocalizedError {
        var errorDescription: String? { "The App Store could not be reached." }
    }

    /// Its own defaults suite per test, for the reason the sibling suites have
    /// one: a resolve persists its answer.
    private static func defaults() throws -> UserDefaults {
        let name = "MapEntitlementStoreRestoreTests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    private static func restoreProcessEntitlement() {
        MapEntitlement.resetForTesting()
    }

    private static func store(
        defaults: UserDefaults,
        entitled: @escaping @Sendable () async -> Bool,
        sync: @escaping @Sendable () async throws -> Void = { /* it lands */ }
    ) -> MapEntitlementStore {
        MapEntitlementStore(
            defaults: defaults,
            currentEntitlements: entitled,
            syncPurchases: sync
        )
    }

    // MARK: - The sync landed

    /// The reason the button exists: a new device, a subscription bought on the
    /// old one, and one tap that finds it.
    @Test("a sync that finds the subscription restores it")
    func syncFindingAnEntitlementRestores() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        let store = Self.store(defaults: defaults, entitled: { true })

        let outcome = await store.restore()

        #expect(outcome == .restored)
        #expect(store.state == .entitled)
        #expect(MapEntitlement.current == .entitled)
        #expect(defaults.bool(forKey: SettingsKey.lastKnownMapEntitlement))
        #expect(!store.isWorking)
    }

    /// The one case allowed to say "Nothing to Restore": the App Store was
    /// asked, it answered, and the answer was that this account owns nothing.
    @Test("a sync that finds nothing reports an empty purchase history")
    func syncFindingNothingReportsNothingToRestore() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        let store = Self.store(defaults: defaults, entitled: { false })

        let outcome = await store.restore()

        #expect(outcome == .nothingToRestore)
        #expect(store.state == .notEntitled)
        #expect(!store.isWorking)
    }

    // MARK: - The sync did not land

    /// The bug, pinned. A failed sync is not evidence about the account, so it
    /// must not arrive as the sentence that blames it.
    @Test("a failed sync reports the failure rather than an empty history")
    func failedSyncReportsFailure() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        let asked = Mutex(false)
        let store = Self.store(
            defaults: defaults,
            entitled: {
                asked.withLock { $0 = true }
                return false
            },
            sync: { throw SyncFailure() }
        )

        let outcome = await store.restore()

        #expect(outcome == .failed("The App Store could not be reached."))
        #expect(outcome != .nothingToRestore)
        // Nothing was asked, so nothing is known and nothing is written down.
        #expect(!asked.withLock { $0 })
        #expect(store.state == .unknown)
        #expect(defaults.object(forKey: SettingsKey.lastKnownMapEntitlement) == nil)
        #expect(!store.isWorking)
    }

    /// The expensive half of the same bug. A subscriber whose sync fails keeps
    /// their maps: re-reading `currentEntitlements` here would take the
    /// entitlement away on the strength of the one query that just failed —
    /// which on a device whose receipt has not arrived answers "no".
    @Test("a failed sync leaves a resolved entitlement exactly as it was")
    func failedSyncKeepsTheCurrentEntitlement() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        let entitled = Mutex(true)
        let store = Self.store(
            defaults: defaults,
            entitled: { entitled.withLock { $0 } },
            sync: {
                // The local query would now answer "no" — the receipt this
                // device holds is the one the failed sync was meant to fetch.
                entitled.withLock { $0 = false }
                throw SyncFailure()
            }
        )
        await store.refresh()
        #expect(store.state == .entitled)

        let outcome = await store.restore()

        guard case .failed = outcome else {
            Issue.record("Expected a failure from a throwing sync, got \(outcome)")
            return
        }
        #expect(store.state == .entitled)
        #expect(MapEntitlement.current == .entitled)
        #expect(defaults.bool(forKey: SettingsKey.lastKnownMapEntitlement))
    }

    /// Dismissing the password prompt is not a failure and not an answer. It
    /// gets the same silence a cancelled purchase does.
    @Test("dismissing the App Store prompt says nothing")
    func cancelledSyncReportsCancellation() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        let store = Self.store(
            defaults: defaults,
            entitled: { false },
            sync: { throw StoreKitError.userCancelled }
        )

        let outcome = await store.restore()

        #expect(outcome == .cancelled)
        #expect(store.state == .unknown)
        #expect(!store.isWorking)
    }

    // MARK: - A second tap

    /// `isWorking` disables the button, but a tap can still land in the frame
    /// before that redraw. The second one must not start a second sync — and
    /// must not report an empty history either, since it never asked.
    @Test("a second tap while a restore is in flight starts nothing")
    func secondTapWhileWorkingIsCancelled() async throws {
        defer { Self.restoreProcessEntitlement() }
        let defaults = try Self.defaults()
        let syncs = Mutex(0)
        let (releases, release) = AsyncStream<Void>.makeStream()
        let store = Self.store(
            defaults: defaults,
            entitled: { true },
            sync: {
                syncs.withLock { $0 += 1 }
                // Held open until the test lets go, so the second tap lands
                // while the first restore is genuinely still in flight.
                for await _ in releases { break }
            }
        )

        let first = Task { await store.restore() }
        await settleDelegateHop(until: "the first restore to reach the sync") {
            store.isWorking
        }

        let second = await store.restore()

        #expect(second == .cancelled)
        #expect(syncs.withLock { $0 } == 1)

        release.finish()
        #expect(await first.value == .restored)
        #expect(syncs.withLock { $0 } == 1)
        #expect(!store.isWorking)
    }
}
