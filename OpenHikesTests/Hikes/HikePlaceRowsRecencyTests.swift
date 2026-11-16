//
//  HikePlaceRowsRecencyTests.swift
//  OpenHikesTests
//
//  Which hikes' anchors are kept: the most recently read, up to
//  ``HikePlaceRows/keptHikes``. A read moves its hike to the most recent, an
//  answer landing from off the main actor does not, and an answer about a
//  hike no longer kept is dropped without stopping it from asking again.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Synchronization
import Testing

@MainActor
@Suite("Hike place row recency")
struct HikePlaceRowsRecencyTests {
    /// Every place measured, by id, so each hike's measurements can be
    /// counted apart, and the places whose measurement has finished.
    nonisolated private final class Tally: Sendable {
        private struct Log {
            var measured: [UUID] = []
            var finished: [UUID] = []
        }

        private let log = Mutex(Log())

        /// How often `hike`'s places have been sent to be measured.
        func times(_ hike: Owner) -> Int {
            let ids = Set(hike.places.map(\.id))
            return log.withLock { log in log.measured.count { ids.contains($0) } }
        }

        /// How often a measurement of `hike`'s places has finished.
        func finished(_ hike: Owner) -> Int {
            let ids = Set(hike.places.map(\.id))
            return log.withLock { log in log.finished.count { ids.contains($0) } }
        }

        func measure(_ places: [TrailPlace], _ route: [RouteCoordinate]) -> [UUID: TrailPlaceAnchor] {
            log.withLock { $0.measured += places.map(\.id) }
            let anchors = TrailPlaceOrder.anchors(of: places, along: route)
            log.withLock { $0.finished += places.map(\.id) }
            return anchors
        }
    }

    /// One hike's places and line, as a screen hands them to the rows.
    nonisolated struct Owner {
        let id = UUID()
        let route: [RouteCoordinate]
        let places = [TrailPlace(latitude: 47.601, longitude: 12.98, name: "Spring")]

        /// One segment: inside the budget, so measured in the read.
        static func short() -> Self {
            Self(route: [
                RouteCoordinate(latitude: 47.60, longitude: 12.98),
                RouteCoordinate(latitude: 47.602, longitude: 12.98),
            ])
        }

        /// Four hundred points: past the budget, so measured off the main
        /// actor.
        static func long() -> Self {
            Self(route: (0..<400).map { index in
                RouteCoordinate(latitude: 47.60 + Double(index) * 0.00001, longitude: 12.98)
            })
        }
    }

    /// Bound while a read sends its request off the main actor, so the
    /// request's task inherits it as a task-local value and holds it until
    /// the task ends, which is after its answer has landed or been dropped.
    nonisolated private final class Witness: Sendable {
        @TaskLocal static var current: Witness?
    }

    private let tally: Tally
    private let rows: HikePlaceRows

    init() {
        let counter = Tally()
        tally = counter
        rows = HikePlaceRows(budget: 10) { places, route in counter.measure(places, route) }
    }

    @discardableResult private func read(_ hike: Owner) -> [TrailPlaceRow] {
        rows.rows(of: hike.places, along: hike.route, for: hike.id)
    }

    @Test("as many hikes as are kept are reused, and one more evicts the least recently read")
    func boundEvictsTheLeastRecentlyRead() {
        let hikes = (0...HikePlaceRows.keptHikes).map { _ in Owner.short() }
        let kept = hikes.dropLast()

        for _ in 0..<2 {
            for hike in kept { read(hike) }
        }
        #expect(kept.allSatisfy { tally.times($0) == 1 }, "every hike kept was measured once")

        read(hikes[HikePlaceRows.keptHikes])
        read(hikes[0])
        #expect(tally.times(hikes[0]) == 2, "the least recently read was evicted, and measures again")
        #expect(hikes.dropFirst(2).allSatisfy { tally.times($0) == 1 })
    }

    @Test("a read moves its hike to the most recent")
    func readMovesItsHikeToTheMostRecent() {
        let hikes = (0...HikePlaceRows.keptHikes).map { _ in Owner.short() }

        for hike in hikes.dropLast() { read(hike) }
        read(hikes[0])
        read(hikes[HikePlaceRows.keptHikes])

        read(hikes[0])
        #expect(tally.times(hikes[0]) == 1, "read again just before, so kept")
        read(hikes[1])
        #expect(tally.times(hikes[1]) == 2, "the least recently read once the first was read again")
    }

    @Test("an answer landing does not move its hike to the most recent")
    func landingLeavesTheOrderAlone() async {
        let far = Owner.long()
        let others = (0..<HikePlaceRows.keptHikes).map { _ in Owner.short() }

        read(far)
        for hike in others.dropLast() { read(hike) }
        await settleDelegateHop(until: "the long line's anchors land") { rows.revision == 1 }
        read(others[HikePlaceRows.keptHikes - 1])

        read(others[0])
        #expect(tally.times(others[0]) == 1, "read after the long line, so kept")
        read(far)
        await settleDelegateHop(until: "the long line, evicted, is asked about again") { tally.times(far) == 2 }
        await settleDelegateHop(until: "its second answer lands") { rows.revision == 2 }
    }

    @Test("an answer about a hike evicted while it was out is dropped")
    func answerAfterEvictionIsDropped() async throws {
        let far = Owner.long()

        // A dropped answer leaves nothing behind to wait for, and the hop
        // that lands it is queued only once the measurement has returned,
        // from the thread that ran it, so no number of round trips after the
        // measurement is sure to follow it. What is waited for is the
        // request's task ending, which lets go of the witness it inherited.
        weak var request: Witness?
        do {
            let witness = Witness()
            request = witness
            Witness.$current.withValue(witness) { _ = read(far) }
        }
        try #require(request != nil, "the request out holds the witness")
        for _ in 0..<HikePlaceRows.keptHikes { read(Owner.short()) }
        await settleDelegateHop(until: "the long line's request has ended") { request == nil }
        #expect(rows.revision == 0, "nothing kept the hike it was about")

        read(far)
        await settleDelegateHop(until: "the long line is measured again and lands") { rows.revision == 1 }
        #expect(tally.times(far) == 2)
        #expect(try #require(read(far).first).anchor != nil)
    }

    @Test("a hike evicted while its answer is out asks again when read before it lands")
    func evictionForgetsTheRequestOut() async throws {
        let far = Owner.long()

        read(far)
        for _ in 0..<HikePlaceRows.keptHikes { read(Owner.short()) }
        read(far)

        await settleDelegateHop(until: "the long line is asked about again") { tally.times(far) == 2 }
        await settleDelegateHop(until: "both answers are measured and one lands") {
            tally.finished(far) == 2 && rows.revision >= 1
        }
        #expect(try #require(read(far).first).anchor != nil)
    }
}
