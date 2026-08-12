//
//  RecordingModels.swift
//  OpenTrails
//
//  Pure recording policy/state plus the observable leaf models used by the UI
//  and map coordinator.
//

import CoreLocation
import Foundation
import Observation
import OpenTrailsShared

nonisolated enum RecordingAccuracyProfile: String, Codable, CaseIterable,
    Identifiable, Sendable {
    case high
    case balanced
    case batterySaver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high:
            "High"
        case .balanced:
            "Balanced"
        case .batterySaver:
            "Battery Saver"
        }
    }

    var summary: String {
        switch self {
        case .high:
            "Best navigation accuracy with continuous fixes."
        case .balanced:
            "Best accuracy with a 10 m movement filter."
        case .batterySaver:
            "System-paced significant changes for minimum battery use."
        }
    }
}

nonisolated enum RecordingSettings {
    static let recordingAccuracyKey = "settings.recordingAccuracy"
    static let snapToTrailsKey = "settings.snapRecordedHikesToTrails"
    static let improveAccuracyOnlineKey =
        "settings.improveRecordingAccuracyOnline"
    static let keepRawGPSTrackKey =
        "settings.keepRawRecordedGPSTrack"
}

nonisolated struct RecordingSessionOptions: Codable, Equatable, Sendable {
    var accuracyProfile: RecordingAccuracyProfile
    var snapToTrails: Bool
    var improveAccuracyOnline: Bool
    var keepRawGPSTrack: Bool

    static let defaults = RecordingSessionOptions(
        accuracyProfile: .high,
        snapToTrails: true,
        improveAccuracyOnline: false,
        keepRawGPSTrack: true
    )

    static func load(
        from defaults: UserDefaults,
        onlineMatchingAvailable: Bool
    ) -> RecordingSessionOptions {
        let profile = defaults.string(
            forKey: RecordingSettings.recordingAccuracyKey
        ).flatMap(RecordingAccuracyProfile.init(rawValue:)) ?? .high
        return RecordingSessionOptions(
            accuracyProfile: profile,
            snapToTrails: storedBool(
                RecordingSettings.snapToTrailsKey,
                defaultValue: true,
                in: defaults
            ),
            improveAccuracyOnline: onlineMatchingAvailable
                && storedBool(
                    RecordingSettings.improveAccuracyOnlineKey,
                    defaultValue: false,
                    in: defaults
                ),
            keepRawGPSTrack: storedBool(
                RecordingSettings.keepRawGPSTrackKey,
                defaultValue: true,
                in: defaults
            )
        )
    }

    private static func storedBool(
        _ key: String,
        defaultValue: Bool,
        in defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

nonisolated struct RecordingPointFlags: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt32

    static let resumed = RecordingPointFlags(rawValue: 1 << 0)
    static let stationary = RecordingPointFlags(rawValue: 1 << 1)
    static let widgetSourced = RecordingPointFlags(rawValue: 1 << 2)
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
        elevation: Double? = nil,
        horizontalAccuracy: Double,
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

        if location.verticalAccuracy >= 0, location.verticalAccuracy <= 15 {
            elevation = location.altitude
        } else {
            elevation = nil
        }
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
            timestamp: timestamp
        )
    }
}

