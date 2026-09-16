//
//  RecordingDistanceTests.swift
//  OpenHikesTests
//
//  "Recording distance", split out of RecordingFixPolicyTests.swift so that a
//  file declares one @Suite.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Recording distance")
struct RecordingDistanceTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("ten minutes of stationary jitter adds less than five metres")
    func stationaryJitterDoesNotInflateDistance() {
        var accumulator = RecordingDistanceAccumulator()
        for step in 0...60 {
            let offsetMeters = Double((step % 3) - 1) * 3
            accumulator.append(
                RecordingPoint(
                    latitude: 47.63 + offsetMeters / 111_000,
                    longitude: 12.86,
                    timestamp: start.addingTimeInterval(Double(step) * 10),
                    horizontalAccuracy: 8
                )
            )
        }

        #expect(accumulator.isStationary)
        #expect(accumulator.distanceMeters < 5)
    }

    @Test("motion activity corroborates stationary GPS drift")
    func motionStationarySignalRetractsWiderDrift() {
        var accumulator = RecordingDistanceAccumulator()
        for step in 0...4 {
            accumulator.append(
                RecordingPoint(
                    latitude: 47.63 + Double(step) * 10 / 111_000,
                    longitude: 12.86,
                    timestamp: start.addingTimeInterval(Double(step) * 10),
                    horizontalAccuracy: 20,
                    flags: [.motionStationary]
                )
            )
        }

        #expect(accumulator.isStationary)
        #expect(accumulator.distanceMeters < 1)
    }

    @Test("stationary activity does not retract the approach to a stop")
    func stationarySignalKeepsEarlierMovement() {
        var accumulator = RecordingDistanceAccumulator()
        accumulator.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: start,
                horizontalAccuracy: 8
            )
        )
        accumulator.append(
            RecordingPoint(
                latitude: 47.63 + 100.0 / 111_000,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(20),
                horizontalAccuracy: 8
            )
        )
        accumulator.append(
            RecordingPoint(
                latitude: 47.63 + 100.0 / 111_000,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(25),
                horizontalAccuracy: 8,
                flags: [.motionStationary]
            )
        )
        accumulator.append(
            RecordingPoint(
                latitude: 47.63 + 103.0 / 111_000,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(55),
                horizontalAccuracy: 8,
                flags: [.motionStationary]
            )
        )

        #expect(accumulator.isStationary)
        #expect(abs(accumulator.distanceMeters - 100) < 2)
    }

    @Test("average speed ignores the time a pause took out of the hike")
    func averageSpeedExcludesPausedTime() {
        var accumulator = RecordingDistanceAccumulator()
        // 111 m in 60 s, an hour's pause, then 111 m in 60 s again: 1.85 m/s
        // moving, but barely 0.06 m/s if the lunch stop is counted.
        let legs: [(Double, TimeInterval, RecordingPointFlags)] = [
            (47.63, 0, []),
            (47.631, 60, []),
            (47.64, 3660, .resumed),
            (47.641, 3720, []),
        ]
        for (latitude, offset, flags) in legs {
            accumulator.append(
                RecordingPoint(
                    latitude: latitude,
                    longitude: 12.86,
                    timestamp: start.addingTimeInterval(offset),
                    horizontalAccuracy: 8,
                    flags: flags
                )
            )
        }

        #expect(accumulator.recordedDuration == 120)
        let speed = accumulator.averageSpeedMetersPerSecond ?? 0
        #expect(abs(speed - 1.85) < 0.05)
    }

    @Test("the first point after resume does not bridge the paused gap")
    func pauseGapIsNotDistance() throws {
        let points = [
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: start,
                horizontalAccuracy: 8
            ),
            RecordingPoint(
                latitude: 47.631,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(60),
                horizontalAccuracy: 8
            ),
            RecordingPoint(
                latitude: 47.64,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(600),
                horizontalAccuracy: 8,
                flags: .resumed
            ),
            RecordingPoint(
                latitude: 47.641,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(660),
                horizontalAccuracy: 8
            ),
        ]

        let prepared = try RecordingPreparation.prepare(
            points: points,
            startedAt: start
        )

        #expect(abs(prepared.distanceMeters - 222) < 5)
    }

    @Test("resume clears the pre-pause motion-stationary window")
    func resumeClearsMotionStationaryWindow() {
        var accumulator = RecordingDistanceAccumulator()
        accumulator.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: start,
                horizontalAccuracy: 8,
                flags: [.motionStationary]
            )
        )
        accumulator.append(
            RecordingPoint(
                latitude: 47.6301,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(20),
                horizontalAccuracy: 8,
                flags: [.motionStationary]
            )
        )
        accumulator.append(
            RecordingPoint(
                latitude: 47.64,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(3600),
                horizontalAccuracy: 8,
                flags: [.resumed]
            )
        )
        accumulator.append(
            RecordingPoint(
                latitude: 47.6401,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(3610),
                horizontalAccuracy: 8,
                flags: [.motionStationary]
            )
        )

        #expect(!accumulator.isStationary)
    }

    @Test("alternating motion flags restart stationary detection")
    func alternatingMotionFlagsRestartDetection() {
        var accumulator = RecordingDistanceAccumulator()
        let samples: [(TimeInterval, Double, RecordingPointFlags)] = [
            (0, 47.6300, [.motionStationary]),
            (10, 47.6301, []),
            (20, 47.6302, [.motionStationary]),
            (40, 47.6304, [.motionStationary]),
        ]
        for (offset, latitude, flags) in samples {
            accumulator.append(
                RecordingPoint(
                    latitude: latitude,
                    longitude: 12.86,
                    timestamp: start.addingTimeInterval(offset),
                    horizontalAccuracy: 8,
                    flags: flags
                )
            )
        }
        #expect(!accumulator.isStationary)

        accumulator.append(
            RecordingPoint(
                latitude: 47.6305,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(50),
                horizontalAccuracy: 8,
                flags: [.motionStationary]
            )
        )
        #expect(accumulator.isStationary)
    }

    // MARK: The climb the widget publishes

    /// Cumulative, not the difference between the highest and lowest fix: a
    /// walk that goes up 40 m, back down 40 m and up 40 m again has climbed
    /// 80 m, and reporting the 40 m span would understate every undulating
    /// walk there is.
    @Test("climb is summed over every rise, not measured between extremes")
    func climbIsCumulative() throws {
        var accumulator = RecordingDistanceAccumulator()
        for (step, elevation) in [500.0, 540, 500, 540].enumerated() {
            accumulator.append(walkingPoint(step: step, elevation: elevation))
        }

        #expect(try #require(accumulator.elevationGainMeters) == 80)
    }

    /// One height is a position, not a change. Claiming "0 m climbed" from a
    /// single fix would put a chip on the widget the data can't support.
    @Test("a single altitude is not yet a climb")
    func oneAltitudeIsNotAClimb() {
        var accumulator = RecordingDistanceAccumulator()
        accumulator.append(walkingPoint(step: 0, elevation: 500))

        #expect(accumulator.elevationGainMeters == nil)
    }

    /// A recording indoors, or on a phone whose altitude never passes the
    /// filter, reports no climb rather than a flat zero.
    @Test("fixes without altitudes report no climb")
    func noAltitudesMeansNoClimb() {
        var accumulator = RecordingDistanceAccumulator()
        for step in 0..<5 {
            accumulator.append(walkingPoint(step: step, elevation: nil))
        }

        #expect(accumulator.elevationGainMeters == nil)
    }

    /// Distance is retracted when GPS wanders in place; climb is not. The
    /// altitude filter has already smoothed the vertical, and subtracting a
    /// rise the hiker's legs may genuinely have made is the larger error.
    @Test("a stationary window retracts distance but keeps the climb")
    func stationaryWindowKeepsTheClimb() throws {
        var accumulator = RecordingDistanceAccumulator()
        for step in 0...60 {
            let offsetMeters = Double((step % 3) - 1) * 3
            accumulator.append(
                RecordingPoint(
                    latitude: 47.63 + offsetMeters / 111_000,
                    longitude: 12.86,
                    timestamp: start.addingTimeInterval(Double(step) * 10),
                    horizontalAccuracy: 8,
                    elevation: 500 + Double(step)
                )
            )
        }

        #expect(accumulator.isStationary)
        #expect(accumulator.distanceMeters < 5)
        #expect(try #require(accumulator.elevationGainMeters) == 60)
    }

    private func walkingPoint(step: Int, elevation: Double?) -> RecordingPoint {
        RecordingPoint(
            latitude: 47.63 + Double(step) * 100 / 111_000,
            longitude: 12.86,
            timestamp: start.addingTimeInterval(Double(step) * 60),
            horizontalAccuracy: 8,
            elevation: elevation
        )
    }
}
