//
//  LibraryTotalsOverlapTests.swift
//  OpenHikesTests
//
//  How much of a followed walk the recordings' clocks take out, worked out
//  once for the whole library (#1118) and held to the per-walk scan it
//  replaced — the proportional-overlap policy of #696 — which is kept here
//  as the oracle.
//
//  Every time is a whole number of minutes from one reference date, so both
//  sides subtract and add exactly, and the outings are compared with `==`
//  rather than to a tolerance: a share that came out a few ulps over zero
//  would count a walk wholly inside a recording as an outing.
//

import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Library totals: recording overlap")
struct LibraryTotalsOverlapTests {
    private static let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let trail = UUID()

    private static func at(_ minutes: Int) -> Date {
        origin.addingTimeInterval(TimeInterval(minutes * 60))
    }

    private static func recording(_ start: Int, _ end: Int) -> LibraryHikeFacts {
        LibraryHikeFacts(
            hikeID: UUID(),
            title: "Recording",
            date: at(start),
            distanceMeters: 1000,
            climbMeters: 50,
            highestMeters: 900,
            movingSeconds: TimeInterval((end - start) * 60),
            clock: DateInterval(start: at(start), end: at(end)),
            isFromCommunity: false
        )
    }

    private static func walk(_ start: Int, _ end: Int) -> LibraryWalkFacts {
        LibraryWalkFacts(
            hikeID: trail,
            startedAt: at(start),
            endedAt: at(end),
            coveredMeters: 6000,
            walkedMeters: 7000,
            activeSeconds: TimeInterval(max(0, end - start) * 60),
            climbMeters: 400,
            isRecordingsOwn: false,
            trailHasChanged: false
        )
    }

    /// The trail the walks follow: in the library, and never walked itself.
    private static let savedTrail = LibraryHikeFacts(
        hikeID: trail,
        title: "Trail",
        date: at(-100_000),
        distanceMeters: 6000,
        climbMeters: 400,
        highestMeters: 1200,
        movingSeconds: nil,
        clock: nil,
        isFromCommunity: false
    )

    // MARK: Named shapes

    /// One walk from minute 0 to 240, with the recordings' clocks laid over it.
    nonisolated struct Shape: CustomTestStringConvertible, Sendable {
        let name: String
        let clocks: [ClosedRange<Int>]
        /// The minutes of the walk no clock covers.
        let unrecordedMinutes: Int

        var testDescription: String { name }
    }

    nonisolated static let shapes: [Shape] = [
        Shape(name: "no recording", clocks: [], unrecordedMinutes: 240),
        Shape(name: "disjoint", clocks: [300...360, 250...280], unrecordedMinutes: 240),
        Shape(name: "touching the walk's ends only", clocks: [-60...0, 240...300], unrecordedMinutes: 240),
        Shape(name: "inside", clocks: [60...70], unrecordedMinutes: 230),
        Shape(name: "over the start", clocks: [-30...30], unrecordedMinutes: 210),
        Shape(name: "over the end", clocks: [210...270], unrecordedMinutes: 210),
        Shape(name: "overlapping", clocks: [0...60, 30...90], unrecordedMinutes: 150),
        Shape(name: "nested", clocks: [20...200, 50...80, 100...120], unrecordedMinutes: 60),
        Shape(name: "adjacent", clocks: [0...60, 60...120], unrecordedMinutes: 120),
        Shape(name: "out of order", clocks: [180...200, 10...20, 100...150], unrecordedMinutes: 160),
        Shape(name: "an instant", clocks: [100...100], unrecordedMinutes: 240),
        Shape(name: "the whole walk", clocks: [-10...250], unrecordedMinutes: 0),
        Shape(
            name: "the whole walk, in overlapping pieces",
            clocks: [0...100, 90...200, 150...240],
            unrecordedMinutes: 0
        ),
        Shape(name: "the whole walk, end to end", clocks: [0...80, 80...160, 160...240], unrecordedMinutes: 0),
    ]

