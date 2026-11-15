//
//  DrawnRouteSquare.swift
//  OpenHikes
//
//  One square of the hiking-routes layer, ready to stroke: its lines in map
//  points, each with its bounding rectangle, the networks of the routes that
//  share it and their signs, and joined end to end.
//
//  **Joined, because OpenStreetMap cuts a route into many short ways.** A
//  square holds each way once — see ``RouteSquareFile`` — and a route is
//  dozens of them, split at every junction and bridge. Stroked one way at a
//  time, the overview square over the Alps was 105,663 lines of two points
//  each, every one a subpath with two round caps: a zoom-7 tile took 6.9
//  seconds to draw on a simulator, and every overlay on the map, the base
//  map's tiles included, waited behind it. Ways that meet end to end are
//  joined here, once, as a square is read — the ends are the same
//  OpenStreetMap node, and simplification keeps ends, so they meet exactly.
//
//  **Joined only where the same routes run.** A line is a stretch every one
//  of its routes shares, which is what a sign stands along and what
//  ``HikingRoutesStyle`` strokes by: where a route leaves, the line ends and
//  another begins.
//
//  **The short way round the antimeridian.** A step from 179.9° to −179.9°
//  is 21 km of ground, and taken as two map points it was a line back across
//  the whole map, through Greenwich. Each step of a line here takes the short
//  way instead, so a line that crosses runs on past the world's east or west
//  edge, its first point where the map has it, and its box, its length and
//  where its signs stand along it are all of the ground it crosses. The tiles
//  at both edges of the map draw it — see ``HikingRoutesDrawing``.
//

import Algorithms
import CoreLocation
import DequeModule
import Foundation
import MapKit
import OrderedCollections

nonisolated struct DrawnRouteSquare: Sendable {
    nonisolated struct Line: Sendable {
        /// Every network among the routes that share this line.
        let networks: RouteNetworkSet
        /// Those routes' signs, as indices into the square's
        /// ``DrawnRouteSquare/signs``: each different sign once, the most
        /// important network's first.
        let signs: [Int]
        /// Off the world's east or west edge where the line crosses the
        /// antimeridian. See this file's header.
        let points: [MKMapPoint]
        /// The points' box, past the world's edge with them.
        let bounds: MKMapRect
        /// The line's length, in map points.
        let length: Double
    }

    /// How many signs of the regional routes and up one line carries, and
    /// how many of its local routes': Waymarked Trails' five of each.
    static let maximumSignsPerLine = 5

    let lines: [Line]
    /// Every different sign among the square's routes.
    let signs: [WaymarkSign]
    /// Each sign's size in tile pixels, measured once rather than at every
    /// draw.
    let signSizes: [CGSize]
    /// Every line's points, counted: what a square costs to hold.
    let pointCount: Int
    /// The ground whose signs are this square's to place, or `nil` for a
    /// square that places every sign along its lines. A line runs a segment
    /// past its square's edge, into ground the next square places.
    let ground: MKMapRect?
    /// Where the signs stand at each zoom, worked out when a tile first asks.
    let placements = WaymarkPlacements()

    static let empty = Self(lines: [], signs: [], pointCount: 0, ground: nil)

    private init(lines: [Line], signs: [WaymarkSign], pointCount: Int, ground: MKMapRect?) {
        self.lines = lines
        self.signs = signs
        signSizes = signs.map(\.size)
        self.pointCount = pointCount
        self.ground = ground
    }

    /// The file's lines in map points, joined end to end where the same
    /// routes run, leaving out the ones `square`'s zooms never stroke.
    init(_ file: RouteSquareFile, square: RouteSquare? = nil) {
        let scale = Double(file.coordinateScale)
        let routes = RouteSigns(file.routes)
        let grouped = Dictionary(grouping: file.lines.filter { $0.points.count > 1 }, by: \.routes)
        var count = 0
        var drawn: [Line] = []
        for shared in grouped.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let ways = grouped[shared] ?? []
            let networks = routes.networks(of: shared, or: ways.first?.network ?? .other)
            if let level = square?.level, !HikingRoutesStyle.isDrawn(networks, at: level) { continue }
            let shown = routes.signs(of: shared)
            for run in Self.joined(ways.map(\.points)) {
                let points = Self.mapPoints(run, scale: scale)
                count += points.count
                drawn.append(Line(
                    networks: networks,
                    signs: shown,
                    points: points,
                    bounds: Self.bounds(of: points),
                    length: Self.length(of: points)
                ))
            }
        }
        self.init(lines: drawn, signs: routes.signs, pointCount: count, ground: square.map(Self.ground(of:)))
    }

    static func mapPoint(_ point: RouteSquareFile.Point, scale: Double) -> MKMapPoint {
        MKMapPoint(CLLocationCoordinate2D(
            latitude: Double(point.latitude) / scale,
            longitude: Double(point.longitude) / scale
        ))
    }

    /// `run` in map points, each step the short way round: a step across the
    /// antimeridian goes on past the world's edge, by the world's width.
    static func mapPoints(_ run: [RouteSquareFile.Point], scale: Double) -> [MKMapPoint] {
        let width = MKMapSize.world.width
        var previous: MKMapPoint?
        return run.map { point in
            var projected = mapPoint(point, scale: scale)
            if let previous {
                projected.x -= ((projected.x - previous.x) / width).rounded() * width
            }
            previous = projected
            return projected
        }
    }

    /// `runs` joined wherever one ends where another starts or ends, each run
    /// used once. A junction of three keeps going along one of them, and the
    /// third starts a line of its own.
    ///
    /// A line grows at its start as often as at its end, because ways come in
    /// OpenStreetMap's order rather than the walking order, so it is a `Deque`.
    /// An array, copied whole for every way put before it, took 30 ms to join
    /// 16,000 ways that came in backward and 2 ms for the same ways in order;
    /// the deque takes 3 ms backward, measured in a release build on a Mac.
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
            var line = Deque(runs[start])
            while let end = line.last {
                let next = take(from: end)
                guard !next.isEmpty else { break }
                line.append(contentsOf: next.dropFirst())
            }
            while let end = line.first {
                let previous = take(from: end)
                guard !previous.isEmpty else { break }
                line.prepend(contentsOf: previous.dropFirst().reversed())
            }
            joined.append(Array(line))
        }
        return joined
    }
}

