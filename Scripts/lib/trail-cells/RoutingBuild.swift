//
//  RoutingBuild.swift
//  trail-cells
//
//  The trail maker's graph: every way the trail graph's build files, and the
//  roads that join them (`TrailGraphHighway.all`), filed under every tile of
//  `RoutingGraphArchive.zoom` its box touches, as one PMTiles archive the tile
//  server serves a tile at a time. See `RoutingGraphArchive.swift` for why.
//
//  A planet's roads and trails are 2.5 billion nodes, so the ways come in on
//  standard input rather than from a file: `Scripts/trail-cells.sh
//  build-routing` has osmium write them into a pipe a band of longitude at a
//  time, because no index of every node's position fits in memory at once. A
//  way across two bands' edge comes in once from each, and is filed once.
//
//  They are spooled by the trail graph's own squares, four levels up from a
//  tile, a few gigabytes in memory at a time and the rest in a file a square
//  (`Spool`), and each square is then written as its sixteen tiles. A square's
//  tiles are consecutive along the archive's Hilbert curve, so writing the
//  squares in the order of their first tile writes every tile in order, and
//  the archive is clustered. The squares are read back and encoded many at a
//  time; only the writing is in order.
//
//  The archive's root directory has to be in its first 16 KiB, and its size
//  is known only once every tile is written. So the first 16 KiB are held
//  open, the tiles written after them, the metadata and the leaf directories
//  after the tiles, and the header and the root written last into the space
//  held for them. The tile server reads every section by its offset.
//
//  **The same extract always gives the same archive**, but for the time it
//  was built, which is in the metadata: a tile's ways are written by id.
//

import Foundation

struct RoutingBuildOptions {
    var relationsPath: String
    /// `-` for standard input.
    var waysPath: String
    var outputDirectory: URL
    /// The archive's name on the server, which is its file's name without
    /// `.pmtiles` — see `RoutingGraphArchive.isArchiveName(_:)`.
    var name: String
    /// Whether the extract was the whole planet, so a tile the archive does
    /// not hold is ground with no ways on it. See `RoutingGraphBuild.Record`.
    var coversTheWorld: Bool
    var osmTimestamp: Date?
}

enum RoutingGraphBuild {
    /// The expressions `osmium tags-filter` is handed, one a line: every way
    /// the graph keeps, and the hiking relations whose names they carry.
    static var osmiumFilters: [String] {
        ["r/route=hiking", "w/highway=\(TrailGraphHighway.all.joined(separator: ","))"]
    }

    /// What a build says of itself, beside its archive: what
    /// `Scripts/trail-cells.sh upload-routing` reads before it sends one.
    static let recordFileName = "routing-build.json"

    /// At most this many squares are read back and encoded at once, and no
    /// more than this many bytes of their spool: the square over Paris is
    /// tens of megabytes spooled and a few hundred decoded.
    static let batchSquares = 64
    static let batchSpoolBytes = 256 << 20

    struct Record: Codable {
        var name: String
        var generation: Int
        var zoom: Int
        /// Whether the archive is every tile there is, so the app may read a
        /// tile it does not hold as ground with no ways on it. A regional
        /// build says no, and `upload-routing` refuses it.
        var complete: Bool
        var builtAt: Date
        var osmTimestamp: Date?
        var ways: Int
        var nodes: Int
        var tiles: Int
        var bytes: UInt64
    }

    struct Sizes {
        var count = 0
        var bytes = 0
        var median = 0
        var percentile99 = 0
        var largest: (name: String, bytes: Int, ways: Int)?
    }

    struct Summary {
        var ways = 0
        var nodes = 0
        var notWalkable = 0
        var withoutPositions = 0
        var tiles = Sizes()
        /// What the same ways would weigh filed under the trail graph's own
        /// squares, four levels up, measured on the way.
        var squares = Sizes()
        var archiveBytes: UInt64 = 0
        var isClustered = true
        var archive: URL?
    }

