//
//  GraphBuild.swift
//  trail-cells
//
//  Turning the trails of an OpenStreetMap extract into the squares of the
//  trail graph: every way whose `highway` is one of `TrailGraphHighway.trails`
//  and that may be walked, whole, with its nodes' ids and positions and the
//  name of a hiking route it is part of, filed under every square of
//  `TrailGraphSquareGrid` its box touches.
//
//  A planet's trails are a billion nodes, more than this tool should hold, so
//  the ways are read once and spooled: each way's bytes are appended to its
//  squares' spool files as it is read, a few gigabytes at a time, and each
//  square is then written from its spool alone.
//
//  **The same extract always gives the same squares.** A square's ways are
//  written by id and nothing depends on the clock, so a square's digest
//  changes exactly when OpenStreetMap's trails in it did.
//

import CryptoKit
import Foundation

enum TrailGraphSquareBuild {
    /// What `build-graph` writes in a manifest's `kind`, so `upload` knows
    /// which manifest record it is replacing.
    static let manifestKind = "graph"

    /// The expressions `osmium tags-filter` is handed, one a line: the trails,
    /// and the hiking relations whose names they carry.
    static var osmiumFilters: [String] {
        ["r/route=hiking", "w/highway=\(TrailGraphHighway.trails.sorted().joined(separator: ","))"]
    }

    struct Summary {
        var trails = 0
        var nodes = 0
        var notWalkable = 0
        var withoutPositions = 0
        var squares = 0
        var bytes = 0
        var largest: (name: String, bytes: Int, ways: Int)?
    }

    static func run(_ options: BuildOptions) throws -> Summary {
        var summary = Summary()
        let names = try hikingRouteNames(at: options.relationsPath)
        let spoolDirectory = options.outputDirectory.appendingPathExtension("spool")
        let spool = try Spool(directory: spoolDirectory)
        defer { try? FileManager.default.removeItem(at: spoolDirectory) }

        var withPositions = 0
        try OPLFile(path: options.waysPath).forEachLine { line in
            guard let way = try OPL.way(
                line,
                scale: TrailGraphSquareFile.standardCoordinateScale,
                readsTags: true,
                readsNodeIDs: true
            ),
                let highway = way.tags["highway"], TrailGraphHighway.trails.contains(highway)
            else { return }
            guard TrailGraphSquareFile.permitsWalking(way.tags) else {
                summary.notWalkable += 1
                return
            }
            guard let points = way.points, points.count == way.nodeIDs.count else {
                summary.withoutPositions += 1
                return
            }
            withPositions += 1
            guard points.count > 1 else { return }
            var tags: [TrailGraphSquareFile.Tag: String] = [:]
            for tag in TrailGraphSquareFile.Tag.allCases {
                tags[tag] = tag.key.flatMap { way.tags[$0] }
            }
            tags[.hikingRoute] = names[way.id]
            let trail = TrailGraphSquareFile.Way(
                id: way.id,
                highway: highway,
                tags: tags,
                nodes: zip(way.nodeIDs, points).map { id, point in
                    TrailGraphSquareFile.Node(id: id, latitude: point.latitude, longitude: point.longitude)
                }
            )
            let record = SpoolRecord.encoded(trail)
            for square in squares(touching: trail.nodes) {
                try spool.append(record, to: square)
            }
            summary.trails += 1
            summary.nodes += trail.nodes.count
        }
        // Not one way with a position, and ways that lacked them: the file
        // osmium writes when it is not asked for positions — see
        // `TrailCellBuild.ways(at:namedBy:)`.
        if withPositions == 0, summary.withoutPositions > 0 {
            throw BuildError.waysCarryNoPositions(options.waysPath)
        }
        try spool.flush()

        try TrailCellBuild.prepare(options.outputDirectory)
        let squares = try write(spool, to: options.outputDirectory, summary: &summary)
        try BuildManifest(
            kind: manifestKind,
            generation: TrailGraphSquareGrid.generation,
            complete: options.coversTheWorld,
            builtAt: Date(),
            osmTimestamp: options.osmTimestamp,
            routeCount: summary.trails,
            cells: squares
        )
        .write(to: options.outputDirectory)
        return summary
    }
}

// MARK: - Reading the extract

private extension TrailGraphSquareBuild {
    /// The hiking route name of every way a hiking relation names. osmium
    /// hands over a matching relation's member relations too, whatever they
    /// are, so the tags are asked about again here.
    static func hikingRouteNames(at path: String) throws -> [Int64: String] {
        var names: [Int64: String] = [:]
        try OPLFile(path: path).forEachLine { line in
            guard let relation = try OPL.relation(line),
                  let name = TrailGraphSquareFile.hikingRouteName(relation.tags)
            else { return }
            for member in relation.members where member.kind == UInt8(ascii: "w") {
                names[member.ref] = TrailGraphSquareFile.hikingRouteName(of: [names[member.ref], name].compactMap(\.self))
            }
        }
        return names
    }

    /// The squares a way is filed under: every square its box touches, or,
    /// for a box more than half the world wide, which is a way across the
    /// antimeridian read the long way round, the squares of its own points.
    static func squares(touching nodes: [TrailGraphSquareFile.Node]) -> [TrailGraphSquare] {
        let scale = Double(TrailGraphSquareFile.standardCoordinateScale)
        let latitudes = nodes.map { Double($0.latitude) / scale }
        let longitudes = nodes.map { Double($0.longitude) / scale }
        guard let south = latitudes.min(), let north = latitudes.max(),
              let west = longitudes.min(), let east = longitudes.max()
        else { return [] }
        let halfTurn: Double = 180
        guard east - west > halfTurn else {
            return TrailGraphSquareGrid.squares(touchingSouth: south, west: west, north: north, east: east)
        }
        var seen: Set<TrailGraphSquare> = []
        return zip(latitudes, longitudes).compactMap { latitude, longitude in
            let square = TrailGraphSquare(
                x: TrailGraphSquareGrid.tileX(longitude, zoom: TrailGraphSquareGrid.squareZoom),
                y: TrailGraphSquareGrid.tileY(latitude, zoom: TrailGraphSquareGrid.squareZoom)
            )
            return seen.insert(square).inserted ? square : nil
        }
    }
}

