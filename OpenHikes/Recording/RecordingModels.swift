//
//  RecordingModels.swift
//  OpenHikes
//
//  Pure recording values and the fix-acceptance policy. The observable leaf
//  models the UI and map coordinator read live in RecordingObservables.swift.
//

import Algorithms
import CoreLocation
import DequeModule
import Foundation
import Observation
import OpenHikesShared

nonisolated struct RecordingPointFlags: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32

    static let resumed = Self(rawValue: 1 << 0)
    // Bit 1 is spent, and stays spent. It carried `stationary`: the distance
    // accumulator's own verdict, written back onto the point it had just been
    // handed. Nothing ever read it, and nothing could have learned anything
    // from it — the verdict is a function of the points before it, so every
    // reader either holds the live accumulator
    // (``HikeRecorder/resolvedEnergyProfile()``) or replays them
    // (``HikeRecorder/rebuildLiveState(from:)``,
    // ``RecordingPreparation``). Journals recorded before it was dropped still
    // have the bit set and still decode, the flags field being a raw `UInt32`
    // — which is exactly why a new flag must not be given the bit. Every one
    // of those old stationary fixes would arrive making the new claim.
    static let widgetSourced = Self(rawValue: 1 << 2)
    static let motionStationary = Self(rawValue: 1 << 3)
    static let nonPedestrian = Self(rawValue: 1 << 4)
    /// The stretch of route *leading to* this point was reasoned about rather
    /// than walked under observation: the recording crossed it without
    /// producing a fix, and the geometry is whatever ``TrailMatcher`` could
    /// justify — a mapped trail it bridged the gap with, or a straight line
    /// where it could not.
    ///
    /// A property of the segment, carried on that segment's end point. That is
    /// what lets a two-coordinate straight line across a gap be marked at all,
    /// and it survives the `dropFirst()` join between legs because the shared
    /// anchor is kept from the earlier leg. Never set on a fix as it arrives
    /// from Core Location or the widget.
    static let inferred = Self(rawValue: 1 << 5)
}

nonisolated struct RecordingPoint: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    var elevation: Double?
    let horizontalAccuracy: Double
    let course: Double?
    let speed: Double?
    var flags: RecordingPointFlags

    init(
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        horizontalAccuracy: Double,
        elevation: Double? = nil,
        course: Double? = nil,
        speed: Double? = nil,
        flags: RecordingPointFlags = []
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.elevation = elevation
        self.horizontalAccuracy = horizontalAccuracy
        self.course = course
        self.speed = speed
        self.flags = flags
    }

    init(location: CLLocation, flags: RecordingPointFlags = []) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        timestamp = location.timestamp
        horizontalAccuracy = location.horizontalAccuracy
        course = LocationFixPolicy.course(of: location)
        speed = location.speed >= 0 ? location.speed : nil
        self.flags = flags

        // Same rule as the barometric filter's, and deliberately the same
        // function: two copies of it drifted apart silently.
        elevation = RecordingElevationFilter.trustedAltitude(of: location)
    }

    init(sharedFix: SharedRecordingFix) {
        latitude = sharedFix.latitude
        longitude = sharedFix.longitude
        timestamp = sharedFix.timestamp
        elevation = sharedFix.elevation
        horizontalAccuracy = sharedFix.horizontalAccuracy
        course = sharedFix.course
        speed = sharedFix.speed
        flags = [.widgetSourced]
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var routeCoordinate: RouteCoordinate {
        RouteCoordinate(
            latitude: latitude,
            longitude: longitude,
            elevation: elevation,
            timestamp: timestamp,
            motion: flags.contains(.nonPedestrian)
                ? .nonPedestrian
                : nil,
            provenance: flags.contains(.inferred) ? .inferred : nil
        )
    }
}

nonisolated enum RecordingFixPolicy {
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 50
    static let maximumSpeed: CLLocationSpeed = 8
    static let minimumDisplacement: CLLocationDistance = 5
    static let maximumInterval: TimeInterval = 10
    static let bearingChangeDegrees = 15.0
    private static let displacementGateFraction = 0.5
    private static let speedToleranceBase: CLLocationSpeed = 2
    private static let speedToleranceFraction = 0.35

    static func accepts(
        _ location: CLLocation,
        after previous: RecordingPoint?,
        motionState: RecordingMotionState = .unknown,
        now: Date = .now
    ) -> Bool {
        guard LocationFixPolicy.accepts(
            location,
            maximumAge: LocationFixPolicy.foregroundMaximumAge,
            maximumHorizontalAccuracy: maximumHorizontalAccuracy,
            now: now
        ), Mercator.isRepresentable(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        ) else { return false }

        guard let previous else { return true }

        let interval = location.timestamp.timeIntervalSince(previous.timestamp)
        guard interval > 0 else { return false }

        let displacement = RouteGeometry.distanceMeters(
            from: previous.coordinate,
            to: location.coordinate
        )
        let impliedSpeed = displacement / interval
        // The `interval` term is what stops this gate outranking the heartbeat
        // below. A first fix has no predecessor and so anchors the recording on
        // its claimed accuracy alone, and a cold start can claim a figure
        // inside the 50 m filter while sitting materially further out than
        // that. Every accurate fix afterwards is then measured against a place
        // the walker has never stood and implies a speed no walk supports;
        // their real speed cannot rescue it either, since 1.4 m/s does not
        // corroborate an implied 16. Without the term the lockout runs until
        // the anchor's error divided by `maximumSpeed` has elapsed — around
        // 19 s for 150 m, and longer the worse the anchor was — and that
        // opening stretch of the walk is simply lost.
        //
        // Little is given up. A teleport arrives amid a stream whose anchor is
        // seconds old, and inside `maximumInterval` it is refused exactly as
        // before; past it this was never a rejection but a delay, being a
        // distance threshold that grows at `maximumSpeed` and admits the same
        // bad fix a little later. A live recording would rather re-anchor on a
        // position that may be wrong than hold one that is certainly stale.
        // The `interval > 0` guard above still refuses a reordered pair, so
        // the escape cannot admit one.
        if impliedSpeed > maximumSpeed,
           motionState != .nonPedestrian,
           !reportedSpeedSupports(impliedSpeed, location.speed),
           interval < maximumInterval { return false }

        let displacementGate = max(
            minimumDisplacement,
            location.horizontalAccuracy * displacementGateFraction
        )
        if displacement >= displacementGate || interval >= maximumInterval { return true }

        guard let previousCourse = previous.course,
              let nextCourse = LocationFixPolicy.course(of: location)
        else { return false }
        return angularDifference(previousCourse, nextCourse) > bearingChangeDegrees
    }

    private static func reportedSpeedSupports(
        _ impliedSpeed: CLLocationSpeed,
        _ reportedSpeed: CLLocationSpeed
    ) -> Bool {
        guard reportedSpeed >= 0 else { return false }
        let tolerance = max(speedToleranceBase, impliedSpeed * speedToleranceFraction)
        return abs(reportedSpeed - impliedSpeed) <= tolerance
    }

    private static func angularDifference(_ lhs: Double, _ rhs: Double) -> Double {
        let difference = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }
}
