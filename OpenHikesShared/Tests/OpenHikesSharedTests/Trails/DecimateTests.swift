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
    /// A track short enough to send as-is is left exactly as it is.
    @Test("a short track is passed through untouched", arguments: [0, 1, 2, 50, 180])
    func shortTracksUntouched(count: Int) {
        #expect(decimatedIndices(count: count, maxPoints: 180) == Array(0..<count))
    }

    @Test("a long track is reduced to the requested budget")
    func longTracksAreReduced() {
        #expect(decimatedIndices(count: 10_000, maxPoints: 180).count == 180)
        #expect(decimatedIndices(count: 181, maxPoints: 180).count == 180)
    }

    /// The endpoints are the one thing a hiker recognises: a trail whose
    /// drawn line stops short of its own trailhead looks like the wrong
    /// trail.
    @Test("the first and last points are always kept")
    func endpointsPreserved() {
        let kept = decimatedIndices(count: 5000, maxPoints: 180)
        #expect(kept.first == 0)
        #expect(kept.last == 4999)
    }

    /// Order is the shape: a reordered polyline draws a different trail.
    @Test("the drawn order is preserved")
    func orderPreserved() {
        let kept = decimatedIndices(count: 5000, maxPoints: 180)
        #expect(zip(kept, kept.dropFirst()).allSatisfy { $0 < $1 })
    }

    /// Sampling is even, so the line doesn't crowd one end of the trail.
    /// A fixed stride rounds to whole source points, so neighbouring gaps can
    /// differ by one of those — but never more.
    @Test("points are sampled evenly along the track")
    func evenlySpaced() {
        let kept = decimatedIndices(count: 3600, maxPoints: 180)
        let gaps = zip(kept, kept.dropFirst()).map { $1 - $0 }
        let smallest = gaps.min() ?? 0
        let largest = gaps.max() ?? 0
        #expect(largest - smallest <= 1)
        #expect(smallest > 0)
    }

    /// A degenerate budget mustn't produce an empty or crashing result — the
    /// widget would have nothing to draw.
    @Test("a nonsense budget falls back to passing the track through", arguments: [0, 1])
    func degenerateBudget(maxPoints: Int) {
        #expect(decimatedIndices(count: 500, maxPoints: maxPoints) == Array(0..<500))
    }
}
