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
        speed: Double? = 1.2,
        distance: Double = 1400
    ) -> SharedRecordingSnapshot {
        SharedRecordingSnapshot(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            distanceMeters: distance,
            pointCount: 320,
            polyline: [],
            elevationGainMeters: gain,
            averageSpeedMetersPerSecond: speed
        )
    }

    /// The three slots a trail's band has, answered with the walk's figures —
    /// and in the trail's order, so the pair in the corner does not swap
    /// places when a hiker starts recording along a trail they were following.
    @Test("a live recording fills the same three slots a trail does")
    func recordingChips() {
        #expect(
            Self.snapshot().metrics(limit: 4, locale: Self.locale).map(\.kind)
                == [.ascent, .distance, .pace]
        )
    }

    /// A recording that has just started has none of the three yet.
    @Test("nothing is claimed before there is anything to claim")
    func nothingBeforeTheFirstFixes() {
        #expect(
            Self.snapshot(gain: nil, speed: nil, distance: 0)
                .metrics(limit: 4, locale: Self.locale)
                .isEmpty
        )
    }

    /// A stationary recorder has a speed of zero, and "0.0 km/h" is not a
    /// pace worth the width. The metres it has already walked stay.
    @Test("a standing start reports no pace")
    func standingStartHasNoPace() {
        #expect(
            Self.snapshot(speed: 0).metrics(limit: 4, locale: Self.locale).map(\.kind)
                == [.ascent, .distance]
        )
    }

    /// The distance chip and the trail's length chip render the same way and
    /// are deliberately different kinds, because VoiceOver is where the
    /// difference has to survive: "Walked 1.4 km" is not "Length 1.4 km".
    @Test("a walk's distance is spoken as walked, not as a length")
    func distanceIsSpokenAsAWalk() throws {
        let metrics = Self.snapshot().metrics(limit: 4, locale: Self.locale)
        let walked = try #require(metrics.first { $0.kind == .distance })
        #expect(walked.spokenLabel == "Walked")
        #expect(!metrics.contains { $0.kind == .length })
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