nonisolated enum RecordingFixPolicy {
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 50
    static let preferredHorizontalAccuracy: CLLocationAccuracy = 20
    static let maximumSpeed: CLLocationSpeed = 8
    static let minimumDisplacement: CLLocationDistance = 5
    static let maximumInterval: TimeInterval = 10
    static let bearingChangeDegrees = 15.0

    static func accepts(
        _ location: CLLocation,
        after previous: RecordingPoint?,
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
        ) else {
            return false
        }

        guard let previous else { return true }

        let interval = location.timestamp.timeIntervalSince(previous.timestamp)
        guard interval > 0 else { return false }

        let displacement = RouteGeometry.distanceMeters(
            from: previous.coordinate,
            to: location.coordinate
        )
        let impliedSpeed = displacement / interval
        if impliedSpeed > maximumSpeed, !reportedSpeedSupports(impliedSpeed, location.speed) {
            return false
        }

        let displacementGate = max(
            minimumDisplacement,
            location.horizontalAccuracy * 0.5
        )
        if displacement >= displacementGate || interval >= maximumInterval {
            return true
        }

        guard let previousCourse = previous.course,
              let nextCourse = LocationFixPolicy.course(of: location)
        else {
            return false
        }
        return angularDifference(previousCourse, nextCourse) > bearingChangeDegrees
    }

    private static func reportedSpeedSupports(
        _ impliedSpeed: CLLocationSpeed,
        _ reportedSpeed: CLLocationSpeed
    ) -> Bool {
        guard reportedSpeed >= 0 else { return false }
        let tolerance = max(2, impliedSpeed * 0.35)
        return abs(reportedSpeed - impliedSpeed) <= tolerance
    }

    private static func angularDifference(_ lhs: Double, _ rhs: Double) -> Double {
        let difference = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }
}

/// Distance accumulation that can retract a short window of GPS wander when
/// the walker has remained within one small area for long enough.
nonisolated struct RecordingDistanceAccumulator: Sendable {
    private(set) var distanceMeters = 0.0
    private(set) var isStationary = false
    /// Time actually spent recording: the sum of the gaps between consecutive
    /// accepted points, minus the gap a pause opened. Averaging distance over
    /// wall-clock instead would let a long lunch stop drag the pace down for a
    /// walk the recorder wasn't even watching.
    private(set) var recordedDuration = 0.0

    private var previous: RecordingPoint?
    private var movementWindowStart: RecordingPoint?
    private var movementWindowDistance = 0.0
    private var stationaryAnchor: RecordingPoint?

    private static let stationaryInterval: TimeInterval = 30
    private static let stationaryNetDisplacement: CLLocationDistance = 15
    private static let resumeDisplacement: CLLocationDistance = 20

    var averageSpeedMetersPerSecond: Double? {
        recordedDuration > 0 ? distanceMeters / recordedDuration : nil
    }

    @discardableResult
    mutating func append(_ point: RecordingPoint) -> Double {
        guard let previous else {
            self.previous = point
            movementWindowStart = point
            return distanceMeters
        }

        if point.flags.contains(.resumed) {
            self.previous = point
            movementWindowStart = point
            movementWindowDistance = 0
            stationaryAnchor = nil
            isStationary = false
            return distanceMeters
        }

        recordedDuration += max(
            0,
            point.timestamp.timeIntervalSince(previous.timestamp)
        )

        if isStationary {
            let anchor = stationaryAnchor ?? previous
            let displacement = RouteGeometry.distanceMeters(
                from: anchor.coordinate,
                to: point.coordinate
            )
            self.previous = point
            guard displacement > Self.resumeDisplacement else {
                return distanceMeters
            }

            isStationary = false
            stationaryAnchor = nil
            distanceMeters += displacement
            movementWindowStart = point
            movementWindowDistance = 0
            return distanceMeters
        }

        let leg = RouteGeometry.distanceMeters(
            from: previous.coordinate,
            to: point.coordinate
        )
        distanceMeters += leg
        movementWindowDistance += leg
        self.previous = point

        guard let movementWindowStart,
              point.timestamp.timeIntervalSince(movementWindowStart.timestamp)
                >= Self.stationaryInterval
        else {
            return distanceMeters
        }

        let netDisplacement = RouteGeometry.distanceMeters(
            from: movementWindowStart.coordinate,
            to: point.coordinate
        )
        if netDisplacement < Self.stationaryNetDisplacement {
            distanceMeters = max(0, distanceMeters - movementWindowDistance)
            movementWindowDistance = 0
            stationaryAnchor = movementWindowStart
            isStationary = true
        } else {
            self.movementWindowStart = point
            movementWindowDistance = 0
        }
        return distanceMeters
    }
}

