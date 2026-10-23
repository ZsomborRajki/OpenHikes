//
//  WidgetRecordingRequestTests.swift
//  OpenWidgetTests
//
//  "Widget recording requests", split out of TrailWidgetTests.swift so that a
//  file declares one @Suite. That file's header still holds the context the
//  two share.
//

import CoreLocation
import Foundation
import OpenHikesShared
import Testing
import WidgetKit

@Suite("Widget recording requests")
struct WidgetRecordingRequestTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func location(
        age: TimeInterval,
        accuracy: CLLocationAccuracy,
        altitude: CLLocationDistance = 600,
        verticalAccuracy: CLLocationAccuracy = 5
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: 47.63,
                longitude: 12.86
            ),
            altitude: altitude,
            horizontalAccuracy: accuracy,
            verticalAccuracy: verticalAccuracy,
            course: 0,
            speed: 1,
            timestamp: now.addingTimeInterval(-age)
        )
    }

    @Test("age and accuracy boundaries are inclusive")
    func acceptanceBoundariesAreInclusive() {
        #expect(
            WidgetRecordingFixPolicy.accepts(
                location(age: 0, accuracy: 0),
                now: now
            )
        )
        #expect(
            WidgetRecordingFixPolicy.accepts(
                location(
                    age: WidgetRecordingFixPolicy.maximumAge,
                    accuracy:
                        WidgetRecordingFixPolicy
                            .maximumHorizontalAccuracy
                ),
                now: now
            )
        )
        #expect(
            !WidgetRecordingFixPolicy.accepts(
                location(
                    age: WidgetRecordingFixPolicy.maximumAge + 0.001,
                    accuracy: 50
                ),
                now: now
            )
        )
        #expect(
            !WidgetRecordingFixPolicy.accepts(
                location(
                    age: 1,
                    accuracy:
                        WidgetRecordingFixPolicy
                            .maximumHorizontalAccuracy + 0.001
                ),
                now: now
            )
        )
        #expect(
            !WidgetRecordingFixPolicy.accepts(
                location(age: -0.001, accuracy: 50),
                now: now
            )
        )
    }

    /// The phone holds its own GPS heights to `AltitudePolicy`, so an anchor
    /// merged into its recording is held to the same rule.
    @Test("an anchor carries a height only when AltitudePolicy trusts it")
    func anchorHeightFollowsAltitudePolicy() {
        let limit = AltitudePolicy.maximumVerticalAccuracy
        func height(_ altitude: CLLocationDistance, at verticalAccuracy: CLLocationAccuracy) -> CLLocationDistance? {
            WidgetRecordingFixPolicy.elevation(
                of: location(age: 0, accuracy: 50, altitude: altitude, verticalAccuracy: verticalAccuracy)
            )
        }

        #expect(height(600, at: 0) == 600)
        #expect(height(600, at: limit) == 600)
        #expect(height(600, at: limit.nextUp) == nil)
        // The widget's own limit, before it took the phone's.
        #expect(height(600, at: 30) == nil)
        #expect(height(600, at: -1) == nil)
        // A NaN height made the encoder throw, which lost the position too.
        #expect(height(.nan, at: 5) == nil)
    }

    @MainActor
    @Test("a timeout completion cannot fire again for a late fix")
    func completionIsOneShot() {
        let sessionID = UUID()
        var completionCount = 0
        let request = WidgetRecordingRequest(sessionID: sessionID) {
            completionCount += 1
        }

        let timeout = request.consume()
        timeout?.completion()
        let lateFix = request.consume()
        lateFix?.completion()

        #expect(timeout?.sessionID == sessionID)
        #expect(lateFix == nil)
        #expect(completionCount == 1)
    }
}
