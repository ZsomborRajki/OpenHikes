//
//  RouteBuild.swift
//  trail-cells
//
//  Turning the hiking relations of an OpenStreetMap extract into the squares
//  of the hiking-routes layer: every way of every `route=hiking` relation,
//  once, simplified and filed at each of `RouteSquareLevel`'s four levels.
//
//  Unlike the day hikes' build nothing is left out for being long, unnamed or
//  big: the layer draws every marked route there is. A way the extract holds
//  without positions — one running out of a regional extract — is left out,
//  and the rest of its route is drawn.
//
//  **A way that crosses the date line is read the short way**, when it is
//  simplified and when its squares are found, and filed as it is written:
//  see `Antimeridian`.
//
//  **The same extract always gives the same squares.** Ways are read in the
//  order osmium writes them, which is by id, routes are numbered by relation
//  id, and nothing depends on the clock, so a square's digest changes exactly
//  when OpenStreetMap's routes in it did.
//

import CryptoKit
import Foundation

enum RouteSquareBuild {
    struct Summary {
        var relationsRead = 0
        var routes = 0
        var ways = 0
        var points = 0
        var squares: [RouteSquareLevel: Int] = [:]
        var bytes: [RouteSquareLevel: Int] = [:]
        var largest: [RouteSquareLevel: (name: String, bytes: Int)] = [:]
    }

    /// What `build-routes` writes in a manifest's `kind`, so `upload` knows
    /// which manifest record it is replacing.
    static let manifestKind = "routes"

    static func run(_ options: BuildOptions) throws -> Summary {
        var summary = Summary()
        let catalogue = try RouteCatalogue(relationsAt: options.relationsPath, summary: &summary)
        var filing = RouteFiling()
        var withoutPositions = 0
        try OPLFile(path: options.waysPath).forEachLine { line in
            guard let id = OPL.wayID(line), let routes = catalogue.routes(ofWay: id) else { return }
            guard let way = try OPL.way(line, scale: TrailCellFile.standardCoordinateScale),
                  let points = way.points
            else {
                withoutPositions += 1
                return
            }
            guard points.count > 1 else { return }
            summary.ways += 1
            summary.points += points.count
            filing.file(points, routes: routes, network: catalogue.network(of: routes))
        }
        if summary.ways == 0, withoutPositions > 0 {
            throw BuildError.waysCarryNoPositions(options.waysPath)
        }
        try TrailCellBuild.prepare(options.outputDirectory)
        let cells = try write(filing, catalogue: catalogue, to: options.outputDirectory, summary: &summary)
        try BuildManifest(
            kind: manifestKind,
            generation: RouteSquareGrid.generation,
            complete: options.coversTheWorld,
            builtAt: Date(),
            osmTimestamp: options.osmTimestamp,
            routeCount: summary.routes,
            cells: cells
        )
        .write(to: options.outputDirectory)
        return summary
    }
}

// MARK: - The routes

/// Every hiking relation's tags, numbered in relation-id order, and which of
/// them each way is drawn as part of.
///
/// **A way is drawn as its routes' topmost relations.** A long route is often
/// mapped as a relation for each stage inside a relation for the whole. A
/// stage tagged with the network of the route it is a stage of is that
/// route, not one more: its ways are filed under the whole route alone, so
/// the map shows the Via Alpina's sign along the Via Alpina rather than a
/// number for each of its stages. A relation inside one of another network
/// keeps its place beside it — a national trail an E-path runs along is
/// both. It is the rule Waymarked Trails draws by, and what a way's routes
/// in a square are: the relations it is drawn as, not the ones that name it.
///
/// A route OpenStreetMap calls proposed is left out: nothing marks it on the
/// ground yet. So is a relation of any type but a route's: a `network` or a
/// `collection` tagged `route=hiking` gathers a region's routes and is none of
/// them, and taken for one it would be the topmost relation of every route it
/// lists of its own network, whose numbers and waymarks would be lost under
/// its name. One with no type at all is taken for the route it is tagged as.
private struct RouteCatalogue {
    private static let routeTypes: Set<String?> = ["route", "superroute", nil]

