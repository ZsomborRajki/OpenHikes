//
//  Build.swift
//  trail-cells
//
//  Turning the hiking relations of an OpenStreetMap extract into one file a
//  square.
//
//  What is decided here is what is *filed*, and nothing about what a hiker is
//  shown — see `TrailCellFile.swift`'s header for why the line-assembly rules
//  stay in the app. A relation is filed when it is one the app's own Overpass
//  search would have been handed:
//
//  - tagged `route=hiking`, with a `name`;
//  - fewer than `TrailCellGrid.maximumMemberCount` members;
//  - every member way present, with a position for every node — a relation
//    that runs out of a regional extract is left out rather than filed short;
//  - no wider, corner to corner, than `TrailCellGrid.maximumRouteSpanMeters`.
//
//  The first two are the Overpass query's own filters and the last is the
//  day-hike rule, measured on the box of the points that are stored.
//
//  **The same extract always gives the same squares.** Relations are written
//  in id order and nothing in a square depends on the clock, so a square's
//  digest changes exactly when OpenStreetMap's routes in it did, and an upload
//  sends only those.
//

import CryptoKit
import Foundation

struct BuildOptions {
    var relationsPath: String
    var waysPath: String
    var outputDirectory: URL
    /// Whether the extract was the whole planet, so every square holds all
    /// of its routes and a square with no file is a square with no routes.
    /// See `BuildManifest.complete`.
    var coversTheWorld: Bool
    /// When the extract's data was current, as osmium read it off the file.
    var osmTimestamp: Date?
}

/// What a build left on disk, for `upload` to read back.
struct BuildManifest: Codable {
    struct Cell: Codable {
        /// The record name — `TrailCellGrid.recordName(for:)`.
        var name: String
        /// SHA-256 of the square's body, unpacked. See
        /// `TrailCellFile.encodedBody()` for why it is not the file's.
        var digest: String
        var bytes: Int
        var routes: Int
    }

    static let fileName = "manifest.json"
    static let cellDirectoryName = "cells"
    static let cellFileExtension = "cell"

    /// Which set of squares this is: `nil` for the day hikes' — the only set
    /// there was when the first manifests were written — or
    /// `RouteSquareBuild.manifestKind` for the hiking-routes layer's. See
    /// `Upload.Dataset`.
    var kind: String?
    var generation: Int
    /// Whether these squares are every square there is. Only then does the
    /// app read them, and take a missing one to mean *no routes here*. A
    /// regional build says no: it leaves out the routes that run out of its
    /// extract, so the app goes on asking Overpass.
    var complete: Bool
    var builtAt: Date
    var osmTimestamp: Date?
    var routeCount: Int
    var cells: [Cell]

    static func read(from directory: URL) throws -> BuildManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            BuildManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent(fileName))
        )
    }

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    static func cellFile(named name: String, in directory: URL) -> URL {
        directory
            .appendingPathComponent(cellDirectoryName, isDirectory: true)
            .appendingPathComponent("\(name).\(cellFileExtension)")
    }
}

enum BuildError: Error, CustomStringConvertible {
    case outputIsNotABuild(String)
    case cellTooLarge(name: String, bytes: Int)
    case waysCarryNoPositions(String)

    var description: String {
        switch self {
        case .waysCarryNoPositions(let path):
            "no way in \(path) carries its nodes' positions. It has to be written from the output of "
                + "`osmium add-locations-to-ways`, with `-f opl,locations_on_ways=true`."
        case .outputIsNotABuild(let path):
            "\(path) holds files and no \(BuildManifest.fileName), so it is not an earlier build to replace. "
                + "Name an empty directory, or a previous build's."
        case .cellTooLarge(let name, let bytes):
            "\(name) is \(bytes) bytes, past what one asset upload takes "
                + "(\(TrailCellBuild.maximumCellBytes)). The grid needs smaller squares before this can ship."
        }
    }
}

