//
//  HikeSearchTests.swift
//  OpenHikesTests
//
//  Ranking every hike title against the query is the one real cost in
//  `MapSheetHikes.body` — a body that runs far more often than the query
//  changes, including once per detent change a sheet drag produces.
//  `HikeSearch` keeps the result instead, so there are two halves to hold
//  onto: the ranking must still be the ranking, and a repeat pass must not
//  redo it.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Hike search")
struct HikeSearchTests {
    /// The sheet hands over `@Query`'s array; these are its titles in its
    /// order (newest first), so a test reads like the list on screen.
    private func hikes(_ titles: [String], in context: ModelContext) -> [Hike] {
        titles.map { Fixture.hike(in: context, title: $0) }
    }

    @Test("titles starting with the query rank above titles merely containing it")
    func prefixMatchesRankFirst() throws {
        let context = try Fixture.modelContext()
        let hikes = hikes(["Zermatt Ridge", "Ridge Loop", "High Ridge Traverse", "Valley Floor"], in: context)
        let search = HikeSearch()

        let matches = search.rankedHikes(matching: "ridge", in: hikes).map(\.title)
        #expect(matches == ["Ridge Loop", "High Ridge Traverse", "Zermatt Ridge"])
    }

    /// Ties inside a rank are broken by the folded title, so the order doesn't
    /// depend on the order the store happened to hand the hikes over in.
    @Test("case and accents don't decide whether a trail matches")
    func matchingIsCaseAndDiacriticInsensitive() throws {
        let context = try Fixture.modelContext()
        let hikes = hikes(["ZÜRICHBERG", "zürichberg trail", "Zurichberg Alt"], in: context)
        let search = HikeSearch()

        let matches = search.rankedHikes(matching: "ZURICH", in: hikes).map(\.title)
        #expect(matches == ["ZÜRICHBERG", "Zurichberg Alt", "zürichberg trail"])
    }

    @Test("an empty or whitespace-only query matches nothing")
    func blankQueryMatchesNothing() throws {
        let context = try Fixture.modelContext()
        let hikes = hikes(["Ridge Loop"], in: context)
        let search = HikeSearch()

        #expect(search.rankedHikes(matching: "", in: hikes).isEmpty)
        #expect(search.rankedHikes(matching: "   \n", in: hikes).isEmpty)
        #expect(search.rankingPasses == 0, "a blank query is answered without ranking anything")
    }

    /// The finding itself: a sheet drag is a run of body passes with an
    /// unchanged query over an unchanged list.
    @Test("dragging the sheet doesn't re-rank")
    func repeatedBodyPassesReuseTheRanking() throws {
        let context = try Fixture.modelContext()
        let hikes = hikes(["Ridge Loop", "Valley Floor", "Ridgeway"], in: context)
        let search = HikeSearch()

        let first = search.rankedHikes(matching: "ridge", in: hikes).map(\.title)
        for _ in 0..<40 {
            #expect(search.rankedHikes(matching: "ridge", in: hikes).map(\.title) == first)
        }
        #expect(search.rankingPasses == 1)

        // Leading/trailing whitespace is trimmed before the comparison, so a
        // trailing space typed and deleted isn't a new query either.
        _ = search.rankedHikes(matching: " ridge ", in: hikes)
        #expect(search.rankingPasses == 1)
    }

    @Test("another keystroke re-ranks")
    func queryChangeInvalidatesTheCache() throws {
        let context = try Fixture.modelContext()
        let hikes = hikes(["Ridge Loop", "Valley Floor"], in: context)
        let search = HikeSearch()

        #expect(search.rankedHikes(matching: "r", in: hikes).count == 2)
        #expect(search.rankedHikes(matching: "ri", in: hikes).map(\.title) == ["Ridge Loop"])
        #expect(search.rankingPasses == 2)
    }

    /// A rename changes the ranking without changing the list, so the cache
    /// key has to include the titles and not just which hikes are present.
    @Test("renaming a hike re-ranks")
    func renameInvalidatesTheCache() throws {
        let context = try Fixture.modelContext()
        let hikes = hikes(["Ridge Loop", "Valley Floor"], in: context)
        let search = HikeSearch()

        #expect(search.rankedHikes(matching: "ridge", in: hikes).map(\.title) == ["Ridge Loop"])

        hikes[1].title = "Ridgeback"
        #expect(search.rankedHikes(matching: "ridge", in: hikes).map(\.title) == ["Ridge Loop", "Ridgeback"])
        #expect(search.rankingPasses == 2)
    }

    /// An import or a deletion replaces `@Query`'s array while the query
    /// stands — the new list has to be ranked rather than answered from the
    /// old one, which would leave the sheet showing a deleted trail.
    @Test("importing or deleting a hike re-ranks")
    func changingTheHikesInvalidatesTheCache() throws {
        let context = try Fixture.modelContext()
        var hikes = hikes(["Ridge Loop", "Valley Floor"], in: context)
        let search = HikeSearch()

        #expect(search.rankedHikes(matching: "ridge", in: hikes).map(\.title) == ["Ridge Loop"])

        hikes.insert(Fixture.hike(in: context, title: "Ridgeway Path"), at: 0)
        #expect(search.rankedHikes(matching: "ridge", in: hikes).map(\.title) == ["Ridge Loop", "Ridgeway Path"])

        hikes.removeAll { $0.title == "Ridge Loop" }
        #expect(search.rankedHikes(matching: "ridge", in: hikes).map(\.title) == ["Ridgeway Path"])
        #expect(search.rankingPasses == 3)
    }

    /// Two trails can share a title, so equal titles in equal positions is not
    /// enough to call it the same list: the cached rows would point at models
    /// the store has since replaced.
    @Test("a same-titled hike doesn't get answered from the previous one")
    func identityIsPartOfTheCacheKey() throws {
        let context = try Fixture.modelContext()
        let original = hikes(["Ridge Loop"], in: context)
        let search = HikeSearch()

        #expect(search.rankedHikes(matching: "ridge", in: original).first === original[0])

        let replacement = hikes(["Ridge Loop"], in: context)
        let matches = search.rankedHikes(matching: "ridge", in: replacement)
        #expect(matches.first === replacement[0])
        #expect(search.rankingPasses == 2)
    }

    /// Clearing the field (or dismissing the keyboard, which calls `clear()`)
    /// releases the matched hikes rather than holding them behind a search
    /// nobody is running — so the next search starts from nothing.
    @Test("clearing the search drops what the ranking held")
    func clearingReleasesTheCachedResults() throws {
        let context = try Fixture.modelContext()
        let hikes = hikes(["Ridge Loop"], in: context)
        let search = HikeSearch()

        #expect(search.rankedHikes(matching: "ridge", in: hikes).count == 1)
        #expect(search.rankedHikes(matching: "", in: hikes).isEmpty)
        #expect(search.rankedHikes(matching: "ridge", in: hikes).count == 1)
        #expect(search.rankingPasses == 2, "the emptied query dropped the cache rather than parking it")

        search.clear()
        #expect(search.rankedHikes(matching: "ridge", in: hikes).count == 1)
        #expect(search.rankingPasses == 3)
    }
}
