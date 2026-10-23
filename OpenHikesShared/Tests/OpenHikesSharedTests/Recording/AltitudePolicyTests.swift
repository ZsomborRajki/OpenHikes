//
//  AltitudePolicyTests.swift
//  OpenHikesSharedTests
//
//  Which GPS heights a recording keeps. The phone, the watch and the widget all
//  ask `AltitudePolicy`, so this suite is where all three of them are tested.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Altitude policy")
struct AltitudePolicyTests {
    private static let altitude = 612.0

    /// A negative vertical accuracy is Core Location saying the altitude is
    /// invalid; NaN is no claim at all.
    @Test("A height with no vertical accuracy is refused", arguments: [-1, -10, -Double.infinity, Double.nan])
    func invalidAccuracyIsRefused(accuracy: Double) {
        #expect(AltitudePolicy.trustedAltitude(Self.altitude, verticalAccuracy: accuracy) == nil)
    }

    /// Zero is a valid claim to Core Location, not a missing one. The watch
    /// used to refuse it while the phone kept it.
    @Test("A height claimed exact is kept")
    func zeroAccuracyIsKept() {
        #expect(AltitudePolicy.trustedAltitude(Self.altitude, verticalAccuracy: 0) == Self.altitude)
    }

    @Test(
        "A height within the limit is kept",
        arguments: [5, AltitudePolicy.maximumVerticalAccuracy.nextDown, AltitudePolicy.maximumVerticalAccuracy]
    )
    func acceptableAccuracyIsKept(accuracy: Double) {
        #expect(AltitudePolicy.trustedAltitude(Self.altitude, verticalAccuracy: accuracy) == Self.altitude)
    }

    @Test(
        "A height past the limit is refused",
        arguments: [AltitudePolicy.maximumVerticalAccuracy.nextUp, 30, 100, Double.infinity]
    )
    func excessiveAccuracyIsRefused(accuracy: Double) {
        #expect(AltitudePolicy.trustedAltitude(Self.altitude, verticalAccuracy: accuracy) == nil)
    }

    /// A non-finite height would make every statistic built on it NaN, and
    /// `JSONEncoder` refuses one, so a walk carrying it could not be written.
    @Test("A height that is not a number is refused", arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteAltitudeIsRefused(altitude: Double) {
        #expect(AltitudePolicy.trustedAltitude(altitude, verticalAccuracy: 5) == nil)
    }

    /// Below sea level is ground, not an error: the Dead Sea shore is at
    /// about −430 m.
    @Test("A height below sea level is kept")
    func negativeAltitudeIsKept() {
        #expect(AltitudePolicy.trustedAltitude(-430, verticalAccuracy: 5) == -430)
    }

    /// The case #932 reported, passed through the watch's ingestion: six
    /// accepted fixes on level ground whose heights swing by 100 m at ±100 m
    /// came out as 300 m of climb. With the heights refused, each fix is
    /// still kept and the walk has its full track but no climb.
    @Test("A walk under a poor vertical fix keeps its track and climbs nothing")
    func uncertainHeightsKeepTheirFixes() {
        let walk = Self.walk(verticalAccuracy: 100)
        #expect(walk.fixes.count == 6)
        #expect(walk.fixes.allSatisfy { $0.elevationMeters == nil })
        #expect(walk.distanceMeters > 0)
        #expect(walk.elevationGainMeters == 0)
        #expect(walk.elevationLossMeters == 0)
    }

    /// The control for the test above: the same walk at a trustworthy
    /// accuracy climbs, so it is the policy that removed the climb there.
    @Test("The same walk under a good vertical fix climbs")
    func trustedHeightsClimb() {
        let walk = Self.walk(verticalAccuracy: 5)
        #expect(walk.fixes.allSatisfy { $0.elevationMeters != nil })
        #expect(walk.elevationGainMeters == 300)
    }

    /// Six fixes ten seconds and about twenty metres apart, offered the way
    /// `WatchRecorder.received` offers a `CLLocation`.
    private static func walk(verticalAccuracy: Double) -> WatchWalkAccumulator {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        var walk = WatchWalkAccumulator()
        for (index, height) in [100.0, 200, 100, 200, 100, 200].enumerated() {
            walk.accept(
                latitude: 47.63 + Double(index) * 0.0002,
                longitude: 12.86,
                timestamp: start.addingTimeInterval(Double(index) * 10),
                horizontalAccuracy: 5,
                elevationMeters: AltitudePolicy.trustedAltitude(height, verticalAccuracy: verticalAccuracy)
            )
        }
        return walk
    }
}
