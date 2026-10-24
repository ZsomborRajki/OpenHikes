//
//  TrailRunsTests.swift
//  OpenHikesSharedTests
//
//  The one reading of a line's pauses (#962, #1035), at every edge the
//  readings that came before it disagreed about: no pause, one, two adjacent,
//  a pause on the first and on the last leg, a line made only of lone fixes,
//  one point and none. Each case states every view the type gives, because
//  each has a consumer that iterates it instead of the legs: the profile and
//  the watch skip ``TrailRuns/pausedLegs``, a place's anchor walks
//  ``TrailRuns/walkedLegs``, a waypoint's track measures
//  ``TrailRuns/loneFixes`` as points, and the steepness colours and the
//  photo timeline go piece by piece.
//

@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Trail runs")
struct TrailRunsTests {
    /// Everything a ``TrailRuns`` says, in one value to compare.
    private struct Reading: Equatable {
        var pausedLegs: [Int]
        var pieces: [Range<Int>]
        var walkedRuns: [Range<Int>]
        var walkedLegs: [Int]
        var loneFixes: [Int]
        var pausedStretches: [Range<Int>]
    }

    private static func reading(_ pointCount: Int, pauses: [Int]) -> Reading {
        let runs = TrailRuns(pointCount: pointCount, pauseIndices: pauses)
        return Reading(
            pausedLegs: runs.pausedLegs,
            pieces: runs.pieces,
            walkedRuns: runs.walkedRuns,
            walkedLegs: Array(runs.walkedLegs),
            loneFixes: runs.loneFixes,
            pausedStretches: runs.pausedStretches
        )
    }

    @Test("a line with no pause is one piece, every leg of it walked")
    func noPause() {
        #expect(Self.reading(4, pauses: []) == Reading(
            pausedLegs: [],
            pieces: [0..<4],
            walkedRuns: [0..<4],
            walkedLegs: [0, 1, 2],
            loneFixes: [],
            pausedStretches: []
        ))
        #expect(!TrailRuns(pointCount: 4, pauseIndices: []).isPaused)
    }

    @Test("a pause names the point it arrives at, and the leg before that point is the pause")
    func onePause() {
        #expect(Self.reading(4, pauses: [2]) == Reading(
            pausedLegs: [1],
            pieces: [0..<2, 2..<4],
            walkedRuns: [0..<2, 2..<4],
            walkedLegs: [0, 2],
            loneFixes: [],
            pausedStretches: [1..<3]
        ))
        #expect(TrailRuns(pointCount: 4, pauseIndices: [2]).isPaused)
    }

    @Test("the point between two adjacent pauses is a lone fix: a piece, but no walked run")
    func adjacentPauses() {
        #expect(Self.reading(6, pauses: [2, 3]) == Reading(
            pausedLegs: [1, 2],
            pieces: [0..<2, 2..<3, 3..<6],
            walkedRuns: [0..<2, 3..<6],
            walkedLegs: [0, 3, 4],
            loneFixes: [2],
            pausedStretches: [1..<4]
        ))
    }

    @Test("a pause on the first or the last leg leaves that end's point a lone fix")
    func pausesOnTheEndLegs() {
        #expect(Self.reading(5, pauses: [1, 4]) == Reading(
            pausedLegs: [0, 3],
            pieces: [0..<1, 1..<4, 4..<5],
            walkedRuns: [1..<4],
            walkedLegs: [1, 2],
            loneFixes: [0, 4],
            pausedStretches: [0..<2, 3..<5]
        ))
    }

    @Test("a line paused on every leg is all lone fixes, with nothing walked")
    func onlyLoneFixes() {
        #expect(Self.reading(3, pauses: [1, 2]) == Reading(
            pausedLegs: [0, 1],
            pieces: [0..<1, 1..<2, 2..<3],
            walkedRuns: [],
            walkedLegs: [],
            loneFixes: [0, 1, 2],
            pausedStretches: [0..<3]
        ))
    }

    @Test("a line of one point is one lone fix, and a line of none is nothing")
    func onePointAndNone() {
        #expect(Self.reading(1, pauses: []) == Reading(
            pausedLegs: [],
            pieces: [0..<1],
            walkedRuns: [],
            walkedLegs: [],
            loneFixes: [0],
            pausedStretches: []
        ))
        #expect(Self.reading(0, pauses: [0, 1]) == Reading(
            pausedLegs: [],
            pieces: [],
            walkedRuns: [],
            walkedLegs: [],
            loneFixes: [],
            pausedStretches: []
        ))
    }

    @Test("a pause on the first point, past the end, or named twice changes nothing it cannot")
    func untrustedIndicesAreDropped() {
        #expect(Self.reading(4, pauses: [0, 2, 2, 4, -1]) == Self.reading(4, pauses: [2]))
        #expect(Self.reading(4, pauses: [3, 1]) == Self.reading(4, pauses: [1, 3]), "in any order")
    }

    @Test("the pieces cover every point once, and the walked legs and paused legs every leg once")
    func everyPointAndLegOnce() {
        for (count, pauses) in [(1, [Int]()), (6, [2, 3]), (5, [1, 4]), (3, [1, 2]), (9, [1, 3, 4, 8])] {
            let runs = TrailRuns(pointCount: count, pauseIndices: pauses)

            #expect(runs.pieces.flatMap { Array($0) } == Array(0..<count), "\(count) points, \(pauses)")
            #expect(
                (Array(runs.walkedLegs) + runs.pausedLegs).sorted() == Array(0..<max(0, count - 1)),
                "\(count) points, \(pauses)"
            )
        }
    }
}

// swiftlint:enable no_magic_numbers
