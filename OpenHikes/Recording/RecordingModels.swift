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
    static let stationary = Self(rawValue: 1 << 1)
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
        if impliedSpeed > maximumSpeed,
           motionState != .nonPedestrian,
           !reportedSpeedSupports(impliedSpeed, location.speed) { return false }

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
