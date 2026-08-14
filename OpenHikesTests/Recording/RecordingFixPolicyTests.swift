//
//  RecordingFixPolicyTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

nonisolated private let recordingAltitude: CLLocationDistance = 600

nonisolated private func recordingLocation(
    timestamp: Date,
    latitude: Double = 47.63,
    longitude: Double = 12.86,
    accuracy: CLLocationAccuracy = 8,
    course: CLLocationDirection = -1,
    speed: CLLocationSpeed = -1
) -> CLLocation {
    CLLocation(
        coordinate: CLLocationCoordinate2D(
            latitude: latitude,
            longitude: longitude
        ),
        altitude: recordingAltitude,
        horizontalAccuracy: accuracy,
        verticalAccuracy: 5,
        course: course,
        speed: speed,
        timestamp: timestamp
    )
}

@Suite("Recording settings")
struct RecordingSettingsTests {
    @Test("defaults load without reading UserDefaults")
    func defaults() {
        let suite = "recording-settings-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults with suite \(suite)")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let options = RecordingSessionOptions.load(from: defaults)

        #expect(options == .defaults)
    }
}

@Suite("Recording fix policy")
struct RecordingFixPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("the first current precise fix is accepted")
    func acceptsFirstFix() {
        let fix = recordingLocation(timestamp: start)
        #expect(RecordingFixPolicy.accepts(fix, after: nil, now: start))
    }

    @Test("stale, imprecise and unprojectable fixes are refused")
    func rejectsInvalidFixes() {
        #expect(!RecordingFixPolicy.accepts(
            recordingLocation(timestamp: start.addingTimeInterval(-31)),
            after: nil,
            now: start
        ))
        #expect(!RecordingFixPolicy.accepts(
            recordingLocation(
                timestamp: start,
                accuracy: RecordingFixPolicy.maximumHorizontalAccuracy + 1
            ),
            after: nil,
            now: start
        ))
        #expect(!RecordingFixPolicy.accepts(
            recordingLocation(timestamp: start, latitude: 90),
            after: nil,
            now: start
        ))
    }

    @Test("small quick movements are gated but heartbeat points survive")
    func movementAndHeartbeatGates() {
        let first = RecordingPoint(
            location: recordingLocation(timestamp: start)
        )
        let twoMetersNorth = 2.0 / 111_000

        #expect(!RecordingFixPolicy.accepts(
            recordingLocation(
                timestamp: start.addingTimeInterval(5),
                latitude: 47.63 + twoMetersNorth
            ),
            after: first,
            now: start.addingTimeInterval(5)
        ))
        #expect(RecordingFixPolicy.accepts(
            recordingLocation(
                timestamp: start.addingTimeInterval(10),
                latitude: 47.63 + twoMetersNorth
            ),
            after: first,
            now: start.addingTimeInterval(10)
        ))
    }

    @Test("a real direction change keeps a close-spaced point")
    func bearingGate() {
        let first = RecordingPoint(
            location: recordingLocation(
                timestamp: start,
                course: 0,
                speed: 1
            )
        )
        let next = recordingLocation(
            timestamp: start.addingTimeInterval(2),
            latitude: 47.63001,
            course: 30,
            speed: 1
        )

        #expect(RecordingFixPolicy.accepts(
            next,
            after: first,
            now: next.timestamp
        ))
    }

    @Test("a teleport is refused unless the receiver reports the same motion")
    func speedSanityGate() {
        let first = RecordingPoint(
            location: recordingLocation(timestamp: start)
        )
        let farNorth = 100.0 / 111_000
        let timestamp = start.addingTimeInterval(5)

        #expect(!RecordingFixPolicy.accepts(
            recordingLocation(
                timestamp: timestamp,
                latitude: 47.63 + farNorth,
                speed: 1
            ),
            after: first,
            now: timestamp
        ))
        #expect(RecordingFixPolicy.accepts(
            recordingLocation(
                timestamp: timestamp,
                latitude: 47.63 + farNorth,
                speed: 20
            ),
            after: first,
            now: timestamp
        ))
    }

    @Test("non-pedestrian motion keeps a real fast segment with weak GPS speed")
    func motionCanCorroborateFastTravel() {
        let first = RecordingPoint(
            location: recordingLocation(timestamp: start)
        )
        let timestamp = start.addingTimeInterval(5)
        let fastFix = recordingLocation(
            timestamp: timestamp,
            latitude: 47.63 + 100.0 / 111_000,
            speed: 1
        )

        #expect(!RecordingFixPolicy.accepts(
            fastFix,
            after: first,
            now: timestamp
        ))
        #expect(RecordingFixPolicy.accepts(
            fastFix,
            after: first,
            motionState: .nonPedestrian,
            now: timestamp
        ))
    }
}

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
            startedAt: start,
            endedAt: start.addingTimeInterval(660)
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
}