    private(set) var ids: [Int64] = []
    private(set) var tags: [[String: String]] = []
    private var networks: [RouteNetwork] = []
    private var wayRoutes: [Int64: [Int32]] = [:]

    init(relationsAt path: String, summary: inout RouteSquareBuild.Summary) throws {
        var relations: [OPLRelation] = []
        try OPLFile(path: path).forEachLine { line in
            guard let relation = try OPL.relation(line) else { return }
            summary.relationsRead += 1
            // osmium hands over a hiking relation's member relations too,
            // whatever they are, so the tag is asked about again here.
            guard relation.tags["route"] == "hiking", relation.tags["state"] != "proposed",
                  Self.routeTypes.contains(relation.tags["type"])
            else { return }
            relations.append(relation)
        }
        relations.sort { $0.id < $1.id }
        var indices: [Int64: Int32] = [:]
        for relation in relations {
            indices[relation.id] = Int32(ids.count)
            ids.append(relation.id)
            tags.append(relation.tags.filter { RouteSquareFile.keptTags.contains($0.key) })
            networks.append(RouteNetwork(tag: relation.tags["network"]))
        }
        var parents = [[Int32]](repeating: [], count: relations.count)
        for (index, relation) in relations.enumerated() {
            for member in relation.members where member.kind == UInt8(ascii: "r") {
                guard let child = indices[member.ref], child != Int32(index) else { continue }
                parents[Int(child)].append(Int32(index))
            }
        }
        let drawnAs = Self.topmost(parents: parents, networks: relations.map { $0.tags["network"] })
        for (index, relation) in relations.enumerated() {
            for member in relation.members where member.kind == UInt8(ascii: "w") {
                wayRoutes[member.ref, default: []].append(contentsOf: drawnAs[index])
            }
        }
        summary.routes = ids.count
    }

    /// For each relation, the relations its ways are drawn as: itself and
    /// every relation it is inside, however deep, leaving out each one that
    /// is inside a relation of its own network.
    ///
    /// - Parameters:
    ///   - parents: The relations each relation is a member of.
    ///   - networks: Each relation's `network` tag as written, which is what
    ///     is compared: two routes with no network are not one route.
    static func topmost(parents: [[Int32]], networks: [String?]) -> [[Int32]] {
        let isTopmost = parents.indices.map { index in
            guard let network = networks[index] else { return true }
            return !parents[index].contains { networks[Int($0)] == network }
        }
        return parents.indices.map { index in
            var inside: Set<Int32> = [Int32(index)]
            var unread = [Int32(index)]
            while let next = unread.popLast() {
                for parent in parents[Int(next)] where inside.insert(parent).inserted {
                    unread.append(parent)
                }
            }
            let topmost = inside.filter { isTopmost[Int($0)] }.sorted()
            // Relations each inside the next, in a ring, have no topmost one.
            return topmost.isEmpty ? [Int32(index)] : topmost
        }
    }

    /// The routes a way is drawn as part of, each once and in order, or
    /// `nil` for a way no hiking route names.
    func routes(ofWay id: Int64) -> [Int32]? {
        wayRoutes[id].map { Array(Set($0)).sorted() }
    }

    func network(of routes: [Int32]) -> RouteNetwork {
        routes.map { networks[Int($0)] }.max() ?? .other
    }
}

// MARK: - Filing

/// The lines of every square of every level, as they are filed.
private struct RouteFiling {
    struct Line {
        var network: RouteNetwork
        var routes: [Int32]
        var points: [RouteSquareFile.Point]
    }

    private(set) var squares: [RouteSquare: [Line]] = [:]

    /// Files one way at every level whose networks it is important enough for.
    mutating func file(_ points: [TrailCellFile.Point], routes: [Int32], network: RouteNetwork) {
        let scale = Double(TrailCellFile.standardCoordinateScale)
        let degrees = points.map { (latitude: Double($0.latitude) / scale, longitude: Double($0.longitude) / scale) }
        for level in RouteSquareLevel.shallowestFirst where network >= level.minimumNetwork {
            let simplified = Simplification.douglasPeucker(degrees, toleranceMeters: level.toleranceMeters)
            let units = Double(level.coordinateScale)
            var quantized: [RouteSquareFile.Point] = []
            for point in simplified {
                let unit = RouteSquareFile.Point(
                    latitude: Int32((point.latitude * units).rounded()),
                    longitude: Int32((point.longitude * units).rounded())
                )
                if quantized.last != unit { quantized.append(unit) }
            }
            guard quantized.count > 1 else { continue }
            cut(quantized, at: level, routes: routes, network: network)
        }
    }