// MARK: - Spooling

/// Each square's ways as they are read, a few gigabytes in memory at a time
/// and the rest appended to a file a square.
private final class Spool {
    private static let flushBytes = 2 << 30

    private let directory: URL
    private var buffers: [TrailGraphSquare: [UInt8]] = [:]
    private var buffered = 0
    private(set) var squares: Set<TrailGraphSquare> = []

    init(directory: URL) throws {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    func append(_ record: [UInt8], to square: TrailGraphSquare) throws {
        buffers[square, default: []].append(contentsOf: record)
        squares.insert(square)
        buffered += record.count
        if buffered >= Self.flushBytes { try flush() }
    }

    /// Appends every buffer to its square's file and empties them.
    func flush() throws {
        for (square, bytes) in buffers {
            let url = file(of: square)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            try handle.close()
        }
        buffers = [:]
        buffered = 0
    }

    /// The ways spooled for `square`, once everything is flushed.
    func ways(of square: TrailGraphSquare) throws -> [TrailGraphSquareFile.Way] {
        var reader = PackedReader(bytes: Array(try Data(contentsOf: file(of: square))))
        var ways: [TrailGraphSquareFile.Way] = []
        while !reader.isAtEnd {
            ways.append(try SpoolRecord.decoded(&reader))
        }
        return ways
    }

    private func file(of square: TrailGraphSquare) -> URL {
        directory.appendingPathComponent("\(square.x)_\(square.y).spool")
    }
}

/// One way as the spool holds it: every number whole, so a record can be
/// copied into any number of squares as it is.
private enum SpoolRecord {
    static func encoded(_ way: TrailGraphSquareFile.Way) -> [UInt8] {
        var writer = PackedWriter()
        writer.write(step: way.id)
        write(way.highway, to: &writer)
        writer.write(UInt64(way.tags.count))
        for (tag, value) in way.tags.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            writer.write(UInt64(tag.rawValue))
            write(value, to: &writer)
        }
        writer.write(UInt64(way.nodes.count))
        for node in way.nodes {
            writer.write(step: node.id)
            writer.write(step: Int64(node.latitude))
            writer.write(step: Int64(node.longitude))
        }
        return writer.bytes
    }

    static func decoded(_ reader: inout PackedReader) throws -> TrailGraphSquareFile.Way {
        let id = try reader.readStep()
        let highway = try reader.readString()
        var tags: [TrailGraphSquareFile.Tag: String] = [:]
        for _ in try 0..<reader.readCount() {
            guard let tag = TrailGraphSquareFile.Tag(rawValue: Int(try reader.readVarint())) else {
                throw PackedFileError.corrupt
            }
            tags[tag] = try reader.readString()
        }
        let nodes = try (0..<reader.readCount()).map { _ in
            TrailGraphSquareFile.Node(
                id: try reader.readStep(),
                latitude: Int32(truncatingIfNeeded: try reader.readStep()),
                longitude: Int32(truncatingIfNeeded: try reader.readStep())
            )
        }
        return TrailGraphSquareFile.Way(id: id, highway: highway, tags: tags, nodes: nodes)
    }

    private static func write(_ text: String, to writer: inout PackedWriter) {
        let bytes = Array(text.utf8)
        writer.write(UInt64(bytes.count))
        writer.bytes.append(contentsOf: bytes)
    }
}

// MARK: - Writing

private extension TrailGraphSquareBuild {
    static func write(_ spool: Spool, to directory: URL, summary: inout Summary) throws -> [BuildManifest.Cell] {
        var cells: [BuildManifest.Cell] = []
        // Every square is written before one too large is refused, so a
        // build that has to move to a finer grid says how much finer at once.
        var tooLarge: [(name: String, bytes: Int)] = []
        for square in spool.squares {
            let name = TrailGraphSquareGrid.recordName(for: square)
            let ways = try spool.ways(of: square)
            let file = TrailGraphSquareFile(ways: ways)
            let bytes = file.encoded()
            guard bytes.count <= TrailCellBuild.maximumCellBytes else {
                tooLarge.append((name: name, bytes: bytes.count))
                continue
            }
            try bytes.write(to: BuildManifest.cellFile(named: name, in: directory), options: .atomic)
            let digest = SHA256.hash(data: file.encodedBody()).map { String(format: "%02x", $0) }.joined()
            cells.append(BuildManifest.Cell(name: name, digest: digest, bytes: bytes.count, routes: ways.count))
            summary.bytes += bytes.count
            if bytes.count > summary.largest?.bytes ?? 0 {
                summary.largest = (name: name, bytes: bytes.count, ways: ways.count)
            }
        }
        summary.squares = cells.count
        if let largest = tooLarge.max(by: { $0.bytes < $1.bytes }) {
            print("\(tooLarge.count) squares are past what one asset upload takes.")
            throw BuildError.cellTooLarge(name: largest.name, bytes: largest.bytes)
        }
        return cells.sorted { $0.name < $1.name }
    }
}
