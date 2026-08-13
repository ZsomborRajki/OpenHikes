//
//  RecordingModels.swift
//  OpenTrails
//
//  Pure recording policy/state plus the observable leaf models used by the UI
//  and map coordinator.
//

import Algorithms
import CoreLocation
import DequeModule
import Foundation
import Observation
import OpenTrailsShared

nonisolated enum RecordingSettings {
    static let snapToTrailsKey = "settings.snapRecordedHikesToTrails"
    static let keepRawGPSTrackKey =
        "settings.keepRawRecordedGPSTrack"
}

nonisolated struct RecordingSessionOptions: Codable, Equatable, Sendable {
    var snapToTrails: Bool
    var keepRawGPSTrack: Bool

    static let defaults = RecordingSessionOptions(
        snapToTrails: true,
        keepRawGPSTrack: true
    )

    static func load(from defaults: UserDefaults) -> RecordingSessionOptions {
        return RecordingSessionOptions(
            snapToTrails: storedBool(
                RecordingSettings.snapToTrailsKey,
                defaultValue: true,
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
    static let motionStationary = RecordingPointFlags(rawValue: 1 << 3)
    static let nonPedestrian = RecordingPointFlags(rawValue: 1 << 4)
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
            timestamp: timestamp,
            motion: flags.contains(.nonPedestrian)
                ? .nonPedestrian
                : nil
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
        if impliedSpeed > maximumSpeed,
           motionState != .nonPedestrian,
           !reportedSpeedSupports(impliedSpeed, location.speed) {
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
    private var motionStationaryStartedAt: Date?

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
            _ = updateMotionStationaryStart(for: point)
            return distanceMeters
        }

        if point.flags.contains(.resumed) {
            self.previous = point
            movementWindowStart = point
            movementWindowDistance = 0
            stationaryAnchor = nil
            isStationary = false
            _ = updateMotionStationaryStart(for: point)
            return distanceMeters
        }

        let beganMotionStationary = updateMotionStationaryStart(
            for: point
        )
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
            if point.flags.contains(.motionStationary) {
                return distanceMeters
            }
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
        if beganMotionStationary {
            movementWindowStart = point
            movementWindowDistance = 0
            return distanceMeters
        }

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
        let motionConfirmsStationary = motionStationaryStartedAt.map {
            point.timestamp.timeIntervalSince($0)
                >= Self.stationaryInterval
        } ?? false
        if netDisplacement < Self.stationaryNetDisplacement
            || motionConfirmsStationary {
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

    private mutating func updateMotionStationaryStart(
        for point: RecordingPoint
    ) -> Bool {
        if point.flags.contains(.motionStationary) {
            guard motionStationaryStartedAt == nil else { return false }
            motionStationaryStartedAt = point.timestamp
            return true
        } else {
            motionStationaryStartedAt = nil
            return false
        }
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
    let matchResult: TrailMatchResult?
}

nonisolated enum RecordingPreparation {
    /// Turns journalled fixes into the values a `Hike` is built from.
    static func prepare(
        points: [RecordingPoint],
        startedAt: Date,
        endedAt: Date,
        graph: TrailGraph? = nil,
        gapDistances: [Int: Double] = [:],
        keepRawGPSTrack: Bool = true,
        ambiguityChoices: [Int: TrailAmbiguityChoice]? = nil
    ) throws(RecordingFailure) -> PreparedRecording {
        let deduplicated = normalizedPoints(points)
        guard deduplicated.count > 1 else { throw .tooShort }

        let match = graph.map {
            TrailMatcher.match(
                points: deduplicated,
                graph: $0,
                gapDistances: gapDistances
            )
        }
        return preparedRecording(
            points: deduplicated,
            startedAt: startedAt,
            endedAt: endedAt,
            match: match,
            keepRawGPSTrack: keepRawGPSTrack,
            ambiguityChoices: ambiguityChoices
        )
    }

    static func prepareResolved(
        points: [RecordingPoint],
        startedAt: Date,
        endedAt: Date,
        matchResult: TrailMatchResult,
        choices: [Int: TrailAmbiguityChoice],
        keepRawGPSTrack: Bool
    ) throws(RecordingFailure) -> PreparedRecording {
        let deduplicated = normalizedPoints(points)
        guard deduplicated.count > 1 else { throw .tooShort }
        return preparedRecording(
            points: deduplicated,
            startedAt: startedAt,
            endedAt: endedAt,
            match: matchResult,
            keepRawGPSTrack: keepRawGPSTrack,
            ambiguityChoices: choices
        )
    }

    private static func preparedRecording(
        points deduplicated: [RecordingPoint],
        startedAt: Date,
        endedAt: Date,
        match: TrailMatchResult?,
        keepRawGPSTrack: Bool,
        ambiguityChoices: [Int: TrailAmbiguityChoice]?
    ) -> PreparedRecording {
        let rawRoute = deduplicated.map(\.routeCoordinate)
        let preparedPoints: [RecordingPoint]
        if let match, let ambiguityChoices {
            preparedPoints = match.points(resolving: ambiguityChoices)
        } else {
            preparedPoints = match?.points ?? deduplicated
        }
        let usesMatchedRoute = routeMoved(
            preparedPoints,
            from: deduplicated
        )

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
            ambiguousLegCount: ambiguityChoices == nil
                ? match?.ambiguousLegCount ?? 0
                : 0,
            matchResult: match
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
        let foregroundTimestamps = TimestampIndex(
            ordered.compactMap {
                $0.flags.contains(.widgetSourced) ? nil : $0.timestamp
            }
        )
        var deduplicated: [RecordingPoint] = []
        deduplicated.reserveCapacity(ordered.count)
        for point in ordered {
            if point.flags.contains(.widgetSourced),
               foregroundTimestamps.contains(point.timestamp, within: 5) {
                continue
            }
            guard point.timestamp != deduplicated.last?.timestamp else {
                continue
            }
            deduplicated.append(point)
        }
        return deduplicated
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

    private static func routeMoved(
        _ route: [RecordingPoint],
        from raw: [RecordingPoint]
    ) -> Bool {
        guard route.count == raw.count else { return true }
        return zip(route, raw).contains {
            RouteGeometry.distanceMeters(
                from: $0.0.coordinate,
                to: $0.1.coordinate
            ) > 1
        }
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
    @ObservationIgnored private(set) var reviewSegment:
        [CLLocationCoordinate2D] = []
    @ObservationIgnored private(set) var generation = 0
    /// Drained from the front every time a chunk is sealed, so it's a `Deque`
    /// rather than an `Array`: `removeFirst(_:)` on an array shifts every
    /// surviving element down, and this runs on the main actor once per 255
    /// fixes for the whole life of a recording.
    @ObservationIgnored private var stableTail: Deque<CLLocationCoordinate2D> = []
    @ObservationIgnored private var provisionalTail: [CLLocationCoordinate2D] = []
    private(set) var revision = 0

    func append(
        _ coordinate: CLLocationCoordinate2D,
        provisional: Bool = false
    ) {
        reviewSegment = []
        if provisional {
            Self.appendDistinct(coordinate, to: &provisionalTail)
        } else {
            appendStable([coordinate])
            provisionalTail = []
        }
        rebuildTail()
        revision &+= 1
    }

    func replace(with coordinates: [CLLocationCoordinate2D]) {
        replace(stable: coordinates, provisional: [])
    }

    func replace(
        stable stableCoordinates: [CLLocationCoordinate2D],
        provisional provisionalCoordinates: [CLLocationCoordinate2D]
    ) {
        generation &+= 1
        committedChunks = []
        reviewSegment = []
        stableTail = []
        provisionalTail = []
        tail = []
        guard !stableCoordinates.isEmpty
                || !provisionalCoordinates.isEmpty else {
            revision &+= 1
            return
        }

        appendStable(stableCoordinates)
        for coordinate in provisionalCoordinates {
            Self.appendDistinct(coordinate, to: &provisionalTail)
        }
        rebuildTail()
        revision &+= 1
    }

    @discardableResult
    func applyLiveMatch(
        committing stableCoordinates: [CLLocationCoordinate2D],
        provisional provisionalCoordinates: [CLLocationCoordinate2D],
        expectedGeneration: Int
    ) -> Bool {
        guard generation == expectedGeneration else { return false }
        reviewSegment = []
        appendStable(stableCoordinates)
        provisionalTail = []
        for coordinate in provisionalCoordinates {
            Self.appendDistinct(coordinate, to: &provisionalTail)
        }
        rebuildTail()
        revision &+= 1
        return true
    }

    func showReview(
        route: [CLLocationCoordinate2D],
        highlightedSegment: [CLLocationCoordinate2D]?
    ) {
        replace(with: route)
        reviewSegment = highlightedSegment ?? []
        revision &+= 1
    }

    func reset() {
        generation &+= 1
        committedChunks = []
        reviewSegment = []
        stableTail = []
        provisionalTail = []
        tail = []
        revision &+= 1
    }

    private func appendStable(
        _ coordinates: [CLLocationCoordinate2D]
    ) {
        for coordinate in coordinates {
            Self.appendDistinct(coordinate, to: &stableTail)
        }
        while stableTail.count >= Self.chunkSize {
            committedChunks.append(
                Array(stableTail.prefix(Self.chunkSize))
            )
            stableTail.removeFirst(Self.chunkSize - 1)
        }
    }

    private func rebuildTail() {
        tail = Array(stableTail)
        for coordinate in provisionalTail {
            Self.appendDistinct(coordinate, to: &tail)
        }
    }

    private static func appendDistinct<C>(
        _ coordinate: CLLocationCoordinate2D,
        to coordinates: inout C
    ) where C: RangeReplaceableCollection & BidirectionalCollection,
            C.Element == CLLocationCoordinate2D {
        if let previous = coordinates.last,
           RouteGeometry.distanceMeters(
               from: previous,
               to: coordinate
           ) <= 0.05 {
            return
        }
        coordinates.append(coordinate)
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