    /// Cuts a line into one run a square, a segment going to every square its
    /// box touches — see `RouteSquareGrid`'s header, and `Antimeridian` for a
    /// segment that crosses it.
    private mutating func cut(
        _ points: [RouteSquareFile.Point],
        at level: RouteSquareLevel,
        routes: [Int32],
        network: RouteNetwork
    ) {
        let units = Double(level.coordinateScale)
        var open: [RouteSquare: [RouteSquareFile.Point]] = [:]
        for index in 1..<points.count {
            let start = points[index - 1], end = points[index]
            let touched = Set(Antimeridian.boxes(from: start, to: end, units: units).flatMap { box in
                RouteSquareGrid.squares(at: level, covering: box)
            })
            for (square, run) in open where !touched.contains(square) {
                close(run, in: square, routes: routes, network: network)
                open[square] = nil
            }
            for square in touched {
                if open[square] != nil {
                    open[square]?.append(end)
                } else {
                    open[square] = [start, end]
                }
            }
        }
        for (square, run) in open {
            close(run, in: square, routes: routes, network: network)
        }
    }

    private mutating func close(
        _ run: [RouteSquareFile.Point],
        in square: RouteSquare,
        routes: [Int32],
        network: RouteNetwork
    ) {
        squares[square, default: []].append(Line(network: network, routes: routes, points: run))
    }
}

/// Where OpenStreetMap's longitudes jump from 180° to −180°, and a way that
/// crosses it is written as it is mapped: a node at 179.9° and the next at
/// −179.9°, about 21 km apart where the line crosses Fiji.
///
/// Read as plain numbers that segment runs 359.8° the long way round, and its
/// box is every column of the grid: one such way was filed in 2,610 squares
/// round the world, Greenwich's among them, and the simplifier measured it as
/// a line across the planet. Each step from one point to the next is read the
/// short way instead — the only way a path is walked. The points themselves
/// are filed as they are written, so a square on either side of the line
/// holds the segment as OpenStreetMap has it, as it would any segment that
/// crosses its edge.
enum Antimeridian {
    private static let halfTurnDegrees: Double = 180
    private static let fullTurnDegrees: Double = 360

    /// Each longitude moved by whole turns to stand the short way from the one
    /// before it, so a line that crosses the antimeridian runs on past ±180°
    /// rather than jumping round the world. A line that never crosses it comes
    /// back exactly as it went in.
    ///
    /// - Parameter longitudes: OpenStreetMap's, each within ±180°, so one
    ///   step crosses the antimeridian once at most.
    static func unwrapped(_ longitudes: [Double]) -> [Double] {
        var turns = 0.0
        return longitudes.indices.map { index in
            if index > 0 {
                let step = longitudes[index] - longitudes[index - 1]
                if step > halfTurnDegrees {
                    turns -= 1
                } else if step < -halfTurnDegrees {
                    turns += 1
                }
            }
            return longitudes[index] + turns * fullTurnDegrees
        }
    }

    /// The boxes a segment's squares are found from: its own, or for one that
    /// crosses the antimeridian the short way, its two pieces either side of
    /// it — a box `RouteSquareGrid.squares(at:covering:)` takes only uncrossed.
    static func boxes(
        from start: RouteSquareFile.Point,
        to end: RouteSquareFile.Point,
        units: Double
    ) -> [RouteSquareBounds] {
        let south = Double(min(start.latitude, end.latitude)) / units
        let north = Double(max(start.latitude, end.latitude)) / units
        let west = Double(min(start.longitude, end.longitude)) / units
        let east = Double(max(start.longitude, end.longitude)) / units
        guard east - west > halfTurnDegrees else {
            return [RouteSquareBounds(south: south, west: west, north: north, east: east)]
        }
        // The short way runs east from the larger longitude to 180°, and on
        // from −180° to the smaller one.
        return [
            RouteSquareBounds(south: south, west: east, north: north, east: halfTurnDegrees),
            RouteSquareBounds(south: south, west: -halfTurnDegrees, north: north, east: west)
        ]
    }
}