    static func run(_ options: RoutingBuildOptions) async throws -> Summary {
        guard RoutingGraphArchive.isArchiveName(options.name) else {
            throw RoutingBuildError.notAnArchiveName(options.name)
        }
        var summary = Summary()
        let names = try TrailGraphSquareBuild.hikingRouteNames(at: options.relationsPath)
        let spoolDirectory = options.outputDirectory.appendingPathExtension("spool")
        let spool = try Spool(directory: spoolDirectory)
        defer { try? FileManager.default.removeItem(at: spoolDirectory) }

        let kept = Set(TrailGraphHighway.all)
        var withPositions = 0
        try OPLFile(path: options.waysPath).forEachLine { line in
            switch try TrailGraphSquareBuild.read(line, keeping: kept, names: names) {
            case .other:
                return
            case .notWalkable:
                summary.notWalkable += 1
            case .withoutPositions:
                summary.withoutPositions += 1
            case .tooShort:
                withPositions += 1
            case .way(let way):
                withPositions += 1
                let record = SpoolRecord.encoded(way)
                for square in TrailGraphSquareGrid.squares(
                    touching: way.nodes,
                    coordinateScale: TrailGraphSquareFile.standardCoordinateScale
                ) {
                    try spool.append(record, to: square)
                }
            }
        }
        if withPositions == 0, summary.withoutPositions > 0 {
            throw BuildError.waysCarryNoPositions(options.waysPath)
        }
        try spool.flush()

        try prepare(options.outputDirectory)
        let archive = options.outputDirectory.appendingPathComponent("\(options.name).pmtiles")
        let writer = try RoutingArchiveWriter(url: archive)
        var tileSizes: [(bytes: Int, ways: Int, tile: TrailGraphSquare)] = []
        var squareSizes: [(bytes: Int, ways: Int, square: TrailGraphSquare)] = []
        let reader = spool.reader
        let squares = spool.squares.sorted { firstTileID(of: $0) < firstTileID(of: $1) }
        var batch: [TrailGraphSquare] = []
        var batchBytes = 0
        func writeBatch() async throws {
            for square in try await tiles(of: batch, from: reader) {
                summary.ways += square.ways
                summary.nodes += square.nodes
                squareSizes.append((square.bytes, square.wayCount, square.square))
                for tile in square.tiles {
                    try writer.append(tile.bytes, tileID: tile.id)
                    tileSizes.append((tile.bytes.count, tile.ways, tile.tile))
                }
            }
            batch = []
            batchBytes = 0
        }
        for square in squares {
            batch.append(square)
            batchBytes += reader.bytes(of: square)
            if batch.count >= batchSquares || batchBytes >= batchSpoolBytes { try await writeBatch() }
        }
        if !batch.isEmpty { try await writeBatch() }

        summary.archiveBytes = try writer.finish(metadata: metadata(options))
        summary.isClustered = writer.isClustered
        summary.archive = archive
        summary.tiles = sizes(tileSizes.map { ($0.bytes, $0.ways, "z\(RoutingGraphArchive.zoom)/\($0.tile.x)/\($0.tile.y)") })
        summary.squares = sizes(squareSizes.map { ($0.bytes, $0.ways, "z\(TrailGraphSquareGrid.squareZoom)/\($0.square.x)/\($0.square.y)") })

        let record = Record(
            name: options.name,
            generation: RoutingGraphArchive.generation,
            zoom: RoutingGraphArchive.zoom,
            complete: options.coversTheWorld,
            builtAt: Date(),
            osmTimestamp: options.osmTimestamp,
            ways: summary.ways,
            nodes: summary.nodes,
            tiles: summary.tiles.count,
            bytes: summary.archiveBytes
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record)
            .write(to: options.outputDirectory.appendingPathComponent(recordFileName), options: .atomic)
        return summary
    }

    /// The id of the first of a square's tiles along the archive's curve.
    static func firstTileID(of square: TrailGraphSquare) -> UInt64 {
        let shift = RoutingGraphArchive.zoom - TrailGraphSquareGrid.squareZoom
        let side = 1 << shift
        var first = UInt64.max
        for row in 0..<side {
            for column in 0..<side {
                first = min(first, PMTilesTileID.id(
                    z: RoutingGraphArchive.zoom,
                    x: (square.x << shift) + column,
                    y: (square.y << shift) + row
                ))
            }
        }
        return first
    }
}

// MARK: - A square's tiles

private extension RoutingGraphBuild {
    struct Tile: Sendable {
        var id: UInt64
        var tile: TrailGraphSquare
        var bytes: Data
        var ways: Int
    }

    struct SquareTiles: Sendable {
        var square: TrailGraphSquare
        var tiles: [Tile]
        /// The square's own file, which the trail graph's squares would be.
        var bytes: Int
        var wayCount: Int
        /// The ways that start in this square and their nodes, so a way is
        /// counted once however many squares it is filed under.
        var ways: Int
        var nodes: Int
    }

    /// The tiles of every square in `batch`, many at a time, in the batch's
    /// order.
    static func tiles(of batch: [TrailGraphSquare], from reader: SpoolReader) async throws -> [SquareTiles] {
        try await withThrowingTaskGroup(of: (Int, SquareTiles).self) { group in
            for (index, square) in batch.enumerated() {
                group.addTask { (index, try tiles(of: square, from: reader)) }
            }
            var found = [SquareTiles?](repeating: nil, count: batch.count)
            for try await (index, tiles) in group {
                found[index] = tiles
            }
            return found.compactMap(\.self)
        }
    }

