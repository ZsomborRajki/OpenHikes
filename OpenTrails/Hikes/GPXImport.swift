//
//  GPXImport.swift
//  OpenTrails
//
//  Reads a .gpx file into an ordered list of points using CoreGPX.
//  Prefers track points, falling back to route points, then waypoints, and
//  pulls whatever metadata a well-formed file provides.
//

import Algorithms
import CoreGPX
import CoreLocation
import Foundation
import OpenTrailsShared

nonisolated enum GPXImport {
    struct Point: Sendable {
        let coordinate: CLLocationCoordinate2D
        let elevation: Double?
        let time: Date?
    }

    struct Track: Sendable {
        let name: String?
        let trackDescription: String?
        let author: String?
        let keywords: String?
        /// Activity start time, from the metadata or the first timestamped point.
        let startTime: Date?
        let points: [Point]
        let coordinates: [CLLocationCoordinate2D]
        let route: [RouteCoordinate]
        /// Total length in meters, computed once while preparing the import.
        let distanceMeters: Double

        init(
            name: String?,
            trackDescription: String?,
            author: String?,
            keywords: String?,
            startTime: Date?,
            points: [Point]
        ) {
            self.name = name
            self.trackDescription = trackDescription
            self.author = author
            self.keywords = keywords
            self.startTime = startTime
            self.points = points
            coordinates = points.map(\.coordinate)
            route = points.map { point in
                RouteCoordinate(
                    latitude: point.coordinate.latitude,
                    longitude: point.coordinate.longitude,
                    elevation: point.elevation,
                    timestamp: point.time
                )
            }

            var cumulativeDistance = 0.0
            for (start, end) in points.adjacentPairs() {
                cumulativeDistance += RouteGeometry.distanceMeters(
                    from: start.coordinate,
                    to: end.coordinate
                )
            }
            distanceMeters = cumulativeDistance
        }
    }

    /// Why a file couldn't be turned into a hike.
    ///
    /// Worth distinguishing rather than collapsing to "import failed": the
    /// three mean genuinely different things to whoever picked the file, and
    /// send them somewhere different to fix it. The import used to say nothing
    /// at all — a picked file that produced no hike looked exactly like a
    /// picked file that was ignored.
    enum ImportFailure: LocalizedError, Equatable, Sendable {
        /// Parsed, but nothing in it carried a coordinate this app can project
        /// — no points at all, points missing `lat`/`lon`, or points outside
        /// Web Mercator's range.
        case noUsablePoints
        /// One usable point. Enough to put a pin on a map; not a route — no
        /// length, no elevation profile, nothing to draw. Policy rather than a
        /// parse failure, so ``load(from:)`` still returns such a track and the
        /// import is what refuses it.
        case tooShort
        /// Not there, or not well-formed XML — the parser had nothing to work
        /// with. Note that well-formed XML that simply *isn't* GPX (an HTML
        /// page, say) parses happily into an empty document, so it arrives as
        /// ``noUsablePoints`` instead; the copy for that case allows for it.
        case unreadable

        var errorDescription: String? {
            switch self {
            case .noUsablePoints: "No track points were found in this file."
            case .tooShort: "This GPX file has only one track point."
            case .unreadable: "This file couldn't be read."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            // Deliberately covers "it isn't GPX at all" as well — see the case's
            // own note for why that lands here.
            case .noUsablePoints: "It may not be a GPX file, or its points are missing coordinates or out of range."
            case .tooShort: "A hike needs at least two points to have a route."
            case .unreadable: "Check that it's a .gpx file and isn't damaged."
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

    /// Parses and prepares a picked file without occupying the main actor.
    static func loadOffMain(from url: URL) async throws(ImportFailure) -> Track {
        try await runOffMain { () throws(ImportFailure) -> Track in
            try load(from: url)
        }
    }

    /// Runs import preparation on a detached executor. Internal so workload
    /// tests can verify the executor directly without relying on wall-clock
    /// scheduling while unrelated suites run in parallel.
    static func runOffMain<Value: Sendable>(
        _ work: @Sendable @escaping () throws(ImportFailure) -> Value
    ) async throws(ImportFailure) -> Value {
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Value, ImportFailure> in
            assertOffMainThread("GPX parsing and route preparation must stay off the main thread")
            do throws(ImportFailure) { return .success(try work()) } catch { return .failure(error) }
        }.value
        return try result.get()
    }

    private static func track(from root: GPXRoot) -> Track? {
        var points: [Point] = []

        // Tracks → segments → points.
        // This app targets single-track, single-segment GPX files (e.g. Komoot exports).
        // Multi-segment files are flattened: cross-segment edges are treated as
        // continuous route legs. That's intentional — we don't need to support
        // paused recordings or disconnected trail sections.
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
            startTime: metadata?.time ?? points.first { $0.time != nil }?.time,
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
