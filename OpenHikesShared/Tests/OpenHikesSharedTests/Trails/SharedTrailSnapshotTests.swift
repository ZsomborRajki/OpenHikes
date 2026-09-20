//
//  SharedTrailSnapshotTests.swift
//  OpenHikesSharedTests
//
//  The snapshot is the contract between the app and the iOS widget, which
//  renders it without recomputing trail geometry or route matching. It crosses
//  the App Group process boundary, so these tests keep both targets aligned.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Trail snapshot")
struct SharedTrailSnapshotTests {
    private static func snapshot(
        total: Double = 10_000,
        along: Double? = nil,
        offRoute: Double = 5
    ) -> SharedTrailSnapshot {
        SharedTrailSnapshot(
            hikeID: UUID(),
            title: "Thumsee Loop",
            tintHex: "#34C759FF",
            totalDistanceMeters: total,
            polyline: [
                .init(latitude: 47.63, longitude: 12.86),
                .init(latitude: 47.64, longitude: 12.87),
            ],
            elevationLowMeters: 600,
            elevationHighMeters: 900,
            liveFix: along.map { distance in
                .init(
                    coordinate: .init(latitude: 47.635, longitude: 12.865),
                    distanceAlongRouteMeters: distance,
                    offRouteMeters: offRoute,
                    timestamp: .now
                )
            }
        )
    }

    // MARK: Progress

    @Test("progress and remaining distance are read off the live fix")
    func progress() throws {
        let snapshot = Self.snapshot(total: 10_000, along: 2500)
        #expect(try #require(snapshot.fractionComplete) == 0.25)
        #expect(try #require(snapshot.remainingDistanceMeters) == 7500)
    }

    @Test("without a fix there is no progress to report")
    func noProgressWithoutFix() {
        let snapshot = Self.snapshot()
        #expect(snapshot.fractionComplete == nil)
        #expect(snapshot.remainingDistanceMeters == nil)
    }

    /// The trail's stored length and the distance a fix is matched at are
    /// computed by two different passes over the same points, so they can
    /// disagree by a metre. "101% · -8 m left" is worse than a rounding error,
    /// hence the clamp.
    @Test("progress stays within 0…100% at the finish")
    func progressClamps() throws {
        let overshoot = Self.snapshot(total: 10_000, along: 11_000)
        #expect(try #require(overshoot.fractionComplete) == 1)
        #expect(try #require(overshoot.remainingDistanceMeters) == 0)

        // A negative distance-along-route can't come out of route matching
        // (cumulative distances start at zero), but the percentage floor is
        // there all the same.
        #expect(try #require(Self.snapshot(total: 10_000, along: -50).fractionComplete) == 0)
    }

    /// A zero-length trail can't have a percentage; dividing by it would
    /// produce a NaN that renders as "nan%".
    @Test("a zero-length trail reports no percentage rather than a NaN")
    func zeroLengthTrail() {
        let snapshot = Self.snapshot(total: 0, along: 0)
        #expect(snapshot.fractionComplete == nil)
        #expect(!snapshot.statusText.contains("nan"))
    }

    // MARK: The shared status line

    @Test("with a fix, the status line is progress and distance left")
    func statusWithFix() {
        let status = Self.snapshot(total: 10_000, along: 6200).statusText
        #expect(status.contains("62%"))
        #expect(status.contains("left"))
    }

    @Test("without a fix, the status line is just the trail's length")
    func statusWithoutFix() {
        let status = Self.snapshot(total: 10_000).statusText
        #expect(!status.contains("%"))
        #expect(!status.contains("left"))
        #expect(!status.isEmpty)
    }

    /// The half the Home Screen widget speaks. It is absent exactly where the
    /// status line falls back to the trail's length, because the widget draws
    /// that length as a chip of its own — and a reader who cannot see the chip
    /// must not be told the same number twice. See `TrailWidgetSpeech`.
    @Test("the progress half is absent when there is no progress to report")
    func progressStatusIsAbsentWithoutAFix() {
        let walked = Self.snapshot(total: 10_000, along: 6200)
        let idle = Self.snapshot(total: 10_000)

        #expect(walked.progressStatusText == walked.statusText)
        #expect(idle.progressStatusText == nil)
        #expect(idle.statusText == WidgetFormat.length(meters: 10_000))
    }