    static func tiles(of square: TrailGraphSquare, from reader: SpoolReader) throws -> SquareTiles {
        let scale = TrailGraphSquareFile.standardCoordinateScale
        // By id, and once: a way across two bands' edge was read from each.
        var ways: [TrailGraphSquareFile.Way] = []
        for way in try reader.ways(of: square).sorted(by: { $0.id < $1.id }) where ways.last?.id != way.id {
            ways.append(way)
        }
        let shift = RoutingGraphArchive.zoom - TrailGraphSquareGrid.squareZoom
        var children: [TrailGraphSquare: [TrailGraphSquareFile.Way]] = [:]
        var starting = 0
        var nodes = 0
        for way in ways {
            if let first = way.nodes.first, home(of: first, scale: scale) == square {
                starting += 1
                nodes += way.nodes.count
            }
            for tile in TrailGraphSquareGrid.squares(touching: way.nodes, coordinateScale: scale, zoom: RoutingGraphArchive.zoom)
                where tile.x >> shift == square.x && tile.y >> shift == square.y {
                children[tile, default: []].append(way)
            }
        }
        let tiles = children.map { tile, ways in
            Tile(
                id: PMTilesTileID.id(z: RoutingGraphArchive.zoom, x: tile.x, y: tile.y),
                tile: tile,
                bytes: TrailGraphSquareFile(ways: ways).encoded(),
                ways: ways.count
            )
        }
        return SquareTiles(
            square: square,
            tiles: tiles.sorted { $0.id < $1.id },
            bytes: TrailGraphSquareFile(ways: ways).encoded().count,
            wayCount: ways.count,
            ways: starting,
            nodes: nodes
        )
    }

    /// The square a way's first node is in.
    static func home(of node: TrailGraphSquareFile.Node, scale: Int32) -> TrailGraphSquare {
        let zoom = TrailGraphSquareGrid.squareZoom
        return TrailGraphSquare(
            x: TrailGraphSquareGrid.tileX(Double(node.longitude) / Double(scale), zoom: zoom),
            y: TrailGraphSquareGrid.tileY(Double(node.latitude) / Double(scale), zoom: zoom)
        )
    }
}

// MARK: - The output

