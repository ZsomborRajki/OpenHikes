//
//  TrailStopDropTests.swift
//  OpenHikesTests
//
//  Below iOS 27 a drop among the maker's stops arrives through `onMove`, as
//  offsets and a destination, and `TrailStopSlot.drop(in:moving:to:)` turns
//  it into the rows-and-target the iOS 27 container reports. So the two are
//  held to each other here, for every drop `onMove` can report on a list of
//  up to five rows: whatever the conversion says, `rearranged` must put the
//  rows where `Array.move(fromOffsets:toOffset:)` — `onMove`'s own meaning —
//  puts them.
//

import Foundation
@testable import OpenHikes
import SwiftUI
import Testing

@Suite("Trail stop drops below iOS 27")
struct TrailStopDropTests {
    @Test("every drop onMove can report lands where Array.move puts it", arguments: 1...5)
    func everyDropMatchesMove(_ count: Int) {
        let ids = (0..<count).map { "row-\($0)" }
        for mask in 1..<(1 << count) {
            let offsets = IndexSet((0..<count).filter { mask & (1 << $0) != 0 })
            for destination in 0...count {
                var expected = ids
                expected.move(fromOffsets: offsets, toOffset: destination)

                let drop = TrailStopSlot.drop(in: ids, moving: offsets, to: destination)
                let order = TrailStopSlot.rearranged(ids, moving: drop.sources, before: drop.before)
                #expect(order == expected, "\(Array(offsets)) put down at \(destination)")
            }
        }
    }

    @Test("a row put down where it stood stays there")
    func aRowPutBackStays() {
        let ids = ["start", "middle", "end"]
        let drop = TrailStopSlot.drop(in: ids, moving: [1], to: 1)
        #expect(drop.sources == ["middle"])
        #expect(drop.before == "end", "in front of the first row that did not move")
    }

    @Test("a row put down past the last one goes to the end")
    func aRowPastTheLastGoesToTheEnd() {
        let drop = TrailStopSlot.drop(in: ["start", "middle", "end"], moving: [0], to: 3)
        #expect(drop.sources == ["start"])
        #expect(drop.before == nil)
    }
}
