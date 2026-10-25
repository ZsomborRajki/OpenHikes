//
//  SharedTrailSnapshot.swift
//  OpenHikesShared
//
//  The small, precomputed payload the main app writes and the widget reads.
//  Assembled only by the main app process (foreground or a
//  background significant-location-change relaunch) — nothing downstream ever
//  recomputes trail geometry or GPS matching itself.
//

import Foundation

/// Identifies the trail widget's timeline kind, shared so the widget's `kind:`
/// and the app's `reloadTimelines(ofKind:)` call can never drift apart.
public enum TrailWidgetKind {
    public static let id = "TrailWidget"
}

public struct SharedTrailSnapshot: SharedPayload, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int

    public var hikeID: UUID
    public var title: String
    public var tintHex: String
    public var totalDistanceMeters: Double
    public var elevationLowMeters: Double?
    public var elevationHighMeters: Double?
    /// Cumulative climb over the whole route, summed between consecutive
    /// points that carry an elevation — not `high - low`, which a rolling
    /// trail understates by every descent it makes on the way up.
    public var elevationGainMeters: Double?
    /// Cumulative descent, the companion to ``elevationGainMeters``.
    public var elevationLossMeters: Double?
    /// Decimated route, in order — enough points to draw the trail's shape,
    /// not the full track. See ``line(of:cutAt:maxPoints:pauseEndBudget:coordinate:)``.
    public var polyline: [CodableCoordinate]
    /// The indices into ``polyline`` of the points a pause arrives at, in
    /// order — the convention ``WatchTrailPackage/pauseIndices`` keeps.
    ///
    /// The leg arriving at each one is a drive, a lift or the jump between two
    /// GPX `<trkseg>`s, and is not trail (#962), so the widget draws it faded
    /// and dotted rather than as the line (#1034), cut there by
    /// ``TrailStroke``'s pieces. Only a leg that is the pause alone is named
    /// here: the decimation keeps both ends of a pause it names, and one it
    /// could not afford is not named at all rather than folded into a leg
    /// with walking in it.
    public var pauseIndices: [Int]
    public var liveFix: LiveFix?
    /// The walk under way along this trail, if there is one — see ``Walk``.
    ///
    /// While it is present the percentage in ``statusText`` is
    /// coverage rather than position, and its caption says so.
    public var walk: Walk?
    public var updatedAt: Date

    public init(
        hikeID: UUID,
        title: String,
        tintHex: String,
        totalDistanceMeters: Double,
        polyline: [CodableCoordinate],
        pauseIndices: [Int] = [],
        elevationLowMeters: Double? = nil,
        elevationHighMeters: Double? = nil,
        elevationGainMeters: Double? = nil,
        elevationLossMeters: Double? = nil,
        liveFix: LiveFix? = nil,
        walk: Walk? = nil,
        updatedAt: Date = .now
    ) {
        self.hikeID = hikeID
        self.title = title
        self.tintHex = tintHex
        self.totalDistanceMeters = totalDistanceMeters
        self.elevationLowMeters = elevationLowMeters
        self.elevationHighMeters = elevationHighMeters
        self.elevationGainMeters = elevationGainMeters
        self.elevationLossMeters = elevationLossMeters
        self.polyline = polyline
        self.pauseIndices = pauseIndices
        self.liveFix = liveFix
        self.walk = walk
        self.updatedAt = updatedAt
        schemaVersion = Self.currentSchemaVersion
    }

    /// What the app has recorded about the walk in progress along the trail:
    /// how much of it has been covered, whether the hiker has paused, and
    /// how long they have been moving.
    ///
    /// Coverage rather than position, deliberately. ``fractionComplete``
    /// reads where the hiker *is*; this reads how much of the route their
    /// consecutive matches have actually spanned, so a hiker who opened the
    /// app on the return leg of an out-and-back reads 50% here where the
    /// position would say 100%. The app computes it — the widget and the
    /// Live Activity only ever draw it.
    public struct Walk: Codable, Sendable, Equatable {
        /// Whether coverage is still accruing. A `String` raw value for the
        /// reason `HikeActivityAttributes.ContentState.RunState` has one:
        /// legible on the wire, and stable if the cases are reordered.
        public enum State: String, Codable, Sendable {
            case active = "active"
            case finished = "finished"
            case paused = "paused"
        }

        public var state: State
        /// Covered length over the route's length, 0...1.
        public var coveredFraction: Double
        /// The furthest point along the route any match reached, in metres.
        public var furthestDistanceMeters: Double
        /// The walk's clock with its pauses taken out.
        public var activeSeconds: TimeInterval
        public var startedAt: Date
        /// How long the rest of the trail takes at this walk's own pace, or
        /// `nil` when the app had nothing honest to say — the app's
        /// `WalkTimeLeft` decides. Computed there because the route's heights
        /// are there; carried here so the Lock Screen says the same figure.
        public var secondsLeft: TimeInterval?

        public init(
            state: State,
            coveredFraction: Double,
            furthestDistanceMeters: Double,
            activeSeconds: TimeInterval,
            startedAt: Date,
            secondsLeft: TimeInterval? = nil
        ) {
            self.state = state
            self.coveredFraction = coveredFraction
            self.furthestDistanceMeters = furthestDistanceMeters
            self.activeSeconds = activeSeconds
            self.startedAt = startedAt
            self.secondsLeft = secondsLeft
        }
    }

    public struct LiveFix: Codable, Sendable, Equatable {
        public var coordinate: CodableCoordinate
        public var distanceAlongRouteMeters: Double
        public var offRouteMeters: Double
        /// The *trail's* elevation where the hiker was matched, not the
        /// altitude their receiver reported. Read off the same profile the
        /// match came from, so the number agrees with the elevation chart in
        /// the app rather than with GPS vertical noise.
        public var elevationMeters: Double?
        public var timestamp: Date

        public init(
            coordinate: CodableCoordinate,
            distanceAlongRouteMeters: Double,
            offRouteMeters: Double,
            timestamp: Date,
            elevationMeters: Double? = nil
        ) {
            self.coordinate = coordinate
            self.distanceAlongRouteMeters = distanceAlongRouteMeters
            self.offRouteMeters = offRouteMeters
            self.elevationMeters = elevationMeters
            self.timestamp = timestamp
        }
    }

    /// A `Codable`, `Sendable` stand-in for `CLLocationCoordinate2D` (which is
    /// neither), so this package doesn't need to import CoreLocation.
    public struct CodableCoordinate: Codable, Sendable, Equatable {
        public var latitude: Double
        public var longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// Distance remaining to the end of the route from the live fix, if any.
    public var remainingDistanceMeters: Double? {
        guard let liveFix else { return nil }
        return max(0, totalDistanceMeters - liveFix.distanceAlongRouteMeters)
    }

    /// Fraction of the route completed so far, 0...1, if there's a live fix.
    public var fractionComplete: Double? {
        guard let liveFix, totalDistanceMeters > 0 else { return nil }
        return min(1, max(0, liveFix.distanceAlongRouteMeters / totalDistanceMeters))
    }

    /// The fraction the progress bar should draw: the walk's coverage while
    /// one is under way, otherwise the live position. `nil` when there is
    /// neither — nothing to draw a bar for.
    public var progressFraction: Double? {
        walk?.coveredFraction ?? fractionComplete
    }

}

/// Which of `count` points a line of at most `maxPoints` keeps: a fixed
/// stride that always keeps the first and the last, so the drawn shape's
/// endpoints match the real route. A widget is only ever a few hundred pixels
/// wide, so a simple stride is enough — no need for Douglas-Peucker.
///
/// Indices rather than points, so every caller takes the same points however
/// much it needs from each — the watch's trail package wants the elevation
/// there too — rather than reimplementing the stride. Two implementations of
/// one stride is two roundings that have to agree, and the cost of their
/// disagreeing is a point drawn at one place and labelled with the height of
/// another.
public func decimatedIndices(count: Int, maxPoints: Int = 180) -> [Int] {
    guard count > maxPoints, maxPoints > 1 else { return Array(0..<max(0, count)) }
    let lastIndex = count - 1
    let step = Double(lastIndex) / Double(maxPoints - 1)
    var result: [Int] = []
    result.reserveCapacity(maxPoints)
    for i in 0..<maxPoints {
        result.append(min(Int((Double(i) * step).rounded()), lastIndex))
    }
    return result
}
