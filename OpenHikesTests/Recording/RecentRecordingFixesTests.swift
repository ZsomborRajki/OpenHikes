//
//  RecentRecordingFixesTests.swift
//  OpenHikesTests
//
//  The stretch of walk the recorder keeps in memory so a photograph can be
//  placed at its shutter (#970): only as far back as the retention, whether
//  it was built one accepted fix at a time or rebuilt from the journal.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Recent recording fixes")
struct RecentRecordingFixesTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private static func point(_ latitude: Double, at seconds: TimeInterval) -> RecordingPoint {
        RecordingPoint(
            latitude: latitude,
            longitude: 12.86,
            timestamp: start.addingTimeInterval(seconds),
            horizontalAccuracy: 5
        )
    }

    @Test("the recent fixes let go of what is older than the retention")
    func retentionDropsOldFixes() {
        var recent = RecentRecordingFixes()
        let retention = RecentRecordingFixes.retention

        recent.append(Self.point(47.63, at: 0))
        recent.append(Self.point(47.631, at: retention))
        #expect(recent.points.count == 2, "a fix exactly at the horizon is kept")

        recent.append(Self.point(47.632, at: retention + 1))
        #expect(recent.points.map(\.latitude) == [47.631, 47.632])
    }

    @Test("a walk rebuilt from the journal keeps only its retained tail")
    func replaceKeepsTheRetainedTail() {
        var recent = RecentRecordingFixes()
        recent.append(Self.point(1, at: 0))
        let retention = RecentRecordingFixes.retention

        recent.replace(with: [
            Self.point(47.63, at: 0),
            Self.point(47.631, at: 60),
            Self.point(47.632, at: retention + 60),
        ])

        #expect(recent.points.map(\.latitude) == [47.631, 47.632])

        recent.replace(with: [])
        #expect(recent.points.isEmpty)
    }
}
