//
//  MergedCommunityTransportTests+PublishedFirst.swift
//  OpenHikesTests
//
//  The published half is not held for the curated one.
//
//  An extension of `MergedCommunityTransportTests` rather than a suite of its
//  own, for the reason the `+Curated` file gives: the same type, the same two
//  stubs. What separates this file is *when* rows come back rather than which.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

extension MergedCommunityTransportTests {
    /// The request that asked for this: CloudKit answered in a moment and the
    /// list sat empty for the ten seconds Overpass took. The curated listing
    /// pass is held shut and only the published half's arrival opens it, so
    /// a merge that waited for Overpass before handing anything up would never
    /// get as far as the assertions.
    @Test(
        "the published half is handed up while OpenStreetMap is still out",
        .timeLimit(.minutes(1))
    )
    func publishedHalfArrivesFirst() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.near)],
            curated: [Self.trail(Relation.wimbach, named: "Wimbachgries", metresNorth: Offset.nearest)]
        )
        let gate = AsyncGate()
        merged.overpass.beforeListingsReturn = { await gate.wait() }
        let early = Mutex<[[String]]>([])

        let answer = try await Self.answer(merged) { rows in
            early.withLock { $0.append(rows.map(\.id)) }
            await gate.open()
        }

        #expect(early.withLock { $0 } == [["listing-a"]], "once, with the published rows only")
        #expect(answer.listings.count == 2, "the whole answer still carries both halves")
        #expect(answer.listings.contains { $0.id == "listing-a" })
    }

    /// A published-only question has no slower half to wait for, so its
    /// answer *is* the published half and nothing arrives before it.
    @Test("a published-only question hands nothing up early")
    func publishedOnlyHandsNothingUp() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metresNorth: Offset.near)]
        )
        let early = Mutex(0)

        let answer = try await Self.answer(merged, scope: .publishedOnly) { _ in
            early.withLock { $0 += 1 }
        }

        #expect(early.withLock { $0 } == 0)
        #expect(answer.listings.map(\.id) == ["listing-a"])
    }

    /// An empty published half would replace the last area's rows with
    /// nothing while this area's trails were still coming — *No community
    /// hikes here* over a valley full of them, for ten seconds.
    @Test("an empty published half is not handed up")
    func emptyPublishedHalfIsKept() async throws {
        let merged = Self.merged(
            curated: [Self.trail(Relation.wimbach, named: "Wimbachgries", metresNorth: Offset.nearest)]
        )
        let early = Mutex(0)

        let answer = try await Self.answer(merged) { _ in
            early.withLock { $0 += 1 }
        }

        #expect(early.withLock { $0 } == 0)
        #expect(answer.listings.count == 1)
    }

    /// A failed published half has no rows to hand up, and the curated half
    /// still answers — the merge's own rule, unchanged by the early path.
    @Test("a failed published half hands nothing up and the trails still land")
    func failedPublishedHalfHandsNothingUp() async throws {
        let merged = Self.merged(
            curated: [Self.trail(Relation.wimbach, named: "Wimbachgries", metresNorth: Offset.nearest)]
        )
        merged.cloudKit.listingsResult = .failure(.unreachable)
        let early = Mutex(0)

        let answer = try await Self.answer(merged) { _ in
            early.withLock { $0 += 1 }
        }

        #expect(early.withLock { $0 } == 0)
        #expect(answer.listings.count == 1)
    }
}
