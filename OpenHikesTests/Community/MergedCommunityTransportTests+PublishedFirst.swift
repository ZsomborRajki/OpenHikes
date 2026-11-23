//
//  MergedCommunityTransportTests+PublishedFirst.swift
//  OpenHikesTests
//
//  Neither half is held for the other.
//
//  An extension of `MergedCommunityTransportTests` rather than a suite of its
//  own, for the reason the `+Curated` file gives: the same type, the same two
//  stubs. What separates this file is *when* rows come back rather than which.
//  The name is from when the published half was the only one that could come
//  back early.
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
            published: [Self.published("listing-a", metersNorth: Offset.near)],
            curated: [Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest)]
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

    /// The other way round, which is what downloading an area's trails is
    /// for: they are read off the device in a moment, and with no signal it is
    /// CloudKit that hangs. CloudKit is held shut and only the trails' arrival
    /// opens it, so a merge that waited for CloudKit before handing anything
    /// up would never get as far as the assertions.
    @Test(
        "trails that came with their lines are handed up while CloudKit is still out",
        .timeLimit(.minutes(1))
    )
    func curatedHalfArrivesFirst() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metersNorth: Offset.near)],
            curated: [Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest)]
        )
        let gate = AsyncGate()
        merged.cloudKit.beforeListingsReturn = { await gate.wait() }
        let early = Mutex<[[String]]>([])

        let answer = try await Self.answer(merged) { rows in
            early.withLock { $0.append(rows.map(\.id)) }
            await gate.open()
        }

        #expect(
            early.withLock { $0 } == [[CommunityIdentity.curated(relationID: Relation.wimbach)]],
            "once, with the trails only"
        )
        #expect(answer.listings.count == 2, "the whole answer still carries both halves")
        #expect(answer.listings.contains { $0.id == "listing-a" })
    }

    /// Trails drawn early fill the page they would fill on their own, because
    /// nobody knows yet how many published hikes there are. When CloudKit
    /// lands, the page is still spent on it first, and the trails give their
    /// places back rather than keep them for having arrived first.
    @Test(
        "trails handed up early give their places back to published hikes",
        .timeLimit(.minutes(1))
    )
    func earlyTrailsGiveWayToPublishedHikes() async throws {
        let merged = Self.merged(
            published: [
                Self.published("listing-a", metersNorth: Offset.near),
                Self.published("listing-b", metersNorth: Offset.far),
            ],
            curated: [
                Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest),
                Self.trail(Relation.almbach, named: "Almbachklamm", metersNorth: Offset.farthest),
            ]
        )
        let gate = AsyncGate()
        merged.cloudKit.beforeListingsReturn = { await gate.wait() }
        let early = Mutex<[[String]]>([])

        let answer = try await Self.answer(merged, limit: 2) { rows in
            early.withLock { $0.append(rows.map(\.id)) }
            await gate.open()
        }

        let trails = [Relation.wimbach, Relation.almbach].map { CommunityIdentity.curated(relationID: $0) }
        #expect(early.withLock { $0 } == [trails], "the page the trails would fill on their own")
        #expect(answer.listings.map(\.id) == ["listing-a", "listing-b"], "and the published hikes took it back")
    }

    /// A trail still without its line costs a geometry request, and how many
    /// of those are worth asking for waits on the published half. So only the
    /// trails that came with their lines go up while CloudKit is out, and the
    /// rest join them in the merged answer. CloudKit is held shut until the
    /// trails are drawn, so the trails are certainly the half that lands
    /// first.
    @Test(
        "trails still without their lines are not handed up early",
        .timeLimit(.minutes(1))
    )
    func linelessTrailsWaitForTheMergedAnswer() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metersNorth: Offset.far)],
            curated: [
                Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest),
                Self.lineless(Self.trail(Relation.almbach, named: "Almbachklamm", metersNorth: Offset.near)),
            ]
        )
        let gate = AsyncGate()
        merged.cloudKit.beforeListingsReturn = { await gate.wait() }
        let early = Mutex<[[String]]>([])

        let answer = try await Self.answer(merged) { rows in
            early.withLock { $0.append(rows.map(\.id)) }
            await gate.open()
        }

        #expect(
            early.withLock { $0 } == [[CommunityIdentity.curated(relationID: Relation.wimbach)]],
            "the trail with its line, and not the one without"
        )
        #expect(answer.listings.count == 3, "the merged answer still carries all three")
    }

    /// A published-only question has no slower half to wait for, so its
    /// answer *is* the published half and nothing arrives before it.
    @Test("a published-only question hands nothing up early")
    func publishedOnlyHandsNothingUp() async throws {
        let merged = Self.merged(
            published: [Self.published("listing-a", metersNorth: Offset.near)]
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
    /// hikes here* over a valley full of them, for ten seconds. The trail has
    /// no line, so it may not go up early either, and the case is about the
    /// published half alone.
    @Test("an empty published half is not handed up")
    func emptyPublishedHalfIsKept() async throws {
        let merged = Self.merged(
            curated: [Self.lineless(Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest))]
        )
        let early = Mutex(0)

        let answer = try await Self.answer(merged) { _ in
            early.withLock { $0 += 1 }
        }

        #expect(early.withLock { $0 } == 0)
        #expect(answer.listings.count == 1)
    }

    /// A failed published half has no rows to hand up, and the curated half
    /// still answers — the merge's own rule, unchanged by the early path. The
    /// trail has no line so that, as above, the case is about the published
    /// half alone.
    @Test("a failed published half hands nothing up and the trails still land")
    func failedPublishedHalfHandsNothingUp() async throws {
        let merged = Self.merged(
            curated: [Self.lineless(Self.trail(Relation.wimbach, named: "Wimbachgries", metersNorth: Offset.nearest))]
        )
        merged.cloudKit.listingsResult = .failure(.unreachable)
        let early = Mutex(0)

        let answer = try await Self.answer(merged) { _ in
            early.withLock { $0 += 1 }
        }

        #expect(early.withLock { $0 } == 0)
        #expect(answer.listings.count == 1)
    }

    /// `trail` as a wide search's listing pass brings it back: without its
    /// line, which only the geometry pass adds.
    private static func lineless(_ trail: CuratedTrail) -> CuratedTrail {
        var lineless = trail
        lineless.route = []
        return lineless
    }
}
