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
/// them each way belongs to.
private struct RouteCatalogue {
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
            guard relation.tags["route"] == "hiking" else { return }
            relations.append(relation)
        }
        for relation in relations.sorted(by: { $0.id < $1.id }) {
            let index = Int32(ids.count)
            ids.append(relation.id)
            tags.append(relation.tags.filter { RouteSquareFile.keptTags.contains($0.key) })
            networks.append(RouteNetwork(tag: relation.tags["network"]))
            for member in relation.members where member.kind == UInt8(ascii: "w") {
                wayRoutes[member.ref, default: []].append(index)
            }
        }
        summary.routes = ids.count
    }

    /// The routes a way belongs to, each once and in order, or `nil` for a
    /// way no hiking route names.
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
    /// box touches — see `RouteSquareGrid`'s header.
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
            let box = RouteSquareBounds(
                south: Double(min(start.latitude, end.latitude)) / units,
                west: Double(min(start.longitude, end.longitude)) / units,
                north: Double(max(start.latitude, end.latitude)) / units,
                east: Double(max(start.longitude, end.longitude)) / units
            )
            let touched = Set(RouteSquareGrid.squares(at: level, covering: box))
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

/// Douglas–Peucker over a local flat projection, which at the few kilometres
/// a way spans is the ground to well under the tolerance.
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
        let xy = points.map { (x: $0.longitude * kx, y: $0.latitude * ky) }
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
