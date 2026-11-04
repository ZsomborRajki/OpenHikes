//
//  StatHalvesTests.swift
//  OpenHikesTests
//
//  `StatHalves` is the one place a screen's stats are sorted into the place
//  card's strip and list. `partitioned(by:)` hands back the stats that fail
//  the test first, so a swapped pair would put the headline figures in the
//  list and every other figure in the strip, and still compile. What is pinned
//  here is which half each stat lands in, that each half keeps the order and
//  the very stats it was given, and that a half with nothing in it is empty.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Stat halves")
struct StatHalvesTests {
    @Test("headline stats go to the strip and the rest to the list, each in the order given")
    func sortsEachStatIntoItsHalfInOrder() {
        let stats = [
            Stat("Distance", "12.4 km", headline: true),
            Stat("Max Elevation", "1,820 m"),
            Stat("Duration", "4h 10m", headline: true),
            Stat("Min Elevation", "640 m"),
            Stat("Elevation Gain", "980 m", headline: true),
        ]

        let halves = StatHalves(stats)

        #expect(halves.headline.map(\.id) == [stats[0].id, stats[2].id, stats[4].id])
        #expect(halves.details.map(\.id) == [stats[1].id, stats[3].id])
    }

    @Test("a half with no stats in it is empty")
    func leavesAnUnusedHalfEmpty() {
        let figures = StatHalves([Stat("Distance", "12.4 km", headline: true)])
        #expect(figures.details.isEmpty)
        #expect(figures.headline.count == 1)

        let rows = StatHalves([Stat("Min Elevation", "640 m")])
        #expect(rows.headline.isEmpty)
        #expect(rows.details.count == 1)

        let none = StatHalves([])
        #expect(none.headline.isEmpty)
        #expect(none.details.isEmpty)
    }
}
