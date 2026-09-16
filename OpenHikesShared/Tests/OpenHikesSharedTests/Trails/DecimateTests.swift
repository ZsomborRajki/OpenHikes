//
//  DecimateTests.swift
//  OpenHikesSharedTests
//
//  "Polyline decimation", split out of SharedTrailSnapshotTests.swift so that
//  a file declares one @Suite. That file's header still holds the context the
//  two share.
//

import Foundation
@testable import OpenHikesShared
import Testing

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

    /// The endpoints are the one thing a hiker recognises: a trail whose
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