private extension RoutingGraphBuild {
    /// An empty directory, or an earlier routing build's, emptied of it.
    static func prepare(_ directory: URL) throws {
        let manager = FileManager.default
        let existing = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        if !existing.isEmpty {
            guard existing.contains(recordFileName) else { throw RoutingBuildError.outputIsNotABuild(directory.path) }
            for name in existing where name == recordFileName || name.hasSuffix(".pmtiles") {
                try manager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The archive's metadata: what it is, under what licence, and from
    /// when, for whoever reads the archive without this tool.
    static func metadata(_ options: RoutingBuildOptions) throws -> Data {
        var metadata: [String: Any] = [
            "name": "OpenHikes routing graph",
            "description": "Trails and the roads that join them, one OpenHikes trail graph file a tile "
                + "(OHGS \(TrailGraphSquareFile.formatVersion))",
            "attribution": "© OpenStreetMap contributors",
            "generation": RoutingGraphArchive.generation,
            "complete": options.coversTheWorld,
            "vector_layers": [Any](),
        ]
        if let timestamp = options.osmTimestamp {
            metadata["osm_timestamp"] = ISO8601DateFormatter().string(from: timestamp)
        }
        return try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    }

    static func sizes(_ files: [(bytes: Int, ways: Int, name: String)]) -> Sizes {
        let ordered = files.map(\.bytes).sorted()
        var sizes = Sizes()
        sizes.count = ordered.count
        sizes.bytes = ordered.reduce(0, +)
        guard !ordered.isEmpty else { return sizes }
        sizes.median = ordered[ordered.count / 2]
        sizes.percentile99 = ordered[min(ordered.count - 1, ordered.count * 99 / 100)]
        if let largest = files.max(by: { $0.bytes < $1.bytes }) {
            sizes.largest = (largest.name, largest.bytes, largest.ways)
        }
        return sizes
    }
}

// MARK: - The archive

/// A PMTiles archive written tile by tile: the first 16 KiB held for the
/// header and the root directory, the tiles after them, then the metadata
/// and the leaf directories, and the header and the root written last.
final class RoutingArchiveWriter {
    static let tileDataOffset = UInt64(PMTilesHeader.rootReadBytes)

    private let handle: FileHandle
    private var entries: [PMTilesEntry] = []
    private var tileDataLength: UInt64 = 0
    /// Whether every tile came after the one before it along the curve,
    /// which is what makes the data's order the directory's.
    private(set) var isClustered = true

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(count: PMTilesHeader.rootReadBytes))
    }

    func append(_ bytes: Data, tileID: UInt64) throws {
        if let last = entries.last, last.tileID >= tileID { isClustered = false }
        entries.append(PMTilesEntry(tileID: tileID, offset: tileDataLength, length: UInt64(bytes.count), runLength: 1))
        try handle.write(contentsOf: bytes)
        tileDataLength += UInt64(bytes.count)
    }

    /// Writes the rest and closes the file. Returns how long it is.
    func finish(metadata: Data) throws -> UInt64 {
        if !isClustered { entries.sort { $0.tileID < $1.tileID } }
        for (earlier, later) in zip(entries, entries.dropFirst()) where earlier.tileID == later.tileID {
            throw RoutingBuildError.tileWrittenTwice(earlier.tileID)
        }
        let (root, leaves) = PMTilesLayout.directories(for: entries)
        var header = PMTilesHeader()
        header.rootDirectoryOffset = UInt64(PMTilesHeader.byteCount)
        header.rootDirectoryLength = UInt64(root.count)
        header.tileDataOffset = Self.tileDataOffset
        header.tileDataLength = tileDataLength
        header.metadataOffset = Self.tileDataOffset + tileDataLength
        header.metadataLength = UInt64(metadata.count)
        header.leafDirectoryOffset = header.metadataOffset + header.metadataLength
        header.leafDirectoryLength = UInt64(leaves.count)
        header.addressedTiles = UInt64(entries.count)
        header.tileEntries = UInt64(entries.count)
        header.tileContents = UInt64(entries.count)
        header.isClustered = isClustered
        header.internalCompression = PMTilesCompression.uncompressed.rawValue
        // Each tile is a trail graph file in its own envelope, packed already.
        header.tileCompression = PMTilesCompression.uncompressed.rawValue
        // Not a type PMTiles names, which the tile server serves as it is.
        header.tileType = 0
        header.minimumZoom = UInt8(RoutingGraphArchive.zoom)
        header.maximumZoom = UInt8(RoutingGraphArchive.zoom)
        header.bounds = [-1_800_000_000, -850_511_287, 1_800_000_000, 850_511_287]
        header.centerZoom = UInt8(RoutingGraphArchive.zoom)
        header.center = [0, 0]
        let prefix = header.bytes + root
        guard prefix.count <= PMTilesHeader.rootReadBytes else { throw RoutingBuildError.rootTooLarge(root.count) }
        try handle.write(contentsOf: metadata)
        try handle.write(contentsOf: Data(leaves))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(prefix))
        try handle.close()
        return header.leafDirectoryOffset + header.leafDirectoryLength
    }
}

/// One tile of an archive `RoutingArchiveWriter` wrote, read back by its
/// directories, as the tile server reads it.
enum RoutingArchiveReader {
    static func tile(at url: URL, x: Int, y: Int) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        func read(_ offset: UInt64, _ length: UInt64) throws -> [UInt8] {
            try handle.seek(toOffset: offset)
            let bytes = try handle.read(upToCount: Int(length)) ?? Data()
            guard bytes.count == Int(length) else { throw PMTilesError.truncated }
            return Array(bytes)
        }
        let start = try read(0, UInt64(PMTilesHeader.byteCount))
        let header = try PMTilesHeader(bytes: start)
        let id = PMTilesTileID.id(z: RoutingGraphArchive.zoom, x: x, y: y)
        var entries = try PMTilesDirectory.entries(
            from: read(header.rootDirectoryOffset, header.rootDirectoryLength)
        )
        while let entry = PMTilesDirectory.entry(holding: id, in: entries) {
            guard entry.isLeaf else {
                return Data(try read(header.tileDataOffset + entry.offset, entry.length))
            }
            entries = try PMTilesDirectory.entries(from: read(header.leafDirectoryOffset + entry.offset, entry.length))
        }
        return nil
    }
}

enum RoutingBuildError: Error, CustomStringConvertible {
    case notAnArchiveName(String)
    case outputIsNotABuild(String)
    case tileWrittenTwice(UInt64)
    case rootTooLarge(Int)

    var description: String {
        switch self {
        case .notAnArchiveName(let name):
            "'\(name)' is not a name the app asks the tile server for: `routing`, then hyphenated parts of "
                + "lower-case letters and digits."
        case .outputIsNotABuild(let path):
            "\(path) holds files and no \(RoutingGraphBuild.recordFileName), so it is not an earlier routing "
                + "build to replace. Name an empty directory, or a previous build's."
        case .tileWrittenTwice(let id):
            "tile \(id) was written twice."
        case .rootTooLarge(let bytes):
            "the root directory is \(bytes) bytes, past the archive's first \(PMTilesHeader.rootReadBytes)."
        }
    }
}
