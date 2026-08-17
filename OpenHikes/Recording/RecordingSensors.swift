//
//  RecordingSensors.swift
//  OpenHikes
//
//  Optional motion-sensor inputs used by recording. GPS remains the fallback:
//  a missing barometer or pedometer must reduce matching quality, never make a
//  hike impossible to save.
//

import CoreLocation
import Foundation
import os
#if canImport(CoreMotion)
import CoreMotion
#endif

protocol RecordingElevationSource: AnyObject {
    var isAvailable: Bool { get }

    func start(
        deliveringRelativeAltitude handler: @escaping @Sendable (Double) -> Void
    )
    func stop()
}

final class SystemRecordingElevationSource: RecordingElevationSource {
    /// `nonisolated` so the CoreMotion callback below can log. Under
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` a static stored property is
    /// main-actor isolated unless it says otherwise, and this one is read from
    /// CoreMotion's queue.
    nonisolated private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "RecordingElevation"
    )

    #if os(iOS) && canImport(CoreMotion)
    private let altimeter = CMAltimeter()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "OpenHikes.recording-altimeter"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    #endif

    var isAvailable: Bool {
        #if os(iOS) && canImport(CoreMotion)
        CMAltimeter.isRelativeAltitudeAvailable()
        #else
        false
        #endif
    }

    func start(
        deliveringRelativeAltitude handler: @escaping @Sendable (Double) -> Void
    ) {
        #if os(iOS) && canImport(CoreMotion)
        guard isAvailable else { return }
        altimeter.stopRelativeAltitudeUpdates()
        // `@Sendable` is load-bearing, not decoration. The project builds with
        // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `CMAltitudeHandler`
        // is imported without `@Sendable`, so an unannotated closure here
        // inherits this method's isolation — which is `@MainActor`, inferred
        // from the `RecordingElevationSource` requirement it witnesses, even
        // though the enclosing type does no main-actor work. The compiler then
        // opens the closure with an executor assertion, CoreMotion invokes it
        // on `queue` rather than the main thread, and the very first delivery
        // trips `swift_task_checkIsolated`. That first delivery is whatever
        // follows the Motion & Fitness prompt, so granting *or* refusing it
        // crashed the moment a recording started.
        altimeter.startRelativeAltitudeUpdates(to: queue) { @Sendable data, error in
            if let error {
                Self.logger.error(
                    "Barometer update failed: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            guard let data else { return }
            handler(data.relativeAltitude.doubleValue)
        }
        #endif
    }

    func stop() {
        #if os(iOS) && canImport(CoreMotion)
        altimeter.stopRelativeAltitudeUpdates()
        #endif
    }
}

nonisolated enum RecordingMotionState: Equatable, Sendable {
    case nonPedestrian
    case pedestrian
    case stationary
    case unknown
}

protocol RecordingMotionSource: AnyObject {
    var isAvailable: Bool { get }

    func start(
        deliveringState handler: @escaping @Sendable (
            RecordingMotionState
        ) -> Void
    )
    func stop()
}

final class SystemRecordingMotionSource: RecordingMotionSource {
    #if os(iOS) && canImport(CoreMotion)
    private let manager = CMMotionActivityManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "OpenHikes.recording-motion"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    #endif

    var isAvailable: Bool {
        #if os(iOS) && canImport(CoreMotion)
        CMMotionActivityManager.isActivityAvailable()
        #else
        false
        #endif
    }

    func start(
        deliveringState handler: @escaping @Sendable (
            RecordingMotionState
        ) -> Void
    ) {
        #if os(iOS) && canImport(CoreMotion)
        guard isAvailable else { return }
        manager.stopActivityUpdates()
        // `@Sendable` for the same reason as the altimeter above: without it
        // this closure inherits the witness's `@MainActor` isolation and traps
        // when CoreMotion delivers on `queue`.
        manager.startActivityUpdates(to: queue) { @Sendable activity in
            guard let activity else {
                handler(.unknown)
                return
            }
            handler(Self.state(for: activity))
        }
        #endif
    }

    func stop() {
        #if os(iOS) && canImport(CoreMotion)
        manager.stopActivityUpdates()
        #endif
    }

    #if os(iOS) && canImport(CoreMotion)
    nonisolated private static func state(
        for activity: CMMotionActivity
    ) -> RecordingMotionState {
        guard activity.confidence != .low else { return .unknown }
        if activity.automotive || activity.cycling { return .nonPedestrian }
        if activity.walking || activity.running { return .pedestrian }
        if activity.stationary { return .stationary }
        return .unknown
    }
    #endif
}

/// Slow GPS anchoring plus fast barometric deltas. The barometer supplies the
/// profile's shape; valid GPS altitude prevents weather drift from moving the
/// whole recording indefinitely.
nonisolated struct RecordingElevationFilter: Sendable {
    static let maximumVerticalAccuracy: CLLocationAccuracy = 15
    static let gpsCorrectionWeight = 0.02

    /// The GPS altitude a fix may contribute, or `nil` when its vertical
    /// accuracy is missing or too loose to trust — or when the altitude
    /// itself isn't a number.
    ///
    /// One function rather than one test per caller: ``RecordingPoint`` builds
    /// its own elevation straight from a fix when no barometer is running, and
    /// while that check was written out a second time the two shared a
    /// threshold by coincidence. Tightening one and not the other would have
    /// silently changed which recordings get elevation, with nothing to say so.
    static func trustedAltitude(of location: CLLocation) -> CLLocationDistance? {
        guard location.verticalAccuracy >= 0,
              location.verticalAccuracy <= maximumVerticalAccuracy,
              location.altitude.isFinite
        else { return nil }
        return location.altitude
    }

    private var latestRelativeAltitude: Double?
    private var relativeAnchor: Double?
    private var elevationAnchor: Double?

    mutating func reset() {
        restart(at: nil)
    }

    mutating func restart(at elevation: Double?) {
        latestRelativeAltitude = nil
        relativeAnchor = nil
        elevationAnchor = elevation
    }

    mutating func update(relativeAltitude: Double) {
        guard relativeAltitude.isFinite else { return }
        latestRelativeAltitude = relativeAltitude
    }

    mutating func elevation(for location: CLLocation) -> Double? {
        let gpsAltitude = Self.trustedAltitude(of: location)

        guard let relativeAltitude = latestRelativeAltitude else { return gpsAltitude }

        guard let relativeAnchor else {
            relativeAnchor = relativeAltitude
            if let elevationAnchor {
                guard let gpsAltitude else { return elevationAnchor }
                let corrected = elevationAnchor
                    + (gpsAltitude - elevationAnchor)
                        * Self.gpsCorrectionWeight
                self.elevationAnchor = corrected
                return corrected
            }
            guard let gpsAltitude else { return nil }
            elevationAnchor = gpsAltitude
            return gpsAltitude
        }

        guard let elevationAnchor else { return gpsAltitude }
        var fused = elevationAnchor + relativeAltitude - relativeAnchor
        if let gpsAltitude {
            fused += (gpsAltitude - fused) * Self.gpsCorrectionWeight
            self.relativeAnchor = relativeAltitude
            self.elevationAnchor = fused
        }
        return fused
    }
}

nonisolated protocol RecordingDistanceEvidenceSource: Sendable {
    func distance(from start: Date, to end: Date) async -> Double?
}

actor SystemPedometerDistanceSource: RecordingDistanceEvidenceSource {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "RecordingPedometer"
    )

    #if os(iOS) && canImport(CoreMotion)
    private let pedometer = CMPedometer()
    #endif

    func distance(from start: Date, to end: Date) async -> Double? {
        guard end > start else { return nil }
        #if os(iOS) && canImport(CoreMotion)
        guard CMPedometer.isDistanceAvailable() else { return nil }
        return await withCheckedContinuation { continuation in
            pedometer.queryPedometerData(from: start, to: end) { data, error in
                if let error {
                    Self.logger.error(
                        "Pedometer query failed: \(error.localizedDescription, privacy: .public)"
                    )
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data?.distance?.doubleValue)
            }
        }
        #else
        return nil
        #endif
    }
}
