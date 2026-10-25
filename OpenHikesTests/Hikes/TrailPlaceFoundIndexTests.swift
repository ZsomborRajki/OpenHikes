//
//  TrailPlaceFoundIndexTests.swift
//  OpenHikesTests
//
//  How *Places Around Trail* merges an answer into what it has found: the
//  rule a scan from the front of the list applied, and the work a merge does,
//  counted rather than timed. A merge reads each incoming row's element once,
//  however much has been found — not once per row found for every row given,
//  which made a dozen corridor answers of two hundred places each quadratic
//  on the main actor.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Places found, indexed")
struct TrailPlaceFoundIndexTests {
    private static func row(_ elementID: Int64?, id: UUID = UUID()) -> TrailPlaceRow {
        let osm = elementID.map { TrailPlaceOSM(elementType: "node", elementID: $0) }
        return TrailPlaceRow(place: TrailPlace(latitude: 47.6, longitude: 12.98, osm: osm, id: id))
    }

    /// Counts the elements a merge reads.
    private final class Reads {
        var count = 0
    }

    @Test("a row that has one found row's id and another's element stands for the earlier of the two")
    func earlierOfTwoMatchesWins() {
        var index = TrailPlaceFoundIndex()
        let first = Self.row(1)
        let second = Self.row(2)
        _ = index.merge([first, second])

        #expect(index.merge([Self.row(1, id: second.id)]).ids == [first.id])
        #expect(index.merge([Self.row(2, id: first.id)]).ids == [first.id])
    }

    @Test("an element given twice in one answer is added once, under the first row's id")
    func elementTwiceInOneAnswer() {
        var index = TrailPlaceFoundIndex()
        let first = Self.row(7)

        let merge = index.merge([first, Self.row(7), Self.row(8)])

        #expect(merge.added.map(\.place.osm?.elementID) == [7, 8])
        #expect(merge.added.first?.id == first.id)
        #expect(index.position(of: first.id) == 0)
    }

    @Test("merging a dozen answers of two hundred, then all of them again, reads each row's element once")
    func mergeReadsEachElementOnce() {
        let reads = Reads()
        var index = TrailPlaceFoundIndex { place in
            reads.count += 1
            return TrailPlaceFoundIndex.element(place)
        }
        let answers = (0..<12).map { answer in
            (0..<200).map { Self.row(Int64(answer * 200 + $0)) }
        }

        let added = answers.map { index.merge($0).added.count }
        let repeated = index.merge(answers.flatMap(\.self))

        #expect(added == Array(repeating: 200, count: 12))
        #expect(repeated.added.isEmpty)
        #expect(repeated.ids.count == 2400)
        #expect(reads.count == 4800, "one read per row given, not one per row found")
        #expect(index.position(of: answers[11][199].id) == 2399, "rows keep the order they were added in")
    }
}
