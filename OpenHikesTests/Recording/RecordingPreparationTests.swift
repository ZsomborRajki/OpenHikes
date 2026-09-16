//
//  RecordingPreparationTests.swift
//  OpenHikesTests
//
//  "Recording preparation", split out of RecordingFixPolicyTests.swift so
//  that a file declares one @Suite.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

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