@Suite("Recording preparation")
struct RecordingPreparationTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("a foreground fix supersedes a nearby widget anchor")
    func foregroundFixSupersedesWidgetAnchor() throws {
        let normalized = RecordingPreparation.normalizedPoints([
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: start,
                horizontalAccuracy: 60,
                flags: [.widgetSourced]
            ),
            RecordingPoint(
                latitude: 47.6301,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(3),
                horizontalAccuracy: 8
            ),
        ])

        let point = try #require(normalized.first)
        #expect(normalized.count == 1)
        #expect(point.latitude == 47.6301)
        #expect(!point.flags.contains(.widgetSourced))
    }
}

@Suite("Recording elevation")
struct RecordingElevationTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("barometric deltas shape the profile while GPS anchors drift slowly")
    func complementaryFilter() throws {
        var filter = RecordingElevationFilter()
        filter.update(relativeAltitude: 0)
        let first = CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: 47.63,
                longitude: 12.86
            ),
            altitude: 600,
            horizontalAccuracy: 8,
            verticalAccuracy: 5,
            timestamp: start
        )
        #expect(filter.elevation(for: first) == 600)

        filter.update(relativeAltitude: 10)
        let noisyGPS = CLLocation(
            coordinate: first.coordinate,
            altitude: 650,
            horizontalAccuracy: 8,
            verticalAccuracy: 5,
            timestamp: start.addingTimeInterval(10)
        )
        let secondElevation = filter.elevation(for: noisyGPS)
        let second = try #require(secondElevation)
        #expect(abs(second - 610.8) < 0.01)

        filter.update(relativeAltitude: 20)
        let invalidGPS = CLLocation(
            coordinate: first.coordinate,
            altitude: 900,
            horizontalAccuracy: 8,
            verticalAccuracy: 30,
            timestamp: start.addingTimeInterval(20)
        )
        let thirdElevation = filter.elevation(for: invalidGPS)
        let third = try #require(thirdElevation)
        #expect(abs(third - 620.8) < 0.01)
    }

    @Test("GPS altitude remains the fallback without a barometer")
    func gpsFallback() {
        var filter = RecordingElevationFilter()
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: 47.63,
                longitude: 12.86
            ),
            altitude: 612,
            horizontalAccuracy: 8,
            verticalAccuracy: 5,
            timestamp: start
        )

        #expect(filter.elevation(for: location) == 612)
    }

    @Test("restarting the barometer keeps the previous absolute elevation")
    func restartKeepsAnchor() throws {
        var filter = RecordingElevationFilter()
        filter.restart(at: 620)
        filter.update(relativeAltitude: 0)
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: 47.63,
                longitude: 12.86
            ),
            altitude: 620,
            horizontalAccuracy: 8,
            verticalAccuracy: 30,
            timestamp: start
        )
        #expect(filter.elevation(for: location) == 620)

        filter.update(relativeAltitude: 10)
        let climbedElevation = filter.elevation(for: location)
        let climbed = try #require(climbedElevation)
        #expect(climbed == 630)
    }
}
