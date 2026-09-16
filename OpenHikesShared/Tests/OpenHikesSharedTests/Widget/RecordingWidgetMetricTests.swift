//
//  RecordingWidgetMetricTests.swift
//  OpenHikesSharedTests
//
//  "Recording widget metrics", split out of TrailWidgetMetricTests.swift so
//  that a file declares one @Suite. That file's header still holds the
//  context the two share.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Recording widget metrics")
struct RecordingWidgetMetricTests {
    private static let locale = Locale(identifier: "de_DE")

    private static func snapshot(
        gain: Double? = 180,
        speed: Double? = 1.2
    ) -> SharedRecordingSnapshot {
        SharedRecordingSnapshot(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            distanceMeters: 1400,
            pointCount: 320,
            polyline: [],
            elevationGainMeters: gain,
            averageSpeedMetersPerSecond: speed
        )
    }

    /// Distance and point count are already on the status line and the elapsed
    /// time is in the header, so these two are what a recording otherwise
    /// doesn't say.
    @Test("a live recording reports what its status line doesn't")
    func recordingChips() {
        #expect(Self.snapshot().metrics(limit: 4, locale: Self.locale).map(\.kind) == [.ascent, .pace])
    }

    /// A recording that has just started has neither figure yet.
    @Test("nothing is claimed before there is anything to claim")
    func nothingBeforeTheFirstFixes() {
        #expect(Self.snapshot(gain: nil, speed: nil).metrics(limit: 4, locale: Self.locale).isEmpty)
    }

    /// A stationary recorder has a speed of zero, and "0.0 km/h" is not a
    /// pace worth the width.
    @Test("a standing start reports no pace")
    func standingStartHasNoPace() {
        #expect(Self.snapshot(speed: 0).metrics(limit: 4, locale: Self.locale).map(\.kind) == [.ascent])
    }

    @Test("the chips survive the App Group round trip with the rest")
    func codableRoundTrip() throws {
        let snapshot = Self.snapshot()
        let decoded = try JSONDecoder().decode(
            SharedRecordingSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded == snapshot)
        #expect(
            decoded.metrics(limit: 4, locale: Self.locale)
                == snapshot.metrics(limit: 4, locale: Self.locale)
        )
    }
}