nonisolated struct PreparedRecording: Sendable {
    let route: [RouteCoordinate]
    /// The unmatched trace, kept once matching makes `route` differ from it.
    let rawRoute: [RouteCoordinate]
    let distanceMeters: Double
    let startedAt: Date
    let endedAt: Date
    let matchedTrailName: String?
    let ambiguousLegCount: Int
}

nonisolated enum RecordingPreparation {
    /// Turns journalled fixes into the values a `Hike` is built from.
    static func prepare(
        points: [RecordingPoint],
        startedAt: Date,
        endedAt: Date,
        graph: TrailGraph? = nil,
        gapDistances: [Int: Double] = [:],
        keepRawGPSTrack: Bool = true
    ) throws(RecordingFailure) -> PreparedRecording {
        let deduplicated = normalizedPoints(points)
        guard deduplicated.count > 1 else { throw .tooShort }

        let rawRoute = deduplicated.map(\.routeCoordinate)
        let match = graph.map {
            TrailMatcher.match(
                points: deduplicated,
                graph: $0,
                gapDistances: gapDistances
            )
        }
        let usesMatchedRoute = (match?.matchedLegCount ?? 0) > 0
            && match?.didMoveRoute == true
        let preparedPoints = usesMatchedRoute
            ? (match?.points ?? deduplicated)
            : deduplicated

        let distanceMeters: Double
        if usesMatchedRoute {
            distanceMeters = matchedDistance(preparedPoints)
        } else {
            var accumulator = RecordingDistanceAccumulator()
            for point in preparedPoints {
                accumulator.append(point)
            }
            distanceMeters = accumulator.distanceMeters
        }
        return PreparedRecording(
            route: preparedPoints.map(\.routeCoordinate),
            // No match means `route` already is the raw trace; a second copy
            // would double the row without preserving any additional fact.
            rawRoute: usesMatchedRoute && keepRawGPSTrack ? rawRoute : [],
            distanceMeters: distanceMeters,
            startedAt: startedAt,
            endedAt: endedAt,
            matchedTrailName: usesMatchedRoute
                ? match?.matchedTrailName
                : nil,
            ambiguousLegCount: match?.ambiguousLegCount ?? 0
        )
    }

    static func normalizedPoints(
        _ points: [RecordingPoint]
    ) -> [RecordingPoint] {
        let ordered = points.sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            let firstIsWidget = $0.flags.contains(.widgetSourced)
            let secondIsWidget = $1.flags.contains(.widgetSourced)
            if firstIsWidget != secondIsWidget {
                return !firstIsWidget
            }
            return $0.horizontalAccuracy < $1.horizontalAccuracy
        }
        let foregroundTimestamps = ordered.compactMap {
            $0.flags.contains(.widgetSourced) ? nil : $0.timestamp
        }
        var deduplicated: [RecordingPoint] = []
        deduplicated.reserveCapacity(ordered.count)
        for point in ordered {
            if point.flags.contains(.widgetSourced),
               hasTimestamp(
                   near: point.timestamp,
                   in: foregroundTimestamps,
                   tolerance: 5
               ) {
                continue
            }
            guard point.timestamp != deduplicated.last?.timestamp else {
                continue
            }
            deduplicated.append(point)
        }
        return deduplicated
    }

    private static func hasTimestamp(
        near timestamp: Date,
        in orderedTimestamps: [Date],
        tolerance: TimeInterval
    ) -> Bool {
        var lowerBound = 0
        var upperBound = orderedTimestamps.count
        let earliest = timestamp.addingTimeInterval(-tolerance)
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if orderedTimestamps[midpoint] < earliest {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        guard lowerBound < orderedTimestamps.count else { return false }
        return orderedTimestamps[lowerBound]
            <= timestamp.addingTimeInterval(tolerance)
    }

    private static func matchedDistance(
        _ points: [RecordingPoint]
    ) -> Double {
        guard points.count > 1 else { return 0 }
        var distance = 0.0
        for index in 1..<points.count {
            guard !points[index].flags.contains(.resumed) else { continue }
            distance += RouteGeometry.distanceMeters(
                from: points[index - 1].coordinate,
                to: points[index].coordinate
            )
        }
        return distance
    }
}

