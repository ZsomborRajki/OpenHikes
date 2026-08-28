//
//  RecordingColdStartFixTests.swift
//  OpenHikesTests
//
//  What ``RecordingFixPolicy``'s speed gate may and may not hold out. Its own
//  file rather than another suite in `RecordingFixPolicyTests.swift`, which is
//  already at the length a file is allowed.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

nonisolated private let coldStartLatitude = 47.63
nonisolated private let coldStartLongitude = 12.86
nonisolated private let coldStartAltitude: CLLocationDistance = 600
/// Within a quarter of a percent of the radius ``RouteGeometry`` measures
/// with — close enough that no assertion here sits inside the difference.
nonisolated private let metersPerDegreeLatitude = 111_000.0

/// One fix, with only the fields this policy reads spelled out.
nonisolated private func coldStartLocation(
    offsetMeters: Double,
    at seconds: TimeInterval,
    from start: Date,
    accuracy: CLLocationAccuracy = 8,
    speed: CLLocationSpeed = -1
) -> CLLocation {
    CLLocation(
        coordinate: CLLocationCoordinate2D(
            latitude: coldStartLatitude + offsetMeters / metersPerDegreeLatitude,
            longitude: coldStartLongitude
        ),
        altitude: coldStartAltitude,
        horizontalAccuracy: accuracy,
        verticalAccuracy: 5,
        course: -1,
        speed: speed,
        timestamp: start.addingTimeInterval(seconds)
    )
}

@Suite("Recording fix policy, cold start")
struct RecordingColdStartFixTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    /// The speed gate governs the window before the heartbeat and nothing
    /// past it. Both halves matter: the first pins that a fix arriving while
    /// the anchor is fresh is still refused for an implied speed no walk
    /// supports, the second that one arriving after `maximumInterval` is
    /// admitted anyway — because by then the anchor is the likelier suspect.
    @Test("the heartbeat outranks the speed gate once the anchor is stale")
    func heartbeatOverridesTheSpeedGate() {
        let anchor = RecordingPoint(
            location: coldStartLocation(offsetMeters: 0, at: 0, from: start)
        )
        func fix(after seconds: TimeInterval) -> CLLocation {
            coldStartLocation(
                offsetMeters: 150,
                at: seconds,
                from: start,
                speed: 1.4
            )
        }

        // 150 m in 9 s is 17 m/s, and the walker's own 1.4 m/s says otherwise.
        let inside = fix(after: RecordingFixPolicy.maximumInterval - 1)
        #expect(!RecordingFixPolicy.accepts(
            inside,
            after: anchor,
            now: inside.timestamp
        ))

        // Still 15 m/s, still uncorroborated. Admitted regardless.
        let atHeartbeat = fix(after: RecordingFixPolicy.maximumInterval)
        #expect(RecordingFixPolicy.accepts(
            atHeartbeat,
            after: anchor,
            now: atHeartbeat.timestamp
        ))
    }

    /// The walk the gate used to eat. A cold start reports 45 m of accuracy —
    /// inside the filter, so it is anchored on — while sitting 150 m from
    /// where the walker is standing, and every accurate fix that follows is
    /// measured against it. Before the interval term the first of them was
    /// admitted at 23 s; the walker kept the phantom and lost the walk in
    /// between.
    @Test("a cold-start outlier locks the walk out for one heartbeat, not for the error it made")
    func coldStartOutlierLockoutIsBoundedByTheHeartbeat() throws {
        let outlier = coldStartLocation(
            offsetMeters: -150,
            at: 0,
            from: start,
            accuracy: 45
        )
        #expect(
            RecordingFixPolicy.accepts(outlier, after: nil, now: start),
            "the first fix is admitted on its claimed accuracy alone"
        )
        let anchor = RecordingPoint(location: outlier)

        // A minute of accurate fixes, one a second, walking north at 1.4 m/s
        // from where the walker actually is.
        var accepted: CLLocation?
        for second in 1...60 {
            let walked = coldStartLocation(
                offsetMeters: 1.4 * Double(second),
                at: TimeInterval(second),
                from: start,
                speed: 1.4
            )
            guard RecordingFixPolicy.accepts(
                walked,
                after: anchor,
                now: walked.timestamp
            ) else { continue }
            accepted = walked
            break
        }

        let first = try #require(
            accepted,
            "no fix re-anchored the recording within a minute"
        )
        #expect(
            first.timestamp.timeIntervalSince(start)
                == RecordingFixPolicy.maximumInterval
        )
        // Re-anchored on the truth rather than on the phantom: the fix that
        // got in is north of the start, where the walker is, not south of it.
        #expect(first.coordinate.latitude > coldStartLatitude)

        // And the gate itself has not moved. The fix it just admitted implies
        // twice the walking ceiling, and would have gone on doing so for
        // another thirteen seconds as the walker walked further from the
        // phantom. It is overridden here, not deleted.
        let displacement = RouteGeometry.distanceMeters(
            from: anchor.coordinate,
            to: first.coordinate
        )
        #expect(
            displacement / RecordingFixPolicy.maximumInterval
                > RecordingFixPolicy.maximumSpeed
        )
    }

    /// The escape is granted on elapsed time, and a fix that arrives out of
    /// order has elapsed none: the `interval > 0` guard runs first and refuses
    /// both a fix older than the anchor and one carrying its timestamp
    /// exactly. Nothing behind it would. A negative interval reads as a
    /// negative implied speed, which is not greater than the ceiling; a zero
    /// one reads as an infinite speed, which the walker's reported speed then
    /// *corroborates*, since everything is within an infinite tolerance.
    @Test("a reordered fix is refused however wide the gap it claims")
    func reorderedFixIsStillRefused() {
        let now = start.addingTimeInterval(60)
        let anchor = RecordingPoint(
            location: coldStartLocation(offsetMeters: 0, at: 60, from: start)
        )

        #expect(!RecordingFixPolicy.accepts(
            coldStartLocation(offsetMeters: 150, at: 40, from: start),
            after: anchor,
            now: now
        ))
        #expect(!RecordingFixPolicy.accepts(
            coldStartLocation(
                offsetMeters: 150,
                at: 60,
                from: start,
                speed: 1.4
            ),
            after: anchor,
            now: now
        ))
    }
}
