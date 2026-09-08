//
//  TimestampIndexTests.swift
//  OpenHikesSharedTests
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Timestamp index")
struct TimestampIndexTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("tolerance boundaries are inclusive")
    func inclusiveTolerance() {
        let index = TimestampIndex([start])

        #expect(
            index.contains(
                start.addingTimeInterval(-5),
                within: 5
            )
        )
        #expect(
            index.contains(
                start.addingTimeInterval(5),
                within: 5
            )
        )
        #expect(
            !index.contains(
                start.addingTimeInterval(5.001),
                within: 5
            )
        )
    }

    @Test("out-of-order input is indexed in timestamp order")
    func inputIsSorted() {
        let index = TimestampIndex([
            start.addingTimeInterval(20),
            start,
        ])

        #expect(index.contains(start.addingTimeInterval(4), within: 5))
        #expect(
            index.contains(
                start.addingTimeInterval(21),
                within: 1
            )
        )
    }

    @Test("an empty index contains nothing, however wide the tolerance")
    func emptyIndexContainsNothing() {
        let index = TimestampIndex([Date]())

        #expect(!index.contains(start, within: 0))
        #expect(!index.contains(start, within: 86_400))
    }

    /// The lower bound can land past the end of the array, which is the one
    /// answer the search gives that is not an element.
    @Test("a timestamp after everything indexed is not contained")
    func pastTheEndIsNotContained() {
        let index = TimestampIndex([start, start.addingTimeInterval(10)])

        #expect(!index.contains(start.addingTimeInterval(20), within: 5))
        #expect(index.contains(start.addingTimeInterval(14), within: 4))
    }

    /// A tolerance below zero is clamped rather than inverted, so it asks for
    /// an exact match instead of quietly matching nothing.
    @Test("a negative tolerance is clamped to an exact match")
    func negativeToleranceIsClamped() {
        let index = TimestampIndex([start])

        #expect(index.contains(start, within: -5))
        #expect(!index.contains(start.addingTimeInterval(0.001), within: -5))
    }

    @Test("duplicate timestamps are matched like a single one")
    func duplicatesBehaveLikeOne() {
        let index = TimestampIndex([start, start, start.addingTimeInterval(10)])

        #expect(index.contains(start, within: 0))
        #expect(index.contains(start.addingTimeInterval(3), within: 3))
        #expect(!index.contains(start.addingTimeInterval(5), within: 4))
    }
}