enum TrailCellBuild {
    /// The most one square's file may weigh: what CloudKit Web Services
    /// accepts as one asset upload.
    static let maximumCellBytes = 15 * 1024 * 1024

    /// Why a relation in the extract was not filed, counted for the summary.
    enum Dropped: String, CaseIterable {
        case notAHikingRoute = "not tagged route=hiking"
        case unnamed = "without a name"
        case tooManyMembers = "with too many members"
        case noWays = "with no member ways"
        case incomplete = "running out of the extract"
        case tooWide = "wider than a day hike"
    }

    struct Summary {
        var relationsRead = 0
        var dropped: [Dropped: Int] = [:]
        var routes = 0
        var points = 0
        var cells = 0
        var bytes = 0
        var largest: (name: String, bytes: Int)?
    }

    static func run(_ options: BuildOptions) throws -> Summary {
        var summary = Summary()
        let candidates = try relations(at: options.relationsPath, summary: &summary)
        let ways = try ways(at: options.waysPath, namedBy: candidates)
        let filed = file(candidates, ways: ways, summary: &summary)
        try prepare(options.outputDirectory)
        let cells = try write(filed, to: options.outputDirectory, summary: &summary)
        try BuildManifest(
            kind: nil,
            generation: TrailCellGrid.generation,
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

// MARK: - Reading the extract

private extension TrailCellBuild {
    /// The relations the Overpass query would have matched.
    static func relations(at path: String, summary: inout Summary) throws -> [OPLRelation] {
        var kept: [OPLRelation] = []
        try OPLFile(path: path).forEachLine { line in
            guard let relation = try OPL.relation(line) else { return }
            summary.relationsRead += 1
            // osmium hands over a hiking relation's member relations too,
            // whatever they are, so the tag is asked about again here.
            guard relation.tags["route"] == "hiking" else {
                summary.dropped[.notAHikingRoute, default: 0] += 1
                return
            }
            guard relation.tags["name"] != nil else {
                summary.dropped[.unnamed, default: 0] += 1
                return
            }
            guard relation.members.count < TrailCellGrid.maximumMemberCount else {
                summary.dropped[.tooManyMembers, default: 0] += 1
                return
            }
            kept.append(relation)
        }
        return kept
    }

    /// The points of every way one of `relations` names, where the extract
    /// has a position for each of the way's nodes. A way it holds short of
    /// that is left out, exactly as one it does not hold at all is.
    static func ways(
        at path: String,
        namedBy relations: [OPLRelation]
    ) throws -> [Int64: [TrailCellFile.Point]] {
        var wanted: Set<Int64> = []
        for relation in relations {
            for member in relation.members where member.kind == UInt8(ascii: "w") {
                wanted.insert(member.ref)
            }
        }
        var ways: [Int64: [TrailCellFile.Point]] = [:]
        ways.reserveCapacity(wanted.count)
        var withoutPositions = 0
        try OPLFile(path: path).forEachLine { line in
            guard let id = OPL.wayID(line), wanted.contains(id) else { return }
            guard let points = try OPL.way(line, scale: TrailCellFile.standardCoordinateScale)?.points else {
                withoutPositions += 1
                return
            }
            ways[id] = points
        }
        // Not one way with a position, and ways that lacked them: this is the
        // file osmium writes when it is not asked for positions, and filing
        // it would be a build with no routes that says nothing is wrong.
        if ways.isEmpty, withoutPositions > 0 {
            throw BuildError.waysCarryNoPositions(path)
        }
        return ways
    }
}

// MARK: - Filing

private extension TrailCellBuild {
    /// Each relation that is filed, under the square it is filed in.
    static func file(
        _ relations: [OPLRelation],
        ways: [Int64: [TrailCellFile.Point]],
        summary: inout Summary
    ) -> [TrailCell: [TrailCellFile.Relation]] {
        var filed: [TrailCell: [TrailCellFile.Relation]] = [:]
        for relation in relations {
            let members = relation.members.filter { $0.kind == UInt8(ascii: "w") }
            guard !members.isEmpty else {
                summary.dropped[.noWays, default: 0] += 1
                continue
            }
            var routeWays: [TrailCellFile.Way] = []
            for member in members {
                guard let points = ways[member.ref] else { break }
                routeWays.append(TrailCellFile.Way(role: member.role, points: points))
            }
            guard routeWays.count == members.count, let bounds = bounds(of: routeWays) else {
                summary.dropped[.incomplete, default: 0] += 1
                continue
            }
            guard bounds.spanMeters <= TrailCellGrid.maximumRouteSpanMeters else {
                summary.dropped[.tooWide, default: 0] += 1
                continue
            }
            let center = bounds.center
            let cell = TrailCellGrid.cell(containingLatitude: center.latitude, longitude: center.longitude)
            filed[cell, default: []].append(
                TrailCellFile.Relation(id: relation.id, tags: relation.tags, ways: routeWays)
            )
            summary.routes += 1
            summary.points += routeWays.reduce(0) { $0 + $1.points.count }
        }
        return filed
    }

    /// The extent of every point of `ways`, in degrees, or `nil` when there
    /// is no point at all.
    ///
    /// The plain minimum and maximum Overpass computes, date line and all:
    /// `TrailCellBounds` is what reads a box that spans it the short way.
    static func bounds(of ways: [TrailCellFile.Way]) -> TrailCellBounds? {
        var south = Int32.max, west = Int32.max, north = Int32.min, east = Int32.min
        for way in ways {
            for point in way.points {
                south = min(south, point.latitude)
                north = max(north, point.latitude)
                west = min(west, point.longitude)
                east = max(east, point.longitude)
            }
        }
        guard south <= north else { return nil }
        let scale = Double(TrailCellFile.standardCoordinateScale)
        return TrailCellBounds(
            south: Double(south) / scale,
            west: Double(west) / scale,
            north: Double(north) / scale,
            east: Double(east) / scale
        )
    }
}

// MARK: - Writing

extension TrailCellBuild {
    /// Empties a previous build out of `directory`, and refuses a directory
    /// that holds anything else. Both builds' first step.
    static func prepare(_ directory: URL) throws {
        let manager = FileManager.default
        let cells = directory.appendingPathComponent(BuildManifest.cellDirectoryName, isDirectory: true)
        // Hidden files are the Finder's, not a reason to refuse.
        let existing = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        if !existing.isEmpty {
            guard existing.contains(BuildManifest.fileName) else {
                throw BuildError.outputIsNotABuild(directory.path)
            }
            try? manager.removeItem(at: cells)
            try? manager.removeItem(at: directory.appendingPathComponent(BuildManifest.fileName))
        }
        try manager.createDirectory(at: cells, withIntermediateDirectories: true)
    }
}

private extension TrailCellBuild {
    static func write(
        _ filed: [TrailCell: [TrailCellFile.Relation]],
        to directory: URL,
        summary: inout Summary
    ) throws -> [BuildManifest.Cell] {
        var cells: [BuildManifest.Cell] = []
        for (cell, relations) in filed {
            let name = TrailCellGrid.recordName(for: cell)
            let file = TrailCellFile(relations: relations.sorted { $0.id < $1.id })
            let bytes = file.encoded()
            guard bytes.count <= maximumCellBytes else {
                throw BuildError.cellTooLarge(name: name, bytes: bytes.count)
            }
            try bytes.write(to: BuildManifest.cellFile(named: name, in: directory), options: .atomic)
            let digest = SHA256.hash(data: file.encodedBody()).map { String(format: "%02x", $0) }.joined()
            cells.append(BuildManifest.Cell(name: name, digest: digest, bytes: bytes.count, routes: relations.count))
            summary.bytes += bytes.count
            if bytes.count > summary.largest?.bytes ?? 0 {
                summary.largest = (name: name, bytes: bytes.count)
            }
        }
        summary.cells = cells.count
        return cells.sorted { $0.name < $1.name }
    }
}
