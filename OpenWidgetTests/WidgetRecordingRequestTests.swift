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
import Testing
import WidgetKit

@Suite("Widget recording requests")
struct WidgetRecordingRequestTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func location(
        age: TimeInterval,
        accuracy: CLLocationAccuracy
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: 47.63,
                longitude: 12.86
            ),
            altitude: 600,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
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
