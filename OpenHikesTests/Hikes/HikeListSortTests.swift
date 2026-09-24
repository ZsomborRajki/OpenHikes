//
//  HikeListSortTests.swift
//  OpenHikesTests
//
//  The six orders a library can be put in, and what a missing figure does.
//
//  Real `Hike` rows in an in-memory container, for the reason
//  ``HikeListOrderTests`` gives: two of the keys are not on `Hike` at all —
//  climb and descent live in the unmirrored sidecar — and a stand-in would
//  test the passthrough away.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

// swiftlint:disable no_magic_numbers

@Suite("The orders a library can be put in")
struct HikeListSortTests {
    @Test("longest first is by distance, not by date")
    func longestFirst() throws {
        let context = try Fixture.modelContext()
        let hikes = try makeHikes(in: context)

        let arranged = HikeListOrder.arrange(hikes, activeHikeID: nil, sort: .longest)

        #expect(arranged.map(\.title) == ["Long", "Middling", "Short"])
    }

    @Test("by name is case- and accent-blind, so É files under E")
    func alphabetical() throws {
        let context = try Fixture.modelContext()
        let hikes = [
            Fixture.hike(in: context, title: "zebra trail") { $0.date = .now },
            Fixture.hike(in: context, title: "Écrins Loop") { $0.date = .now },
            Fixture.hike(in: context, title: "Alpine Way") { $0.date = .now },
        ]

        let arranged = HikeListOrder.arrange(hikes, activeHikeID: nil, sort: .alphabetical)

        // Écrins between Alpine and zebra: a hiker looking for it under E is
        // not helped by it sorting after Z, which a plain `<` would do.
        #expect(arranged.map(\.title) == ["Alpine Way", "Écrins Loop", "zebra trail"])
    }

    @Test("a hike nothing has measured sorts last rather than as flat")
    func missingElevationSortsLast() throws {
        let context = try Fixture.modelContext()
        let hikes = try makeHikes(in: context)
        let climbed = try #require(hikes.first { $0.title == "Short" })
        climbed.climbMeters = 900
        climbed.descentMeters = 900

        let arranged = HikeListOrder.arrange(hikes, activeHikeID: nil, sort: .hilliest)

        // Zero would be a claim — a flat walk — and "not worked out yet" is
        // not one, so the measured hike leads and the rest keep date order.
        #expect(arranged.first?.title == "Short")
        // The unmeasured two keep the order underneath every sort, which is
        // newest first — Middling was walked today, Long yesterday.
        #expect(arranged.dropFirst().map(\.title) == ["Middling", "Long"])
    }

    @Test("only the elevation orders ask for anything to be measured")
    func onlyElevationOrdersNeedAFill() throws {
        let context = try Fixture.modelContext()
        let hikes = try makeHikes(in: context)

        #expect(HikeListOrder.hikesMissingElevation(in: hikes, for: .newest).isEmpty)
        #expect(HikeListOrder.hikesMissingElevation(in: hikes, for: .longest).isEmpty)
        #expect(HikeListOrder.hikesMissingElevation(in: hikes, for: .hilliest).count == hikes.count)
    }

    @Test("a measured hike is not asked to be measured again")
    func measuredHikesAreNotRefilled() throws {
        let context = try Fixture.modelContext()
        let hikes = try makeHikes(in: context)
        for hike in hikes {
            hike.climbMeters = 100
            hike.descentMeters = 100
        }

        #expect(HikeListOrder.hikesMissingElevation(in: hikes, for: .hilliest).isEmpty)
    }

    @Test("a hand-made order outranks whatever sort is chosen")
    func draggingWinsOverTheSort() throws {
        let context = try Fixture.modelContext()
        let hikes = try makeHikes(in: context)
        let byLength = HikeListOrder.arrange(hikes, activeHikeID: nil, sort: .longest)

        HikeListOrder.move(byLength, from: IndexSet(integer: 2), to: 0)

        // The sort is still `.longest`, and the hiker's order is what draws:
        // picking a sort is how the drag is given up, not something that
        // happens behind them.
        let arranged = HikeListOrder.arrange(hikes, activeHikeID: nil, sort: .longest)
        #expect(arranged.map(\.title) == ["Short", "Long", "Middling"])
    }

    /// Three hikes whose length and date disagree, so an order that claims to
    /// be by length cannot pass by accident.
    private func makeHikes(in context: ModelContext) throws -> [Hike] {
        let day = TimeInterval(60 * 60 * 24)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let rows: [(String, Double, Int)] = [
            ("Short", 2000, 2),
            ("Middling", 8000, 0),
            ("Long", 20_000, 1),
        ]
        let hikes = rows.map { title, distance, daysOld in
            Fixture.hike(in: context, title: title) { hike in
                hike.distanceMeters = distance
                hike.date = start.addingTimeInterval(-Double(daysOld) * day)
            }
        }
        try context.save()
        return hikes
    }
}

// swiftlint:enable no_magic_numbers
