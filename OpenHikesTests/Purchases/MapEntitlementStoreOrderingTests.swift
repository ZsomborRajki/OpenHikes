//
//  MapEntitlementStoreOrderingTests.swift
//  OpenHikesTests
//
//  Two entitlement reads in flight at once, answering out of order.
//
//  Launch, every foreground, the StoreKit listener, a restore and a purchase
//  finishing each start a read of their own, and nothing serializes them. The
//  bug this suite keeps fixed: the store published whichever answer arrived
//  *last*, so a read started before a purchase could come back after it with
//  "no", lock Pro again and persist the refusal for the next launch.
//
//  Every read here is held open by ``HeldEntitlementReads`` until the test
//  answers it, so both completion orders are written out rather than raced.
//  ``MapEntitlement`` is process-wide, so each test restores it.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

/// Entitlement reads that wait for the test to answer them, in the order they
/// were started.
private final class HeldEntitlementReads: Sendable {
    private let pending = Mutex<[CheckedContinuation<Bool, Never>?]>([])

    var started: Int { pending.withLock { $0.count } }

    @Sendable
    func read() async -> Bool {
        await withCheckedContinuation { continuation in
            pending.withLock { $0.append(continuation) }
        }
    }

    /// Answers the read that started `index`-th (from zero).
    func answer(_ index: Int, with entitled: Bool) {
        let continuation = pending.withLock { reads in
            defer { reads[index] = nil }
            return reads[index]
        }
        continuation?.resume(returning: entitled)
    }
}

@MainActor
@Suite("Map entitlement read ordering", .serialized)
struct MapEntitlementStoreOrderingTests {
    private static func defaults() throws -> UserDefaults {
        let name = "MapEntitlementStoreOrderingTests-\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    private static func store(
        defaults: UserDefaults,
        reads: HeldEntitlementReads
    ) -> MapEntitlementStore {
        MapEntitlementStore(
            defaults: defaults,
            currentEntitlements: reads.read,
            syncPurchases: { /* it lands */ }
        )
    }

    /// Starts a refresh and returns once its read is genuinely in flight.
    private static func startRefresh(
        _ store: MapEntitlementStore,
        reads: HeldEntitlementReads
    ) async -> Task<Void, Never> {
        let expected = reads.started + 1
        let task = Task { await store.refresh() }
        await settleDelegateHop(until: "read \(expected) to be in flight") {
            reads.started == expected
        }
        return task
    }

    /// The reported bug: a purchase's grant, then an older refusal.
    @Test("an older refusal does not replace a newer grant")
    func olderRefusalAfterNewerGrant() async throws {
        defer { MapEntitlement.resetForTesting() }
        let defaults = try Self.defaults()
        let reads = HeldEntitlementReads()
        let store = Self.store(defaults: defaults, reads: reads)

        let older = await Self.startRefresh(store, reads: reads)
        let newer = await Self.startRefresh(store, reads: reads)

        reads.answer(1, with: true)
        await newer.value
        #expect(store.state == .entitled)

        reads.answer(0, with: false)
        await older.value

        #expect(store.state == .entitled)
        #expect(MapEntitlement.current == .entitled)
        #expect(defaults.bool(forKey: SettingsKey.lastKnownMapEntitlement))
    }

    /// The mirror image: a lapse is not undone by a grant read before it.
    @Test("an older grant does not replace a newer refusal")
    func olderGrantAfterNewerRefusal() async throws {
        defer { MapEntitlement.resetForTesting() }
        let defaults = try Self.defaults()
        let reads = HeldEntitlementReads()
        let store = Self.store(defaults: defaults, reads: reads)

        let older = await Self.startRefresh(store, reads: reads)
        let newer = await Self.startRefresh(store, reads: reads)

        reads.answer(1, with: false)
        await newer.value
        #expect(store.state == .notEntitled)

        reads.answer(0, with: true)
        await older.value

        #expect(store.state == .notEntitled)
        #expect(MapEntitlement.current == .notEntitled)
        #expect(defaults.object(forKey: SettingsKey.lastKnownMapEntitlement) != nil)
        #expect(!defaults.bool(forKey: SettingsKey.lastKnownMapEntitlement))
    }

    /// In order, both answers publish: the rule drops only a superseded one,
    /// so a newer read that is slow cannot hold the older answer back.
    @Test("an older answer arriving first still publishes")
    func olderAnswerFirstPublishesBoth() async throws {
        defer { MapEntitlement.resetForTesting() }
        let defaults = try Self.defaults()
        let reads = HeldEntitlementReads()
        let store = Self.store(defaults: defaults, reads: reads)

        let older = await Self.startRefresh(store, reads: reads)
        let newer = await Self.startRefresh(store, reads: reads)

        reads.answer(0, with: false)
        await older.value
        #expect(store.state == .notEntitled)
        #expect(MapEntitlement.current == .notEntitled)

        reads.answer(1, with: true)
        await newer.value
        #expect(store.state == .entitled)
        #expect(MapEntitlement.current == .entitled)
        #expect(defaults.bool(forKey: SettingsKey.lastKnownMapEntitlement))
    }

    /// A restore's own read, overtaken by nothing, is what it reports — even
    /// when a foreground read started before it answers "no" afterwards.
    @Test("a restore's grant survives an older refusal arriving later")
    func restoreSurvivesOlderRefusal() async throws {
        defer { MapEntitlement.resetForTesting() }
        let defaults = try Self.defaults()
        let reads = HeldEntitlementReads()
        let store = Self.store(defaults: defaults, reads: reads)

        let foreground = await Self.startRefresh(store, reads: reads)
        let restore = Task { await store.restore() }
        await settleDelegateHop(until: "the restore's read to be in flight") {
            reads.started == 2
        }

        reads.answer(1, with: true)
        #expect(await restore.value == .restored)

        reads.answer(0, with: false)
        await foreground.value

        #expect(store.state == .entitled)
        #expect(MapEntitlement.current == .entitled)
        #expect(defaults.bool(forKey: SettingsKey.lastKnownMapEntitlement))
    }
}
