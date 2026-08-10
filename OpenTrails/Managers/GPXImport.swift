//
//  GPXImport.swift
//  OpenTrails
//
//  Reads a .gpx file into an ordered list of points using CoreGPX.
//  Prefers track points, falling back to route points, then waypoints, and
//  pulls whatever metadata a well-formed file provides.
//

import Foundation
import CoreLocation
import CoreGPX

nonisolated enum GPXImport {
    struct Point {
        var coordinate: CLLocationCoordinate2D
        var elevation: Double?
        var time: Date?
    }

    struct Track {
        var name: String?
        var trackDescription: String?
        var author: String?
        var keywords: String?
        /// Activity start time, from the metadata or the first timestamped point.
        var startTime: Date?
        var points: [Point]

        var coordinates: [CLLocationCoordinate2D] { points.map(\.coordinate) }

        /// Total length in meters, summed between consecutive points.
        var distanceMeters: Double {
            guard points.count > 1 else { return 0 }
            var total = 0.0
            for i in 1..<points.count {
                let a = CLLocation(latitude: points[i - 1].coordinate.latitude, longitude: points[i - 1].coordinate.longitude)
                let b = CLLocation(latitude: points[i].coordinate.latitude, longitude: points[i].coordinate.longitude)
                total += b.distance(from: a)
            }
            return total
        }
    }

    /// Parses the file at `url`. Returns nil if it can't be read or has no points.
    static func load(from url: URL) -> Track? {
        guard let parser = GPXParser(withURL: url),
              let root = parser.parsedData() else { return nil }
        return track(from: root)
    }

    private static func track(from root: GPXRoot) -> Track? {
        var points: [Point] = []

        // Tracks → segments → points.
        for track in root.tracks {
            for segment in track.segments {
                points.append(contentsOf: segment.points.compactMap(point))
            }
        }
        // Fall back to routes, then loose waypoints.
        if points.isEmpty {
            for route in root.routes {
                points.append(contentsOf: route.points.compactMap(point))
            }
        }
        if points.isEmpty {
            points = root.waypoints.compactMap(point)
        }

        guard !points.isEmpty else { return nil }

        let metadata = root.metadata
        let firstTrack = root.tracks.first
        return Track(
            name: nonEmpty(firstTrack?.name ?? metadata?.name),
            trackDescription: nonEmpty(firstTrack?.desc ?? firstTrack?.comment ?? metadata?.desc),
            author: nonEmpty(metadata?.author?.name),
            keywords: nonEmpty(metadata?.keywords),
            startTime: metadata?.time ?? points.first(where: { $0.time != nil })?.time,
            points: points
        )
    }

    /// Web Mercator's valid latitude range — `SlippyTileMath.tileY` uses `tan`/`log`
    /// that blow up as latitude approaches ±90°, so points beyond this are rejected
    /// rather than risking an `Int(floor(...))` trap downstream.
    private static let maximumMercatorLatitude = 85.0511287798

    private static func point(_ waypoint: GPXWaypoint) -> Point? {
        guard
            let lat = waypoint.latitude, let lon = waypoint.longitude,
            (-maximumMercatorLatitude...maximumMercatorLatitude).contains(lat), (-180...180).contains(lon)
        else { return nil }
        return Point(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            elevation: waypoint.elevation,
            time: waypoint.time
        )
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
