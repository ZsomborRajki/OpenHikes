//
//  HikeListOrderTests.swift
//  OpenHikesTests
//
//  What order the library comes out in, and what a drag does to it.
//
//  Driven through real `Hike` rows in an in-memory container rather than a
//  stand-in, because the positions are the thing under test and they do not
//  live on `Hike` at all — they are in the unmirrored `HikeLocalState` store,
//  reached through a passthrough. A fake would test the passthrough away.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("The order the library is drawn in")
struct HikeListOrderTests {
    @Test("with nothing dragged, the newest walk is first")
    func dateOrderByDefault() throws {
        let context = try Fixture.modelContext()
        let hikes = try makeHikes(in: context)

        let arranged = HikeListOrder.arrange(hikes, activeHikeID: nil)

        #expect(arranged.map(\.title) == ["Newest", "Middle", "Oldest"])
        #expect(!HikeListOrder.isCustom(hikes))
    }

    @Test("a drag puts the row where it was dropped, and keeps it there")
    func aDragIsRemembered() throws {
        let context = try Fixture.modelContext()
        let hikes = try makeHikes(in: context)
        let arranged = HikeListOrder.arrange(hikes, activeHikeID: nil)

        // The oldest walk, dragged to the top.
        HikeListOrder.move(arranged, from: IndexSet(integer: 2), to: 0)

        let after = HikeListOrder.arrange(hikes, activeHikeID: nil)
        #expect(after.map(\.title) == ["Oldest", "Newest", "Middle"])
        #expect(HikeListOrder.isCustom(hikes))
    }

    @Test("the first drag gives every row a position, not just the one moved")
    func everyRowIsNumbered() throws {
        let context = try Fixture.modelContext()
        let hikes = try makeHikes(in: context)
        let arranged = HikeListOrder.arrange(hikes, activeHikeID: nil)

        HikeListOrder.move(arranged, from: IndexSet(integer: 2), to: 0)

        // A list where only the dragged row has a number has no answer for
        // where the others go, which is what makes a second drag ambiguous.
        #expect(hikes.allSatisfy { $0.listOrder != nil })
        #expect(Set(hikes.compactMap(\.listOrder)) == [0, 1, 2])
    }

    @Test("a hike added after the ordering sorts above it, not under it")
    func aNewHikeArrivesAtTheTop() throws {
        let context = try Fixture.modelContext()
        var hikes = try makeHikes(in: context)
        HikeListOrder.move(HikeListOrder.arrange(hikes, activeHikeID: nil), from: IndexSet(integer: 2), to: 0)

        let fresh = Fixture.hike(in: context, title: "Just Walked") { $0.date = .now }
        hikes.append(fresh)

        // The alternative is a walk finishing into the far end of a long list,
        // which is where `nil` would land it if it sorted as "no position".
        let arranged = HikeListOrder.arrange(hikes, activeHikeID: nil)
        #expect(arranged.first?.title == "Just Walked")
    }

    @Test("the hike being walked is first whatever its position says")
    func theActiveHikeIsPinned() throws {
        let context = try Fixture.modelContext()
        let hikes = try makeHikes(in: context)
        let arranged = HikeListOrder.arrange(hikes, activeHikeID: nil)
        HikeListOrder.move(arranged, from: IndexSet(integer: 2), to: 0)
        let last = try #require(hikes.first { $0.title == "Middle" })

        let pinned = HikeListOrder.arrange(hikes, activeHikeID: last.id)

        #expect(pinned.first?.title == "Middle")
        // Pinned rather than renumbered: the position it holds is the one it
        // goes back to when the walk ends.
        #expect(last.listOrder == 2)
        #expect(HikeListOrder.arrange(hikes, activeHikeID: nil).last?.title == "Middle")
    }

    @Test("resetting gives the list back to the date it was walked")
    func resetRestoresDateOrder() throws {
        let context = try Fixture.modelContext()
        let hikes = try makeHikes(in: context)
        HikeListOrder.move(HikeListOrder.arrange(hikes, activeHikeID: nil), from: IndexSet(integer: 2), to: 0)

        HikeListOrder.reset(hikes)

        #expect(!HikeListOrder.isCustom(hikes))
        #expect(HikeListOrder.arrange(hikes, activeHikeID: nil).map(\.title) == ["Newest", "Middle", "Oldest"])
    }

    /// Three hikes a day apart, oldest last, which is the order the list draws
    /// them in before anybody touches it.
    private func makeHikes(in context: ModelContext) throws -> [Hike] {
        let day = TimeInterval(60 * 60 * 24)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let titles = ["Oldest", "Middle", "Newest"]
        let hikes = titles.enumerated().map { index, title in
            Fixture.hike(in: context, title: title) { hike in
                hike.date = start.addingTimeInterval(Double(index) * day)
            }
        }
        try context.save()
        return hikes
    }
}
