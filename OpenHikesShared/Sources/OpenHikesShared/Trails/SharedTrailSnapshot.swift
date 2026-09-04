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

    /// See ``SharedPayload/schemaVersion``: `nil` in bytes written before
    /// versioning existed, which is every payload already in a container at
    /// the moment this shipped. Readable but not settable from outside this
    /// package — a version is a fact about the build that wrote the bytes, and
    /// one a caller could choose would be a version nothing verifies.
    /// ``SharedStore`` stamps it on write.
    public internal(set) var schemaVersion: Int?

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
    /// not the full track. See ``decimate(_:maxPoints:)``.
    public var polyline: [CodableCoordinate]
    public var liveFix: LiveFix?
    /// The walk under way along this trail, if there is one — see ``Walk``.
    ///
    /// Optional, and an optional *key*: a payload written before walks
    /// existed decodes with `nil` here, so this needed no `schemaVersion`
    /// bump. While it is present the percentage in ``statusText`` is
    /// coverage rather than position, and its caption says so.
    public var walk: Walk?
    public var updatedAt: Date

    public init(
        hikeID: UUID,
        title: String,
        tintHex: String,
        totalDistanceMeters: Double,
        polyline: [CodableCoordinate],
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
        self.liveFix = liveFix
        self.walk = walk
        self.updatedAt = updatedAt
        schemaVersion = Self.currentSchemaVersion
    }

    /// What the app has recorded about the walk in progress along the trail:
    /// how much of it has been covered, whether the walker has paused, and
    /// how long they have been moving.
    ///
    /// Coverage rather than position, deliberately. ``fractionComplete``
    /// reads where the walker *is*; this reads how much of the route their
    /// consecutive matches have actually spanned, so a walker who opened the
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

        public init(
            state: State,
            coveredFraction: Double,
            furthestDistanceMeters: Double,
            activeSeconds: TimeInterval,
            startedAt: Date
        ) {
            self.state = state
            self.coveredFraction = coveredFraction
            self.furthestDistanceMeters = furthestDistanceMeters
            self.activeSeconds = activeSeconds
            self.startedAt = startedAt
        }
    }

    public struct LiveFix: Codable, Sendable, Equatable {
        public var coordinate: CodableCoordinate
        public var distanceAlongRouteMeters: Double
        public var offRouteMeters: Double
        /// The *trail's* elevation where the walker was matched, not the
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

    /// "62% · 1.4 mi left" while a live fix is on the trail, otherwise just
    /// the trail's total length. Shared with the iOS widget so the app and
    /// extension cannot drift out of sync.
    ///
    /// During a walk the percentage is coverage and the caption says
    /// *walked*, so the return-leg case reads "50% walked · 0.2 km left"
    /// rather than a contradiction. A paused walk says so first, because on a
    /// widget that is the one word that changes what the number means.
    public var statusText: String {
        if let walk {
            let covered = "\(Self.percent(walk.coveredFraction))% walked"
            let prefix = walk.state == .paused ? "Paused · " : ""
            guard let remainingDistanceMeters else { return prefix + covered }
            let remaining = WidgetFormat.length(meters: remainingDistanceMeters)
            return "\(prefix)\(covered) · \(remaining) left"
        }
        guard let fractionComplete, let remainingDistanceMeters
        else { return WidgetFormat.length(meters: totalDistanceMeters) }
        let remaining = WidgetFormat.length(meters: remainingDistanceMeters)
        return "\(Self.percent(fractionComplete))% · \(remaining) left"
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }
}

// periphery:ignore - exercised by `OpenHikesShared/Tests`, a SwiftPM target
// the Xcode-scheme scan does not index.
/// Decimates an ordered coordinate list to at most `maxPoints` by fixed
/// stride, always keeping the first and last point so the drawn shape's
/// endpoints match the real route. A widget is only ever a few hundred
/// pixels wide, so a simple stride is enough — no need for Douglas-Peucker.
public func decimate(
    _ coordinates: [(latitude: Double, longitude: Double)],
    maxPoints: Int = 180
) -> [SharedTrailSnapshot.CodableCoordinate] {
    decimate(coordinates, maxPoints: maxPoints) { coord in
        SharedTrailSnapshot.CodableCoordinate(latitude: coord.latitude, longitude: coord.longitude)
    }
}

/// Decimates values that can be projected to coordinates without first
/// mapping the entire source collection. Long GPX routes therefore transform
/// only the points the widget will actually keep.
public func decimate<Element>(
    _ elements: [Element],
    maxPoints: Int = 180,
    transform: (Element) -> SharedTrailSnapshot.CodableCoordinate
) -> [SharedTrailSnapshot.CodableCoordinate] {
    guard elements.count > maxPoints, maxPoints > 1 else { return elements.map(transform) }
    let lastIndex = elements.count - 1
    let stride = Double(lastIndex) / Double(maxPoints - 1)
    var result: [SharedTrailSnapshot.CodableCoordinate] = []
    result.reserveCapacity(maxPoints)
    for i in 0..<maxPoints {
        let index = min(Int((Double(i) * stride).rounded()), lastIndex)
        result.append(transform(elements[index]))
    }
    return result
}
