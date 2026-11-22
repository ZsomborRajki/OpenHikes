//
//  Pack.swift
//  trail-cells
//
//  The day hikes', the hiking-routes layer's or the places' squares, as a
//  build wrote them, packed into one PMTiles archive for the tile server's
//  bucket: a square a tile, where `SquareArchive.swift` says it goes.
//
//  Packed from a build's directory rather than built straight into an
//  archive, so that the build stays the one thing that files squares, and
//  what the app reads out of the archive is each square's file byte for
//  byte, the same file `upload` would put in the public database for the
//  installed builds that still read it there.
//
//  ## Only the whole world
//
//  The app reads a square the archive does not hold as ground with nothing
//  on it: *no trails here*, no line to draw, no place to offer. A build of a
//  region leaves out everything that runs out of its extract, and holds no
//  square at all beyond it, so packed it would answer *nothing here* for the
//  rest of the world. A build that is not marked complete is refused, and
//  only a build of the planet with `--world` is marked.
//
//  ## Not the trail graph
//
//  The trail graph's squares are trails alone, four zooms above a region.
//  The app reads the trail graph out of the trail maker's archive instead,
//  every trail and the roads that join them a region a tile, which
//  `build-routing` builds, and nothing reads a trail graph square from the
//  tile server. Its build is refused.
//
//  ## Staged, then read back
//
//  The archive is written beside the output, in a directory of its own, and
//  every tile is then read back by the archive's own directories, as the
//  tile server reads one, and held to its square's file. Only an archive
//  that reads back whole replaces what the output held, the record that
//  names it last, so the output never holds a record without its archive,
//  and a pack that fails leaves an earlier one as it was.
//

import Foundation

struct PackOptions {
    var buildDirectory: URL
    var outputDirectory: URL
    /// The archive's name on the server, which is its file's name without
    /// `.pmtiles`: `nil` for the set's list name and the hour the build's
    /// extract is current to, `trails-20261122-00`.
    var name: String?
}

enum SquarePack {
    /// What a pack says of itself, beside its archive: what
    /// `Scripts/trail-cells.sh upload-archive` reads before it sends one.
    static let recordFileName = "archive-build.json"

    struct Record: Codable {
        var name: String
        /// The list the tile server's manifest names it under:
        /// `SquareArchive.listName`.
        var list: String
        var generation: Int
        var minimumZoom: Int
        /// The deepest zoom of its tiles, which the manifest lists it with.
        var zoom: Int
        /// Whether the archive is every square there is. Always so: a build
        /// that is not is refused.
        var complete: Bool
        /// When the squares were built.
        var builtAt: Date
        var packedAt: Date
        var osmTimestamp: Date?
        var squares: Int
        /// The routes or places the build filed, as its manifest counts them.
        var itemCount: Int
        var bytes: UInt64
    }

    struct Summary {
        var record: Record
        var archive: URL
        var itemName: String
        var median = 0
        var largest: (name: String, bytes: Int)?
    }

    /// The set a build of `kind` is packed as.
    static func set(ofKind kind: String?, in directory: URL) throws -> SquareArchive {
        switch kind {
        case nil: return .trails
        case RouteSquareBuild.manifestKind: return .routes
        case PlaceSquareBuild.manifestKind: return .places
        case TrailGraphSquareBuild.manifestKind: throw PackError.trailGraph(directory.path)
        case let other?: throw PackError.unknownKind(other)
        }
    }

    /// `trails-20261122-00`: the set's list name, then the day and the hour
    /// the extract is current to, in UTC, as `build-routing` names its
    /// archive.
    static func defaultName(for set: SquareArchive, osmTimestamp: Date?) throws -> String {
        guard let osmTimestamp else { throw PackError.noTimestamp }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HH"
        return "\(set.listName)-\(formatter.string(from: osmTimestamp))"
    }

    static func run(_ options: PackOptions) throws -> Summary {
        let build = try BuildManifest.read(from: options.buildDirectory)
        let set = try set(ofKind: build.kind, in: options.buildDirectory)
        guard build.generation == set.generation else {
            throw PackError.otherGeneration(build.generation, set.generation)
        }
        guard build.complete else { throw PackError.notTheWorld(options.buildDirectory.path) }
        let name = try options.name ?? defaultName(for: set, osmTimestamp: build.osmTimestamp)
        guard set.isArchiveName(name) else { throw PackError.notAnArchiveName(name, set) }
        var tiles: [(id: UInt64, name: String)] = []
        for cell in build.cells {
            guard let tile = set.tile(named: cell.name) else { throw PackError.notASquare(cell.name, set) }
            tiles.append((PMTilesTileID.id(z: tile.zoom, x: tile.x, y: tile.y), cell.name))
        }
        tiles.sort { $0.id < $1.id }
        guard try isReplaceable(options.outputDirectory) else {
            throw PackError.outputIsNotAPack(options.outputDirectory.path)
        }

        let manager = FileManager.default
        let staging = options.outputDirectory.appendingPathExtension("staging")
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        let archiveName = "\(name).pmtiles"
        let staged = staging.appendingPathComponent(archiveName)
        let writer = try TileArchiveWriter(url: staged, zooms: set.zooms)
        var sizes: [(name: String, bytes: Int)] = []
        for tile in tiles {
            let bytes = try Data(contentsOf: BuildManifest.cellFile(named: tile.name, in: options.buildDirectory))
            try writer.append(bytes, tileID: tile.id)
            sizes.append((tile.name, bytes.count))
        }
        let archiveBytes = try writer.finish(metadata: metadata(of: set, build: build))
        try readBack(staged, tiles: tiles, from: options.buildDirectory)

        let record = Record(
            name: name,
            list: set.listName,
            generation: set.generation,
            minimumZoom: set.zooms.lowerBound,
            zoom: set.zoom,
            complete: true,
            builtAt: build.builtAt,
            packedAt: Date(),
            osmTimestamp: build.osmTimestamp,
            squares: tiles.count,
            itemCount: build.routeCount,
            bytes: archiveBytes
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: staging.appendingPathComponent(recordFileName), options: .atomic)

        // The record goes first and comes back last, so the output never
        // holds a record without the archive it names.
        try manager.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        try? manager.removeItem(at: options.outputDirectory.appendingPathComponent(recordFileName))
        for file in try manager.contentsOfDirectory(atPath: options.outputDirectory.path) where file.hasSuffix(".pmtiles") {
            try manager.removeItem(at: options.outputDirectory.appendingPathComponent(file))
        }
        let archive = options.outputDirectory.appendingPathComponent(archiveName)
        try manager.moveItem(at: staged, to: archive)
        try manager.moveItem(
            at: staging.appendingPathComponent(recordFileName),
            to: options.outputDirectory.appendingPathComponent(recordFileName)
        )

        let ordered = sizes.map(\.bytes).sorted()
        return Summary(
            record: record,
            archive: archive,
            itemName: set == .places ? "places" : "routes",
            median: ordered.isEmpty ? 0 : ordered[ordered.count / 2],
            largest: sizes.max { $0.bytes < $1.bytes }
        )
    }

