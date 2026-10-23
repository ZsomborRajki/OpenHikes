//
//  WatchTrailRunsTests.swift
//  OpenHikesSharedTests
//
//  Which of a trail's points the watch's map draws as trail, and which legs it
//  draws as a pause (#997). The map drew every point as one solid line, so the
//  drive between two recorded pieces looked like the trail the tracker was
//  measuring along. The watch has no test bundle, so the whole decision is
//  here: `TrailMapScreen` only turns these indices into coordinates.
//

import Foundation
@testable import OpenHikesShared
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Watch trail runs")
struct WatchTrailRunsTests {
    /// A trail of `count` points about a hundred metres apart along the
    /// equator, paused where `pauses` says.
    private static func trail(count: Int, pauses: [Int]) -> WatchTrailPackage {
        WatchTrailPackage(
            hikeID: UUID(),
            title: "Pieces",
            tintHex: "#1B7F3B",
            totalDistanceMeters: 1000,
            points: (0..<count).map { WatchTrailPoint(latitude: 0, longitude: Double($0) * 0.001) },
            pauseIndices: pauses
        )
    }

    @Test("a trail with no pause is one run of every point")
    func unpausedTrailIsOneRun() {
        let trail = Self.trail(count: 4, pauses: [])

        #expect(trail.walkedRuns == [0..<4])
        #expect(trail.pausedLegs.isEmpty)
    }

    @Test("a pause cuts the line in two, and the leg across it is drawn as the pause")
    func onePauseMakesTwoRuns() {
        let trail = Self.trail(count: 4, pauses: [2])

        #expect(trail.walkedRuns == [0..<2, 2..<4])
        #expect(trail.pausedLegs == [1])
    }

    @Test("every pause cuts the line again")
    func multiplePausesMakeARunEach() {
        let trail = Self.trail(count: 8, pauses: [2, 5])

        #expect(trail.walkedRuns == [0..<2, 2..<5, 5..<8])
        #expect(trail.pausedLegs == [1, 4])
    }

    @Test("a point between two adjacent pauses is not a run, and both legs are paused")
    func adjacentPausesLeaveNoSinglePointRun() {
        let trail = Self.trail(count: 6, pauses: [2, 3])

        #expect(trail.walkedRuns == [0..<2, 3..<6])
        #expect(trail.pausedLegs == [1, 2])
    }

    @Test("a pause on the first or last leg leaves no single point at either end")
    func pausesAtTheEndsLeaveNoSinglePointRun() {
        let trail = Self.trail(count: 5, pauses: [1, 4])

        #expect(trail.walkedRuns == [1..<4])
        #expect(trail.pausedLegs == [0, 3])
    }

    @Test("a trail paused on every leg has nothing walked to draw")
    func everyLegPausedHasNoRun() {
        let trail = Self.trail(count: 3, pauses: [1, 2])

        #expect(trail.walkedRuns.isEmpty)
        #expect(trail.pausedLegs == [0, 1])
    }

    @Test("an index the line cannot hold is ignored, and a repeat counts once")
    func indicesOutsideTheLineAreIgnored() {
        let trail = Self.trail(count: 5, pauses: [3, 0, 3, 9, -1])

        #expect(trail.walkedRuns == [0..<3, 3..<5])
        #expect(trail.pausedLegs == [2])
    }

    @Test(
        "every leg is drawn exactly once, as trail or as a pause",
        arguments: [[], [2], [2, 5], [2, 3], [1, 7], [1, 2, 3], [4, 4, 6]]
    )
    func everyLegIsDrawnOnce(pauses: [Int]) {
        let trail = Self.trail(count: 8, pauses: pauses)

        let walked = trail.walkedRuns.flatMap { $0.dropLast() }
        let drawn = (walked + trail.pausedLegs).sorted()

        #expect(drawn == Array(0..<7))
        #expect(trail.walkedRuns.allSatisfy { $0.count > 1 })
    }

    @Test("the tracker refuses exactly the legs the map draws as a pause")
    func trackerAgreesWithTheMap() throws {
        // Two walked pieces a kilometre apart, joined by two paused legs
        // meeting at a lone point: the adjacent-pause case, where a map and a
        // tracker that read the indices differently would disagree first.
        let trail = WatchTrailPackage(
            hikeID: UUID(),
            title: "Pieces",
            tintHex: "#1B7F3B",
            totalDistanceMeters: 300,
            points: [0, 0.001, 0.010, 0.020, 0.021, 0.022].map { WatchTrailPoint(latitude: 0, longitude: $0) },
            pauseIndices: [2, 3]
        )
        var tracker = WatchRouteTracker(trail)

        for leg in trail.pausedLegs {
            let middle = (trail.points[leg].longitude + trail.points[leg + 1].longitude) / 2
            let reading = tracker.advance(latitude: 0, longitude: middle)
            let paused = try #require(reading)
            #expect(!paused.isOnTrail, "paused leg \(leg) was matched")
        }
        for run in trail.walkedRuns {
            for leg in run.dropLast() {
                let middle = (trail.points[leg].longitude + trail.points[leg + 1].longitude) / 2
                let reading = tracker.advance(latitude: 0, longitude: middle)
                let walked = try #require(reading)
                #expect(walked.isOnTrail, "walked leg \(leg) was refused")
            }
        }
    }
}

// swiftlint:enable no_magic_numbers
