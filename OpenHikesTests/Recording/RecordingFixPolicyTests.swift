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
