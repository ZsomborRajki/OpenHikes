//
//  TimestampIndexTests.swift
//  OpenTrailsSharedTests
//

import Foundation
@testable import OpenTrailsShared
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
}