@MainActor
@Observable
final class RecordingStats {
    nonisolated deinit {}

    var distanceMeters = 0.0
    var pointCount = 0
    var horizontalAccuracy: Double?
    var matchedTrailName: String?
    var averageSpeedMetersPerSecond: Double?

    func reset() {
        distanceMeters = 0
        pointCount = 0
        horizontalAccuracy = nil
        matchedTrailName = nil
        averageSpeedMetersPerSecond = nil
    }
}

@MainActor
@Observable
final class RecordingTrace {
    nonisolated deinit {}

    static let chunkSize = 256

    @ObservationIgnored private(set) var committedChunks: [[CLLocationCoordinate2D]] = []
    @ObservationIgnored private(set) var tail: [CLLocationCoordinate2D] = []
    @ObservationIgnored private(set) var generation = 0
    private(set) var revision = 0

    func append(_ coordinate: CLLocationCoordinate2D) {
        tail.append(coordinate)
        if tail.count >= Self.chunkSize {
            committedChunks.append(tail)
            tail = tail.last.map { [$0] } ?? []
        }
        revision &+= 1
    }

    func replace(with coordinates: [CLLocationCoordinate2D]) {
        generation &+= 1
        committedChunks = []
        tail = []
        guard !coordinates.isEmpty else {
            revision &+= 1
            return
        }

        var start = 0
        while coordinates.count - start >= Self.chunkSize {
            let end = start + Self.chunkSize
            committedChunks.append(Array(coordinates[start..<end]))
            start = end - 1
        }
        tail = Array(coordinates[start...])
        revision &+= 1
    }

    func reset() {
        generation &+= 1
        committedChunks = []
        tail = []
        revision &+= 1
    }

    func widgetPolyline(
        maxPoints: Int = 180
    ) -> [SharedTrailSnapshot.CodableCoordinate] {
        guard maxPoints > 0 else { return [] }
        let committedCount = committedChunks.enumerated().reduce(0) {
            $0 + max(0, $1.element.count - ($1.offset == 0 ? 0 : 1))
        }
        let tailCount = max(
            0,
            tail.count - (committedChunks.isEmpty ? 0 : 1)
        )
        let totalCount = committedCount + tailCount
        guard totalCount > 0 else { return [] }

        let outputCount = min(maxPoints, totalCount)
        let targetIndices: [Int]
        if outputCount == 1 {
            targetIndices = [0]
        } else {
            let stride = Double(totalCount - 1) / Double(outputCount - 1)
            targetIndices = (0..<outputCount).map {
                min(Int((Double($0) * stride).rounded()), totalCount - 1)
            }
        }

        var result: [SharedTrailSnapshot.CodableCoordinate] = []
        result.reserveCapacity(outputCount)
        var globalIndex = 0
        var targetIndex = 0

        func consume(_ coordinate: CLLocationCoordinate2D) {
            guard targetIndex < targetIndices.count else {
                globalIndex += 1
                return
            }
            if globalIndex == targetIndices[targetIndex] {
                result.append(
                    SharedTrailSnapshot.CodableCoordinate(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                )
                targetIndex += 1
            }
            globalIndex += 1
        }

        for (chunkIndex, chunk) in committedChunks.enumerated() {
            let start = chunkIndex == 0 ? 0 : 1
            for coordinate in chunk.dropFirst(start) {
                consume(coordinate)
            }
        }
        let tailStart = committedChunks.isEmpty ? 0 : 1
        for coordinate in tail.dropFirst(tailStart) {
            consume(coordinate)
        }
        return result
    }
}
