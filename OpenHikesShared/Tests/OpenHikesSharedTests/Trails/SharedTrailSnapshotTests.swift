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

@Suite("Polyline decimation")
struct DecimateTests {
    private func line(_ count: Int) -> [(latitude: Double, longitude: Double)] {
        (0..<count).map { step -> (latitude: Double, longitude: Double) in
            (latitude: 47.63 + Double(step) * 1e-4, longitude: 12.86)
        }
    }

    /// A track short enough to send as-is is left exactly as it is.
    @Test("a short track is passed through untouched", arguments: [0, 1, 2, 50, 180])
    func shortTracksUntouched(count: Int) {
        let input = line(count)
        let result = decimate(input, maxPoints: 180)
        #expect(result.count == count)
        for (original, decimated) in zip(input, result) {
            #expect(original.latitude == decimated.latitude)
            #expect(original.longitude == decimated.longitude)
        }
    }

    @Test("a long track is reduced to the requested budget")
    func longTracksAreReduced() {
        #expect(decimate(line(10_000), maxPoints: 180).count == 180)
        #expect(decimate(line(181), maxPoints: 180).count == 180)
    }

    /// The endpoints are the one thing a walker recognises: a trail whose
    /// drawn line stops short of its own trailhead looks like the wrong
    /// trail.
    @Test("the first and last points are always kept")
    func endpointsPreserved() throws {
        let input = line(5000)
        let result = decimate(input, maxPoints: 180)
        let first = try #require(result.first)
        let last = try #require(result.last)
        #expect(first.latitude == input[0].latitude)
        #expect(last.latitude == input[input.count - 1].latitude)
    }

    /// Order is the shape: a reordered polyline draws a different trail.
    @Test("the drawn order is preserved")
    func orderPreserved() {
        let result = decimate(line(5000), maxPoints: 180)
        for (previous, next) in zip(result, result.dropFirst()) {
            #expect(next.latitude > previous.latitude)
        }
    }

    /// Sampling is even, so the line doesn't crowd one end of the trail.
    /// A fixed stride rounds to whole source points, so neighbouring gaps can
    /// differ by one of those — but never more.
    @Test("points are sampled evenly along the track")
    func evenlySpaced() {
        let sourceStep = 1e-4
        let result = decimate(line(3600), maxPoints: 180)
        let gaps = zip(result, result.dropFirst()).map { $1.latitude - $0.latitude }
        let smallest = gaps.min() ?? 0
        let largest = gaps.max() ?? 0
        #expect(largest - smallest <= sourceStep * 1.000001)
        #expect(smallest > 0)
    }

    @Test("a long track transforms only the points it keeps")
    func longTracksAvoidAFullProjectionPass() {
        var transformed = 0
        let result = decimate(Array(0..<10_000), maxPoints: 180) { step in
            transformed += 1
            return .init(latitude: Double(step), longitude: 0)
        }

        #expect(result.count == 180)
        #expect(transformed == 180)
    }

    /// A degenerate budget mustn't produce an empty or crashing result — the
    /// widget would have nothing to draw.
    @Test("a nonsense budget falls back to passing the track through", arguments: [0, 1])
    func degenerateBudget(maxPoints: Int) {
        #expect(decimate(line(500), maxPoints: maxPoints).count == 500)
    }
}
