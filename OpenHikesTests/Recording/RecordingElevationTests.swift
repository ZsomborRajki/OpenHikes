//
//  RecordingElevationTests.swift
//  OpenHikesTests
//
//  What a recording believes about altitude when a barometer is running.
//
//  `RecordingElevationFilter` is a complementary filter: CoreMotion's relative
//  altitude supplies the shape of the profile, because it resolves a metre of
//  climb that GPS cannot, and GPS supplies the absolute reference, because a
//  relative altimeter has no idea how high it started. Both halves have to be
//  anchored before either is worth anything, and the order in which those two
//  anchors are committed is the whole subject of this suite.
//
//  Split out of `RecordingFixPolicyTests` when that file outgrew the 500-line
//  limit: which fixes are accepted and what elevation is derived from the ones
//  that are, are two questions.
//

import CoreLocation
@testable import OpenHikes
import Testing

@Suite("Recording elevation")
struct RecordingElevationTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    private func fix(
        altitude: CLLocationDistance,
        verticalAccuracy: CLLocationAccuracy,
        after seconds: TimeInterval = 0
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86),
            altitude: altitude,
            horizontalAccuracy: 8,
            verticalAccuracy: verticalAccuracy,
            timestamp: start.addingTimeInterval(seconds)
        )
    }

    /// A cold-start fix routinely arrives with vertical accuracy too loose to
    /// trust, and CoreMotion is usually already reporting by then. Committing
    /// the relative anchor before knowing whether an absolute one could be
    /// established left the filter holding a relative anchor and no elevation
    /// anchor — a state it has no way out of, because the elevation anchor is
    /// only ever assigned on the path that a set relative anchor skips.
    /// Barometric fusion was then off for the rest of the recording, with
    /// nothing to say so, and the hike's elevation gain was whatever raw GPS
    /// happened to report. `resume()` re-entered it, since it restarts from a
    /// `nil` elevation.
    @Test("an untrusted first fix doesn't disable the barometer for the rest of the hike")
    func untrustedFirstFixDoesNotDisableFusion() throws {
        var filter = RecordingElevationFilter()
        filter.update(relativeAltitude: 0)

        // Past the accuracy limit, and no earlier leg to carry an elevation in
        // from: there is nothing to anchor against yet.
        let untrusted = filter.elevation(for: fix(altitude: 600, verticalAccuracy: 30))
        #expect(untrusted == nil)

        // The barometer has since recorded fifty metres of climb. The first
        // trusted fix is what seeds the absolute anchor.
        filter.update(relativeAltitude: 50)
        let seeded = filter.elevation(for: fix(altitude: 601, verticalAccuracy: 5, after: 10))
        #expect(seeded == 601)

        // And from there the barometric delta shapes the profile, which is the
        // whole point of running one.
        filter.update(relativeAltitude: 100)
        let fusedElevation = filter.elevation(for: fix(altitude: 602, verticalAccuracy: 5, after: 20))
        let fused = try #require(fusedElevation)
        #expect(abs(fused - 650.02) < 0.01, "the barometer's fifty metres, not GPS's one")
    }

    @Test("barometric deltas shape the profile while GPS anchors drift slowly")
    func complementaryFilter() throws {
        var filter = RecordingElevationFilter()
        filter.update(relativeAltitude: 0)
        let first = CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: 47.63,
                longitude: 12.86
            ),
            altitude: 600,
            horizontalAccuracy: 8,
            verticalAccuracy: 5,
            timestamp: start
        )
        #expect(filter.elevation(for: first) == 600)

        filter.update(relativeAltitude: 10)
        let noisyGPS = CLLocation(
            coordinate: first.coordinate,
            altitude: 650,
            horizontalAccuracy: 8,
            verticalAccuracy: 5,
            timestamp: start.addingTimeInterval(10)
        )
        let secondElevation = filter.elevation(for: noisyGPS)
        let second = try #require(secondElevation)
        #expect(abs(second - 610.8) < 0.01)

        filter.update(relativeAltitude: 20)
        let invalidGPS = CLLocation(
            coordinate: first.coordinate,
            altitude: 900,
            horizontalAccuracy: 8,
            verticalAccuracy: 30,
            timestamp: start.addingTimeInterval(20)
        )
        let thirdElevation = filter.elevation(for: invalidGPS)
        let third = try #require(thirdElevation)
        #expect(abs(third - 620.8) < 0.01)
    }

    @Test("GPS altitude remains the fallback without a barometer")
    func gpsFallback() {
        var filter = RecordingElevationFilter()
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: 47.63,
                longitude: 12.86
            ),
            altitude: 612,
            horizontalAccuracy: 8,
            verticalAccuracy: 5,
            timestamp: start
        )

        #expect(filter.elevation(for: location) == 612)
    }

    @Test("restarting the barometer keeps the previous absolute elevation")
    func restartKeepsAnchor() throws {
        var filter = RecordingElevationFilter()
        filter.restart(at: 620)
        filter.update(relativeAltitude: 0)
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: 47.63,
                longitude: 12.86
            ),
            altitude: 620,
            horizontalAccuracy: 8,
            verticalAccuracy: 30,
            timestamp: start
        )
        #expect(filter.elevation(for: location) == 620)

        filter.update(relativeAltitude: 10)
        let climbedElevation = filter.elevation(for: location)
        let climbed = try #require(climbedElevation)
        #expect(climbed == 630)
    }
}