    // MARK: Walks

    private static func walk(
        state: SharedTrailSnapshot.Walk.State = .active,
        covered: Double = 0.5
    ) -> SharedTrailSnapshot.Walk {
        SharedTrailSnapshot.Walk(
            state: state,
            coveredFraction: covered,
            furthestDistanceMeters: 5000,
            activeSeconds: 1800,
            startedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    /// The return-leg case: position reads 62%, coverage reads 50%, and the
    /// status line has to show the coverage and say that it is coverage.
    @Test("during a walk the status line is coverage, captioned walked")
    func statusDuringAWalkIsCoverage() {
        var snapshot = Self.snapshot(total: 10_000, along: 6200)
        snapshot.walk = Self.walk()
        let status = snapshot.statusText
        #expect(status.hasPrefix("50% walked"))
        #expect(status.contains("left"))
        #expect(!status.contains("62%"))
        #expect(snapshot.progressFraction == 0.5, "and the bar draws the same number")
        #expect(snapshot.fractionComplete == 0.62, "position is still there for whoever asks for it")
    }

    @Test("a paused walk says so before its coverage")
    func pausedWalkSaysPaused() {
        var snapshot = Self.snapshot(total: 10_000, along: 6200)
        snapshot.walk = Self.walk(state: .paused)
        #expect(snapshot.statusText.hasPrefix("Paused · 50% walked"))
    }

    @Test("a walk with no fix reports coverage and nothing left")
    func walkWithoutFixReportsCoverageOnly() {
        var snapshot = Self.snapshot(total: 10_000)
        snapshot.walk = Self.walk(covered: 0.25)
        #expect(snapshot.statusText == "25% walked")
        #expect(snapshot.progressFraction == 0.25)
    }

    /// The walk key is optional, so every payload already in a container —
    /// and every one a plain follow still writes — decodes with no walk and
    /// no version bump.
    @Test("a payload written without a walk key decodes as no walk")
    func payloadWithoutWalkDecodes() throws {
        let snapshot = Self.snapshot(total: 8000, along: 1234)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        object.removeValue(forKey: "walk")
        let decoded = try JSONDecoder().decode(
            SharedTrailSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.walk == nil)
        #expect(decoded.statusText == snapshot.statusText)
    }

    @Test("a walk survives the round trip through the App Group")
    func walkRoundTrips() throws {
        var snapshot = Self.snapshot(total: 8000, along: 1234)
        snapshot.walk = Self.walk(state: .paused, covered: 0.4)
        let decoded = try JSONDecoder().decode(
            SharedTrailSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded.walk == snapshot.walk)
    }

    // MARK: Crossing process boundaries

    @Test("a snapshot survives the round trip through the App Group")
    func codableRoundTrip() throws {
        let snapshot = Self.snapshot(total: 8000, along: 1234)
        let decoded = try JSONDecoder().decode(
            SharedTrailSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded == snapshot)
        #expect(decoded.statusText == snapshot.statusText)
    }

    /// The widget snapshot does not need a full-resolution track, so a few KB
    /// is the payload budget defended here.
    @Test("a long trail's payload stays small")
    func payloadStaysSmall() throws {
        let long: [(latitude: Double, longitude: Double)] = (0..<20_000).map { step in
            let offset = Double(step) * 1e-5
            return (latitude: 47.63 + offset, longitude: 12.86 + offset)
        }
        let snapshot = SharedTrailSnapshot(
            hikeID: UUID(),
            title: "Very long trail",
            tintHex: "#34C759FF",
            totalDistanceMeters: 90_000,
            polyline: decimate(long)
        )
        let data = try JSONEncoder().encode(snapshot)
        #expect(data.count < 16_000)
    }
}