    @Test("a recording's clock takes out its own minutes of a walk", arguments: shapes)
    func shapeTakesOutItsMinutes(_ shape: Shape) throws {
        let hikes = [Self.savedTrail] + shape.clocks.map { Self.recording($0.lowerBound, $0.upperBound) }
        let walks = [Self.walk(0, 240)]

        let outings = LibraryTotals.outings(hikes: hikes, walks: walks)

        #expect(outings == Self.scanned(hikes: hikes, walks: walks))
        let walked = outings.filter(\.isWalk)
        if shape.unrecordedMinutes == 0 {
            #expect(walked.isEmpty)
        } else {
            // The share is a fraction of the walk's length, so a third of it
            // is not a whole number of seconds.
            #expect(walked.count == 1)
            let moving = try #require(walked.first).movingSeconds
            let unrecorded = TimeInterval(shape.unrecordedMinutes * 60)
            #expect(moving.isApproximatelyEqual(to: unrecorded, absoluteTolerance: 1e-6))
        }
    }

    @Test("a walk with no length is left whole, as before")
    func walkWithoutLength() {
        let hikes = [Self.savedTrail, Self.recording(0, 60)]
        let walks = [Self.walk(30, 30), Self.walk(50, 40)]

        #expect(LibraryTotals.outings(hikes: hikes, walks: walks) == Self.scanned(hikes: hikes, walks: walks))
    }

    // MARK: A whole library

    /// Hundreds of recordings and walks laid down at random over a few weeks,
    /// so that they overlap, nest and touch in every way at once.
    @Test("a library's outings are the per-walk scan's, walk for walk", arguments: [1, 7, 42, 1118])
    func libraryMatchesTheScan(seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        let span = 30 * 24 * 60
        let hikes = [Self.savedTrail] + (0..<300).map { _ in
            let start = Int.random(in: 0..<span, using: &generator)
            return Self.recording(start, start + Int.random(in: 0...300, using: &generator))
        }
        let walks = (0..<300).map { _ in
            let start = Int.random(in: 0..<span, using: &generator)
            return Self.walk(start, start + Int.random(in: 0...600, using: &generator))
        }

        let outings = LibraryTotals.outings(hikes: hikes, walks: walks)

        #expect(outings == Self.scanned(hikes: hikes, walks: walks), "seed \(seed)")
        let kept = outings.count(where: \.isWalk)
        #expect(kept > 0, "the library should keep some walks")
        #expect(kept < walks.count, "some walks should be wholly recorded")
    }

    // MARK: - The scan it replaced

    /// `LibraryTotals.outings(hikes:walks:)` as it was before #1118: every
    /// walk scans every counted clock and merges what overlaps it.
    private static func scanned(hikes: [LibraryHikeFacts], walks: [LibraryWalkFacts]) -> [LibraryOuting] {
        let counted = hikes.filter { $0.hasClock && !$0.isFromCommunity }
        let clocks = counted.compactMap(\.clock)
        let clocked = counted.map { hike in
            LibraryOuting(
                hikeID: hike.hikeID,
                date: hike.date,
                distanceMeters: hike.distanceMeters,
                walkedMeters: hike.distanceMeters,
                climbMeters: hike.climbMeters ?? 0,
                movingSeconds: hike.movingSeconds ?? 0,
                isWalk: false
            )
        }
        let followed = walks.compactMap { walk -> LibraryOuting? in
            guard !walk.isRecordingsOwn else { return nil }
            let share = scannedShare(of: walk, clocks: clocks)
            guard share > 0 else { return nil }
            return LibraryOuting(
                hikeID: walk.hikeID,
                date: walk.startedAt,
                distanceMeters: walk.coveredMeters * share,
                walkedMeters: walk.walkedMeters * share,
                climbMeters: walk.trailHasChanged ? nil : walk.climbMeters * share,
                movingSeconds: walk.activeSeconds * share,
                isWalk: true
            )
        }
        return clocked + followed
    }

    private static func scannedShare(of walk: LibraryWalkFacts, clocks: [DateInterval]) -> Double {
        let length = walk.endedAt.timeIntervalSince(walk.startedAt)
        guard length > 0 else { return 1 }
        let overlaps = clocks.compactMap { clock -> (start: Date, end: Date)? in
            let start = max(clock.start, walk.startedAt)
            let end = min(clock.end, walk.endedAt)
            return start < end ? (start, end) : nil
        }
        .sorted { $0.start < $1.start }
        var recorded: TimeInterval = 0
        var reach = walk.startedAt
        for overlap in overlaps where overlap.end > reach {
            recorded += overlap.end.timeIntervalSince(max(overlap.start, reach))
            reach = overlap.end
        }
        return max(0, 1 - recorded / length)
    }
}
