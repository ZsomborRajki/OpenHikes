//
//  DrawnRouteSquare.swift
//  OpenHikes
//
//  One square of the hiking-routes layer, ready to stroke: its lines in map
//  points, each with its bounding rectangle, and joined end to end.
//
//  **Joined, because OpenStreetMap cuts a route into many short ways.** A
//  square holds each way once — see ``RouteSquareFile`` — and a route is
//  dozens of them, split at every junction and bridge. Stroked one way at a
//  time, the overview square over the Alps was 105,663 lines of two points
//  each, every one a subpath with two round caps, twice over for the casing:
//  a zoom-7 tile took 6.9 seconds to draw on a simulator, and every overlay
//  on the map, the base map's tiles included, waited behind it. Ways that
//  meet end to end in the same network are joined here, once, as a square is
//  read — the ends are the same OpenStreetMap node, and simplification keeps
//  ends, so they meet exactly.
//

import CoreLocation
import Foundation
import MapKit

nonisolated struct DrawnRouteSquare: Sendable {
    nonisolated struct Line: Sendable {
        let network: RouteNetwork
        /// The next most important network among the routes on this line,
        /// drawn as dots along it: a regional route sharing an international
        /// one's path.
        let secondary: RouteNetwork?
        let points: [MKMapPoint]
        let bounds: MKMapRect
    }

    /// Where one route's sign stands.
    nonisolated struct Waymark: Sendable {
        let point: MKMapPoint
        let sign: WaymarkSign
        /// The sign's size in points, measured once for the route rather
        /// than at every draw.
        let size: CGSize
        /// The route's network, which decides whose sign stays where two
        /// would overlap.
        let network: RouteNetwork
        let routeID: Int64
    }

    let lines: [Line]
    /// Every route's signs, the most important network's first.
    let waymarks: [Waymark]
    /// Every line's points, counted: what a square costs to hold.
    let pointCount: Int

    static let empty = Self(lines: [], waymarks: [], pointCount: 0)

    private init(lines: [Line], waymarks: [Waymark], pointCount: Int) {
        self.lines = lines
        self.waymarks = waymarks
        self.pointCount = pointCount
    }

    /// The file's lines, joined end to end where they share their networks,
    /// in map points, and — at the levels a sign is drawn at — where each
    /// route's signs stand.
    init(_ file: RouteSquareFile, level: RouteSquareLevel = .detail) {
        let scale = Double(file.coordinateScale)
        let routeNetworks = file.routes.map { RouteNetwork(tag: $0.tags["network"]) }
        var count = 0
        var drawn: [Line] = []
        let grouped = Dictionary(grouping: file.lines.filter { $0.points.count > 1 }) { line in
            Pairing(network: line.network, secondary: Self.secondary(of: line, among: routeNetworks))
        }
        for pairing in grouped.keys.sorted() {
            for run in Self.joined(grouped[pairing]?.map(\.points) ?? []) {
                let points = run.map { Self.mapPoint($0, scale: scale) }
                count += points.count
                drawn.append(Line(
                    network: pairing.network,
                    secondary: pairing.secondary,
                    points: points,
                    bounds: Self.bounds(of: points)
                ))
            }
        }
        lines = drawn
        waymarks = Self.waymarks(in: file, spacingMeters: Self.signSpacingMeters(at: level))
        pointCount = count
    }

    /// The most important network among a line's routes other than its own.
    private static func secondary(of line: RouteSquareFile.Line, among networks: [RouteNetwork]) -> RouteNetwork? {
        line.routes
            .compactMap { networks.indices.contains($0) ? networks[$0] : nil }
            .filter { $0 != line.network }
            .max()
    }

    /// The two networks a line is drawn in, ordered the way lines are
    /// stroked: least important first, and a line without dots before one
    /// with them.
    private struct Pairing: Hashable, Comparable {
        let network: RouteNetwork
        let secondary: RouteNetwork?

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.network != rhs.network { return lhs.network < rhs.network }
            return rank(lhs.secondary) < rank(rhs.secondary)
        }

        /// No second network first, then the least important.
        private static func rank(_ network: RouteNetwork?) -> Int {
            network.map { Int($0.rawValue) + 1 } ?? 0
        }
    }

    static func mapPoint(_ point: RouteSquareFile.Point, scale: Double) -> MKMapPoint {
        MKMapPoint(CLLocationCoordinate2D(
            latitude: Double(point.latitude) / scale,
            longitude: Double(point.longitude) / scale
        ))
    }

    /// `runs` joined wherever one ends where another starts or ends, each run
    /// used once. A junction of three keeps going along one of them, and the
    /// third starts a line of its own.
    static func joined(_ runs: [[RouteSquareFile.Point]]) -> [[RouteSquareFile.Point]] {
        var touching: [RouteSquareFile.Point: [Int]] = [:]
        for (index, run) in runs.enumerated() {
            guard let first = run.first, let last = run.last else { continue }
            touching[first, default: []].append(index)
            touching[last, default: []].append(index)
        }
        var used = [Bool](repeating: false, count: runs.count)
        // The unused run touching `end`, turned to start there, or none.
        func take(from end: RouteSquareFile.Point) -> [RouteSquareFile.Point] {
            for index in touching[end] ?? [] where !used[index] {
                used[index] = true
                return runs[index].first == end ? runs[index] : runs[index].reversed()
            }
            return []
        }
        var joined: [[RouteSquareFile.Point]] = []
        for start in runs.indices where !used[start] {
            used[start] = true
            var line = runs[start]
            while let end = line.last {
                let next = take(from: end)
                guard !next.isEmpty else { break }
                line.append(contentsOf: next.dropFirst())
            }
            while let end = line.first {
                let previous = take(from: end)
                guard !previous.isEmpty else { break }
                line = Array(previous.reversed().dropLast()) + line
            }
            joined.append(line)
        }
        return joined
    }

    private static func bounds(of points: [MKMapPoint]) -> MKMapRect {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