// MARK: - Across the antimeridian

nonisolated extension DrawnRouteSquare {
    /// How far a line or a sign is moved to draw it on each copy of the world
    /// a tile can meet it on: none, and a world's width either way. MapKit
    /// names every tile on the world's own copy, and a line across the
    /// antimeridian runs off that copy's edge.
    static let worldCopies = [0, -MKMapSize.world.width, MKMapSize.world.width]

    /// `point` moved onto the world's own copy, where MapKit names its tiles
    /// and a square's ground is.
    static func onTheWorld(_ point: MKMapPoint) -> MKMapPoint {
        let width = MKMapSize.world.width
        return MKMapPoint(x: point.x - (point.x / width).rounded(.down) * width, y: point.y)
    }
}

// MARK: - Measuring

nonisolated private extension DrawnRouteSquare {
    /// The furthest north and south a map point is defined: the edge of the
    /// square map of the world.
    static let mapLatitudeLimit: Double = 85

    static func bounds(of points: [MKMapPoint]) -> MKMapRect {
        guard let across = points.lazy.map(\.x).minAndMax(), let down = points.lazy.map(\.y).minAndMax() else {
            return .null
        }
        return MKMapRect(x: across.min, y: down.min, width: across.max - across.min, height: down.max - down.min)
    }

    static func length(of points: [MKMapPoint]) -> Double {
        points.adjacentPairs().reduce(0) { length, step in
            length + hypot(step.1.x - step.0.x, step.1.y - step.0.y)
        }
    }

    /// The ground `square` covers, in map points.
    static func ground(of square: RouteSquare) -> MKMapRect {
        let bounds = RouteSquareGrid.bounds(of: square)
        let northWest = MKMapPoint(CLLocationCoordinate2D(
            latitude: min(bounds.north, mapLatitudeLimit),
            longitude: bounds.west
        ))
        let southEast = MKMapPoint(CLLocationCoordinate2D(
            latitude: max(bounds.south, -mapLatitudeLimit),
            longitude: bounds.east
        ))
        return MKMapRect(
            x: northWest.x,
            y: northWest.y,
            width: max(0, southEast.x - northWest.x),
            height: max(0, southEast.y - northWest.y)
        )
    }
}

// MARK: - The routes' networks and signs

/// What a square's routes are drawn as: each one's network, and its sign as
/// an index into a table that holds each different sign once.
nonisolated private struct RouteSigns {
    private let table: OrderedSet<WaymarkSign>
    private let networks: [RouteNetwork]
    private let signOfRoute: [Int?]

    /// Every different sign among the routes, in the order they were met.
    var signs: [WaymarkSign] { Array(table) }

    init(_ routes: [RouteSquareFile.Route]) {
        networks = routes.map { RouteNetwork(tag: $0.tags["network"]) }
        var met: OrderedSet<WaymarkSign> = []
        signOfRoute = routes.map { route in
            WaymarkSign(tags: route.tags).map { met.append($0).index }
        }
        table = met
    }

    /// Every network among `routes`, or `fallback`'s for a line that names
    /// none this table holds.
    func networks(of routes: [Int], or fallback: RouteNetwork) -> RouteNetworkSet {
        let named = routes.filter(networks.indices.contains)
        guard !named.isEmpty else { return RouteNetworkSet(fallback) }
        return named.reduce(into: RouteNetworkSet()) { $0.formUnion(RouteNetworkSet(networks[$1])) }
    }

    /// The different signs among `routes`, the most important network's
    /// first, and no more of the long routes' or of the local ones' than
    /// ``DrawnRouteSquare/maximumSignsPerLine``.
    func signs(of routes: [Int]) -> [Int] {
        let different = routes
            .compactMap { signOfRoute.indices.contains($0) ? signOfRoute[$0] : nil }
            .uniqued()
            .sorted { lhs, rhs in
                table[lhs].network != table[rhs].network ? table[lhs].network > table[rhs].network : lhs < rhs
            }
        // `partitioned(by:)` answers (does not satisfy, satisfies), and each
        // half keeps the order above.
        let (local, long) = different.partitioned { table[$0].network > .local }
        return Array(long.prefix(DrawnRouteSquare.maximumSignsPerLine))
            + local.prefix(DrawnRouteSquare.maximumSignsPerLine)
    }
}
