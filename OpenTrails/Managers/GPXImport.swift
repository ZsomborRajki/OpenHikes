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
import OpenTrailsShared

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

    /// Why a file couldn't be turned into a hike.
    ///
    /// Worth distinguishing rather than collapsing to "import failed": the
    /// three mean genuinely different things to whoever picked the file, and
    /// send them somewhere different to fix it. The import used to say nothing
    /// at all — a picked file that produced no hike looked exactly like a
    /// picked file that was ignored.
    enum ImportFailure: LocalizedError, Equatable {
        /// Not there, or not well-formed XML — the parser had nothing to work
        /// with. Note that well-formed XML that simply *isn't* GPX (an HTML
        /// page, say) parses happily into an empty document, so it arrives as
        /// ``noUsablePoints`` instead; the copy for that case allows for it.
        case unreadable
        /// Parsed, but nothing in it carried a coordinate this app can project
        /// — no points at all, points missing `lat`/`lon`, or points outside
        /// Web Mercator's range.
        case noUsablePoints
        /// One usable point. Enough to put a pin on a map; not a route — no
        /// length, no elevation profile, nothing to draw. Policy rather than a
        /// parse failure, so ``load(from:)`` still returns such a track and the
        /// import is what refuses it.
        case tooShort

        var errorDescription: String? {
            switch self {
            case .unreadable: "This file couldn’t be read."
            case .noUsablePoints: "No track points were found in this file."
            case .tooShort: "This GPX file has only one track point."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .unreadable: "Check that it’s a .gpx file and isn’t damaged."
            // Deliberately covers "it isn't GPX at all" as well — see the case's
            // own note for why that lands here.
            case .noUsablePoints: "It may not be a GPX file, or its points are missing coordinates or out of range."
            case .tooShort: "A hike needs at least two points to have a route."
            }
        }
    }

    /// Parses the file at `url`.
    ///
    /// A one-point file parses *successfully* — refusing it is the import's
    /// call, not the parser's, and the distinction is what lets the caller say
    /// which of the two happened. See ``ImportFailure``.
    static func load(from url: URL) throws(ImportFailure) -> Track {
        guard let parser = GPXParser(withURL: url), let root = parser.parsedData() else {
            throw .unreadable
        }
        guard let track = track(from: root) else { throw .noUsablePoints }
        return track
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

    private static func point(_ waypoint: GPXWaypoint) -> Point? {
        // Points outside Web Mercator's representable range are rejected at
        // the door rather than clamped: `Mercator` clamps to keep drawing
        // code safe, but a track claiming to pass within 5° of a pole is bad
        // data, not something to silently move onto the map's edge.
        guard
            let lat = waypoint.latitude, let lon = waypoint.longitude,
            Mercator.isRepresentable(latitude: lat, longitude: lon)
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