    /// Whether a pack may put its archive in `directory`: none there yet, an
    /// empty one, or an earlier pack's, which its record marks.
    static func isReplaceable(_ directory: URL) throws -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return true }
        let entries = try manager.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
        return entries.isEmpty || entries.contains(recordFileName)
    }

    /// Every tile of the archive at `url`, read by its own directories and
    /// held to its square's file, and no tile besides.
    private static func readBack(_ url: URL, tiles: [(id: UInt64, name: String)], from directory: URL) throws {
        let reader = try TileArchiveReader(url: url)
        let held = try reader.tileCount()
        guard held == UInt64(tiles.count) else { throw PackError.readBackCount(held, tiles.count) }
        for tile in tiles {
            let file = try Data(contentsOf: BuildManifest.cellFile(named: tile.name, in: directory))
            guard try reader.tile(id: tile.id) == file else { throw PackError.readBack(tile.name) }
        }
    }

    /// The archive's metadata: what it is, under what licence, and from
    /// when, for whoever reads the archive without this tool.
    private static func metadata(of set: SquareArchive, build: BuildManifest) throws -> Data {
        let what = switch set {
        case .routing: "The trail graph"
        case .trails: "OpenStreetMap's waymarked day hikes, one OpenHikes day-hike square a tile (TrailCellFile)"
        case .routes: "OpenStreetMap's hiking routes, one OpenHikes hiking-routes square a tile, a zoom a level "
            + "of detail (RouteSquareFile)"
        case .places: "The places an OpenHikes place search offers, one square a tile (PlaceSquareFile)"
        }
        var metadata: [String: Any] = [
            "name": "OpenHikes \(set.listName)",
            "description": "\(what), filed as OpenHikes' SquareArchive.\(set.rawValue) says.",
            "attribution": "© OpenStreetMap contributors",
            "list": set.listName,
            "generation": set.generation,
            "complete": build.complete,
            "vector_layers": [Any](),
        ]
        if let timestamp = build.osmTimestamp {
            metadata["osm_timestamp"] = ISO8601DateFormatter().string(from: timestamp)
        }
        return try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    }
}

enum PackError: Error, CustomStringConvertible {
    case trailGraph(String)
    case unknownKind(String)
    case otherGeneration(Int, Int)
    case notTheWorld(String)
    case noTimestamp
    case notAnArchiveName(String, SquareArchive)
    case notASquare(String, SquareArchive)
    case outputIsNotAPack(String)
    case readBackCount(UInt64, Int)
    case readBack(String)

    var description: String {
        switch self {
        case .trailGraph(let path):
            "\(path) is the trail graph's squares, which no archive is packed from: the app reads the trail "
                + "graph out of the trail maker's archive, which build-routing builds."
        case .unknownKind(let kind):
            "this tool does not know a build of kind '\(kind)'."
        case let .otherGeneration(found, written):
            "the build is generation \(found); this tool packs generation \(written)."
        case .notTheWorld(let path):
            "\(path) is not the whole world. The app reads a square the archive does not hold as ground with "
                + "nothing on it, so only a build of the planet with --world is packed."
        case .noTimestamp:
            "the build does not say when its extract was current, which its archive is named for. "
                + "Name it with --name."
        case let .notAnArchiveName(name, set):
            "'\(name)' is not a name the app asks the tile server for: `\(set.listName)`, then hyphenated "
                + "parts of lower-case letters and digits."
        case let .notASquare(name, set):
            "the build lists \(name), which is not one of the \(set.listName) squares."
        case .outputIsNotAPack(let path):
            "\(path) holds files and no \(SquarePack.recordFileName), so it is not an earlier pack to replace. "
                + "Name an empty directory, or a previous pack's."
        case let .readBackCount(held, written):
            "the archive's directories hold \(held) tiles, and \(written) were written."
        case .readBack(let name):
            "\(name) does not read back out of the archive as its square's file."
        }
    }
}
