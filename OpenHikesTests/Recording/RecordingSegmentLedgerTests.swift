//
//  RecordingSegmentLedgerTests.swift
//  OpenHikesTests
//
//  The segments a recording's pauses have cut it into so far (#1470), read
//  off the accumulator every kept fix passes through: so the segments add up
//  to the figures shown above them, and a journal replayed after a crash
//  reaches the same ones.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Recording segments")
struct RecordingSegmentLedgerTests {
    private static let secondsPerFix: TimeInterval = 60
    private static let lunch: TimeInterval = 1800
    private static let degreesPerFix = 0.001
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// One fix a minute and about a hundred metres apart, at `heights`. Each
    /// index in `resumed` is the first fix after half an hour's pause,
    /// flagged the way the recorder writes it.
    private func walk(_ heights: [Double], resumingAt resumed: Set<Int> = []) -> [RecordingPoint] {
        var seconds: TimeInterval = 0
        return heights.indices.map { index in
            if index > 0 { seconds += resumed.contains(index) ? Self.lunch : Self.secondsPerFix }
            return RecordingPoint(
                latitude: 47.63 + Double(index) * Self.degreesPerFix,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(seconds),
                horizontalAccuracy: 5,
                elevation: heights[index],
                flags: resumed.contains(index) ? .resumed : []
            )
        }
    }

    private func accumulator(_ points: [RecordingPoint]) -> RecordingDistanceAccumulator {
        var accumulator = RecordingDistanceAccumulator()
        for point in points {
            accumulator.append(point)
        }
        return accumulator
    }

    @Test("a walk nothing has paused shows no segments")
    func onePiece() {
        let accumulator = accumulator(walk([500, 510, 520, 530]))

        #expect(accumulator.segments.shown.isEmpty)
    }

    @Test("a pause ends a segment, with the stop's length, and begins the next")
    func aPauseCutsTheWalk() throws {
        let accumulator = accumulator(walk([500, 520, 540, 540, 530, 560], resumingAt: [3]))

        let segments = accumulator.segments.shown
        try #require(segments.count == 2)
        #expect(segments[0].seconds == 2 * Self.secondsPerFix)
        #expect(segments[0].elevationGainMeters == 40)
        #expect(segments[0].stopSeconds == Self.lunch)
        #expect(segments[1].seconds == 2 * Self.secondsPerFix)
        #expect(segments[1].elevationGainMeters == 30)
        #expect(segments[1].stopSeconds == nil, "the segment in progress has no stop after it")
    }

    @Test("the segments add up to the figures shown above them")
    func segmentsAddUpToTheTotals() {
        let accumulator = accumulator(
            walk([500, 520, 540, 540, 530, 560, 560, 580], resumingAt: [3, 6])
        )

        let segments = accumulator.segments.shown
        let distance = segments.reduce(0) { $0 + $1.distanceMeters }
        let seconds = segments.reduce(0) { $0 + ($1.seconds ?? 0) }
        let climb = segments.reduce(0) { $0 + ($1.elevationGainMeters ?? 0) }
        #expect(segments.count == 3)
        #expect(distance.isApproximatelyEqual(to: accumulator.distanceMeters, absoluteTolerance: 0.001))
        #expect(seconds == accumulator.recordedDuration)
        #expect(climb == accumulator.elevationGainMeters)
    }

    /// A stop begun on the recording's first fix: the fix is alone, with a
    /// pause after it, and walked nothing.
    @Test("a lone fix before a pause is no segment")
    func loneFix() {
        let accumulator = accumulator(walk([500, 500, 520, 540], resumingAt: [1]))

        #expect(accumulator.segments.shown.isEmpty, "one walked run is the walk itself")
    }

    /// A resume that took one fix before the next pause: the stop runs from
    /// the end of the segment before it to the start of the one after, and
    /// the saved hike's segments say the same of the same points.
    @Test("a lone fix between two pauses is inside one stop, as on the saved hike")
    func loneFixBetweenPauses() throws {
        let points = walk([500, 510, 520, 520, 530, 540], resumingAt: [2, 3])
        let accumulator = accumulator(points)

        let live = accumulator.segments.shown
        let saved = RouteSegments.segments(
            of: points.map(\.routeCoordinate),
            distanceMeters: accumulator.distanceMeters
        )
        try #require(live.count == 2)
        #expect(live[0].stopSeconds == 2 * Self.lunch)
        #expect(live.map(\.stopSeconds) == saved.map(\.stopSeconds))
    }

    /// A fix `meters` up the path, `seconds` in.
    private func fix(
        _ meters: Double,
        at seconds: TimeInterval,
        elevation: Double? = nil,
        resumed: Bool = false
    ) -> RecordingPoint {
        RecordingPoint(
            latitude: 47.63 + meters / 111_195,
            longitude: 12.86,
            timestamp: start.addingTimeInterval(seconds),
            horizontalAccuracy: 5,
            elevation: elevation,
            flags: resumed ? .resumed : []
        )
    }

    /// Each walk a way the two used to disagree: a photo stop the recording
    /// took its wander back from, a segment with no heights, a lone fix at
    /// the end, and more pieces than a walk has stops.
    @Test("the segments shown while recording are the ones the saved hike shows")
    func liveIsSaved() {
        let approach = stride(from: 0.0, through: 500, by: 100).map { fix($0, at: $0, elevation: 500 + $0 / 10) }
        let photoStop = (1...12).map { step in
            fix(500 + Double(step % 3) * 4, at: 500 + Double(step) * 10, elevation: 550)
        }
        let onward = stride(from: 600.0, through: 1100, by: 100).map { meters in
            fix(meters, at: meters + 1800, elevation: 560 + meters / 10, resumed: meters == 600)
        }
        let walks: [String: [RecordingPoint]] = [
            "a photo stop": approach + photoStop + onward,
            "no heights after the stop": approach + onward.map { point in
                var unmeasured = point
                unmeasured.elevation = nil
                return unmeasured
            },
            "a lone fix at the end": approach + onward + [fix(1200, at: 4000, resumed: true)],
            "thirty-one pieces": (0..<62).map { index in
                fix(Double(index) * 50, at: Double(index) * 600, resumed: index > 0 && index.isMultiple(of: 2))
            },
        ]

        for (name, points) in walks {
            let accumulator = accumulator(points)
            let saved = RouteSegments.segments(
                of: points.map(\.routeCoordinate),
                distanceMeters: accumulator.distanceMeters
            )
            #expect(accumulator.segments.shown == saved, "\(name)")
        }
        #expect(accumulator(walks["a photo stop"] ?? []).segments.shown.count == 2)
        #expect(accumulator(walks["thirty-one pieces"] ?? []).segments.shown.isEmpty)
    }

    @Test("a walk with no heights has segments with no climb")
    func noHeights() throws {
        var points = walk([0, 0, 0, 0], resumingAt: [2])
        for index in points.indices {
            points[index].elevation = nil
        }

        let first = try #require(accumulator(points).segments.shown.first)
        #expect(first.elevationGainMeters == nil)
        #expect(first.distanceMeters > 0)
    }
}
