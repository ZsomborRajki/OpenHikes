//
//  RecordingPointElevationTests.swift
//  OpenHikesTests
//
//  Which GPS altitudes a recording is allowed to believe. Two code paths
//  answer that: `RecordingPoint.init(location:)`, used when no barometer is
//  running, and `RecordingElevationFilter`, used when one is. They are the
//  same rule, and were written out twice — the same threshold as two literals,
//  free to drift apart with nothing to notice. This suite pins them together.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Recording point elevation")
struct RecordingPointElevationTests {
    private static let altitude: CLLocationDistance = 612

    private func fix(
        verticalAccuracy: CLLocationAccuracy,
        altitude: CLLocationDistance = altitude
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            altitude: altitude,
            horizontalAccuracy: 8,
            verticalAccuracy: verticalAccuracy,
            course: -1,
            speed: -1,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    @Test("a fix at the accuracy limit keeps its altitude")
    func altitudeAtTheLimitIsKept() {
        let point = RecordingPoint(
            location: fix(verticalAccuracy: RecordingElevationFilter.maximumVerticalAccuracy)
        )
        #expect(point.elevation == Self.altitude)
    }

    @Test("a fix past the accuracy limit has no altitude")
    func altitudePastTheLimitIsDropped() {
        let point = RecordingPoint(
            location: fix(verticalAccuracy: RecordingElevationFilter.maximumVerticalAccuracy.nextUp)
        )
        #expect(point.elevation == nil)
    }

    /// A negative vertical accuracy is CoreLocation's way of saying the fix
    /// carries no altitude at all — the value in `altitude` is meaningless.
    @Test("a fix with no vertical accuracy has no altitude")
    func invalidVerticalAccuracyIsDropped() {
        #expect(RecordingPoint(location: fix(verticalAccuracy: -1)).elevation == nil)
    }

    /// A NaN altitude stored on a point would travel into the route and make
    /// every elevation statistic derived from it NaN too.
    @Test("a fix with a non-finite altitude has no altitude")
    func nonFiniteAltitudeIsDropped() {
        #expect(RecordingPoint(location: fix(verticalAccuracy: 5, altitude: .nan)).elevation == nil)
        #expect(RecordingPoint(location: fix(verticalAccuracy: 5, altitude: .infinity)).elevation == nil)
    }

    /// The point of the suite. A recording with no barometer takes its
    /// elevation from ``RecordingPoint`` and one with a barometer takes it
    /// from ``RecordingElevationFilter``; the two used to test the same
    /// threshold with two literals, so tightening one would quietly have
    /// changed which recordings get elevation at all.
    @Test("the point and the elevation filter accept exactly the same fixes")
    func pointAndFilterAgree() {
        let accuracies: [CLLocationAccuracy] = [
            -10, -1, 0, 5,
            RecordingElevationFilter.maximumVerticalAccuracy.nextDown,
            RecordingElevationFilter.maximumVerticalAccuracy,
            RecordingElevationFilter.maximumVerticalAccuracy.nextUp,
            30, 100,
        ]

        for accuracy in accuracies {
            // A filter with no barometric sample yet reports the GPS altitude
            // it trusts, and nothing else — which is the comparable answer.
            var filter = RecordingElevationFilter()
            let location = fix(verticalAccuracy: accuracy)
            #expect(
                RecordingPoint(location: location).elevation == filter.elevation(for: location),
                "the two paths disagree at a vertical accuracy of \(accuracy)"
            )
        }
    }
}