/// Douglas–Peucker over a local flat projection, which at the few kilometres
/// a way spans is the ground to well under the tolerance. Longitudes are
/// projected unwrapped (`Antimeridian`), so a way across the date line is
/// measured as the ground it covers, and its points come back as written.
enum Simplification {
    private static let metersPerDegreeLatitude = 110_540.0
    private static let metersPerDegreeLongitude = 111_320.0

    static func douglasPeucker(
        _ points: [(latitude: Double, longitude: Double)],
        toleranceMeters tolerance: Double
    ) -> [(latitude: Double, longitude: Double)] {
        guard tolerance > 0, points.count > 2 else { return points }
        let kx = metersPerDegreeLongitude * cos(points[0].latitude * .pi / 180)
        let ky = metersPerDegreeLatitude
        let longitudes = Antimeridian.unwrapped(points.map(\.longitude))
        let xy = zip(points, longitudes).map { point, longitude in (x: longitude * kx, y: point.latitude * ky) }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            let dx = xy[last].x - xy[first].x, dy = xy[last].y - xy[first].y
            let length2 = dx * dx + dy * dy
            var worst = -1.0, worstIndex = first
            for index in (first + 1)..<last {
                let px = xy[index].x - xy[first].x, py = xy[index].y - xy[first].y
                let along = length2 > 0 ? max(0, min(1, (px * dx + py * dy) / length2)) : 0
                let ex = along * dx - px, ey = along * dy - py
                let distance2 = ex * ex + ey * ey
                if distance2 > worst {
                    worst = distance2
                    worstIndex = index
                }
            }
            if worst > tolerance * tolerance {
                keep[worstIndex] = true
                stack.append((first, worstIndex))
                stack.append((worstIndex, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
}

// MARK: - Writing

private extension RouteSquareBuild {
    static func write(
        _ filing: RouteFiling,
        catalogue: RouteCatalogue,
        to directory: URL,
        summary: inout Summary
    ) throws -> [BuildManifest.Cell] {
        var cells: [BuildManifest.Cell] = []
        for (square, lines) in filing.squares {
            let file = squareFile(square, lines: lines, catalogue: catalogue)
            let name = RouteSquareGrid.recordName(for: square)
            let bytes = file.encoded()
            guard bytes.count <= TrailCellBuild.maximumCellBytes else {
                throw BuildError.cellTooLarge(name: name, bytes: bytes.count)
            }
            try bytes.write(to: BuildManifest.cellFile(named: name, in: directory), options: .atomic)
            let digest = SHA256.hash(data: file.encodedBody()).map { String(format: "%02x", $0) }.joined()
            cells.append(BuildManifest.Cell(name: name, digest: digest, bytes: bytes.count, routes: file.routes.count))
            summary.squares[square.level, default: 0] += 1
            summary.bytes[square.level, default: 0] += bytes.count
            if bytes.count > summary.largest[square.level]?.bytes ?? 0 {
                summary.largest[square.level] = (name: name, bytes: bytes.count)
            }
        }
        return cells.sorted { $0.name < $1.name }
    }

    /// One square's file: its lines in the order they were filed, and a route
    /// table of only the routes they name, in relation-id order.
    static func squareFile(_ square: RouteSquare, lines: [RouteFiling.Line], catalogue: RouteCatalogue) -> RouteSquareFile {
        let used = Array(Set(lines.flatMap(\.routes))).sorted()
        var local: [Int32: Int] = [:]
        for (index, route) in used.enumerated() {
            local[route] = index
        }
        return RouteSquareFile(
            routes: used.map { RouteSquareFile.Route(id: catalogue.ids[Int($0)], tags: catalogue.tags[Int($0)]) },
            lines: lines.map { line in
                RouteSquareFile.Line(
                    network: line.network,
                    routes: line.routes.compactMap { local[$0] },
                    points: line.points
                )
            },
            coordinateScale: square.level.coordinateScale
        )
    }
}
