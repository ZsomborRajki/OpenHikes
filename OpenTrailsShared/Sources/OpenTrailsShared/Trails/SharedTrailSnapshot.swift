//
//  SharedTrailSnapshot.swift
//  OpenTrailsShared
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

public struct SharedTrailSnapshot: Codable, Sendable, Equatable {
    public var hikeID: UUID
    public var title: String
    public var tintHex: String
    public var totalDistanceMeters: Double
    public var elevationLowMeters: Double?
    public var elevationHighMeters: Double?
    /// Decimated route, in order — enough points to draw the trail's shape,
    /// not the full track. See ``decimate(_:maxPoints:)``.
    public var polyline: [CodableCoordinate]
    public var liveFix: LiveFix?
    public var updatedAt: Date

    public init(
        hikeID: UUID,
        title: String,
        tintHex: String,
        totalDistanceMeters: Double,
        elevationLowMeters: Double? = nil,
        elevationHighMeters: Double? = nil,
        polyline: [CodableCoordinate],
        liveFix: LiveFix? = nil,
        updatedAt: Date = .now
    ) {
        self.hikeID = hikeID
        self.title = title
        self.tintHex = tintHex
        self.totalDistanceMeters = totalDistanceMeters
        self.elevationLowMeters = elevationLowMeters
        self.elevationHighMeters = elevationHighMeters
        self.polyline = polyline
        self.liveFix = liveFix
        self.updatedAt = updatedAt
    }

    public struct LiveFix: Codable, Sendable, Equatable {
        public var coordinate: CodableCoordinate
        public var distanceAlongRouteMeters: Double
        public var offRouteMeters: Double
        public var timestamp: Date

        public init(coordinate: CodableCoordinate, distanceAlongRouteMeters: Double, offRouteMeters: Double, timestamp: Date) {
            self.coordinate = coordinate
            self.distanceAlongRouteMeters = distanceAlongRouteMeters
            self.offRouteMeters = offRouteMeters
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

    /// "62% · 1.4 mi left" while a live fix is on the trail, otherwise just
    /// the trail's total length. Shared with the iOS widget so the app and
    /// extension cannot drift out of sync.
    public var statusText: String {
        guard let fractionComplete, let remainingDistanceMeters else {
            return Self.formattedLength(totalDistanceMeters)
        }
        return "\(Int((fractionComplete * 100).rounded()))% · \(Self.formattedLength(remainingDistanceMeters)) left"
    }

    private static func formattedLength(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// Decimates an ordered coordinate list to at most `maxPoints` by fixed
/// stride, always keeping the first and last point so the drawn shape's
/// endpoints match the real route. A widget is only ever a few hundred
/// pixels wide, so a simple stride is enough — no need for Douglas-Peucker.
public func decimate(
    _ coordinates: [(latitude: Double, longitude: Double)],
    maxPoints: Int = 180
) -> [SharedTrailSnapshot.CodableCoordinate] {
    decimate(coordinates, maxPoints: maxPoints) {
        SharedTrailSnapshot.CodableCoordinate(latitude: $0.latitude, longitude: $0.longitude)
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
    guard elements.count > maxPoints, maxPoints > 1 else {
        return elements.map(transform)
    }
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
