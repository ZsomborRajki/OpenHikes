//
//  Tool.swift
//  trail-cells
//
//  The command-line tool behind `Scripts/trail-cells.sh`: it files an
//  OpenStreetMap extract's hiking routes, places and trails into squares,
//  packs each set into an archive for the tile server, and keeps or takes the
//  copies in the public database that earlier builds of the app read. It
//  files the Copernicus DEM's heights into squares as well
//  (`ElevationBuild.swift`).
//
//  It is compiled by that script, from the files in this directory and from
//  the app's own — each set's grid and file, the byte format they share,
//  the heights' credit and `CommunitySchema.swift`; the script's
//  `tool_sources` names them — so what the tool writes and what the app
//  reads are one source. The script is the front door: it finds osmium, the
//  container's name and the key; this takes them as options and decides
//  nothing about the machine it is on.
//

import Foundation

struct UsageError: Error, CustomStringConvertible {
    var description: String
}

@main
enum TrailCellsTool {
    static let usage = """
    Usage: trail-cells <command> [options]

      build    --relations <opl> --ways <opl> --out <dir> [--world] [--osm-timestamp <ISO 8601>]
               File the relations of an extract into squares under <dir>.
      build-routes --relations <opl> --ways <opl> --out <dir> [--world] [--osm-timestamp <ISO 8601>]
               File every hiking route's ways into the hiking-routes layer's squares under <dir>.
      build-places --nodes <opl> --relations <opl> --ways <opl> --out <dir> [--world]
               [--osm-timestamp <ISO 8601>]
               File the places a place search offers into the places' squares under <dir>.
      place-filters
               Print the expressions osmium tags-filter finds the places with, one a line.
      build-graph --relations <opl> --ways <opl> --out <dir> [--world] [--osm-timestamp <ISO 8601>]
               File every trail into the trail graph's squares under <dir>.
      graph-filters
               Print the expressions osmium tags-filter finds the trails with, one a line.
      build-routing --relations <opl> --ways <opl|-> --out <dir> [--name <archive>] [--world]
               [--osm-timestamp <ISO 8601>]
               File every trail and the roads that join them into the trail maker's archive,
               <dir>/<archive>.pmtiles (default routing). `--ways -` reads standard input.
      routing-filters
               Print the expressions osmium tags-filter finds them with, one a line.
      routing-tile <archive.pmtiles> <x> <y> [--json]
               Print what a tile of the trail maker's archive holds.
      build-elevation --out <dir> [--area <south>,<west>,<north>,<east>] [--name <archive>]
               [--source <url|dir>] [--coarser <url|dir>] [--jobs <n>]
               File the Copernicus DEM's 30 m heights into the elevation squares,
               <dir>/<archive>.pmtiles (default elevation-YYYYMMDD-HH, for the hour the build began),
               the whole world unless --area names whole degrees, and read it back.
      copernicus-tile <file.tif> [--post <row>,<column>]...
               Print what a Copernicus DEM tile holds, read as build-elevation reads it.
      elevation-height <archive.pmtiles> <latitude> <longitude>
               Print the height at a point, read out of an elevation archive as the app reads it.
      copernicus-fixture <out.tif> --south <degrees> --west <degrees>
               Write a tile laid out as Copernicus lays theirs out, whose height at a post is a
               hundred metres plus its column, for the script tests.
      pack     <build-dir> --out <dir> [--name <archive>]
               Pack a whole-world build of the day hikes', the hiking-routes layer's or the places'
               squares into one archive for the tile server, <dir>/<archive>.pmtiles (default
               <list>-YYYYMMDD-HH, for the hour the extract is current to), and read it back.
      archive-tile <archive.pmtiles> <square-name> [--json]
               Print what the square of that name holds, read out of the archive of its set.
      upload   <dir> --container <id> --environment development|production
               --key-id <id> --key-file <pem> [--dry-run] [--yes] [--replace-world]
               Make the public database hold what <dir> does.
      prune    <trails|routes|places|graph> --container <id> --environment development|production
               --key-id <id> --key-file <pem> [--dry-run] [--yes]
               Take one set of squares out of the public database, its manifest last.
      whoami   --container <id> --environment development|production --key-id <id> --key-file <pem>
               Print the account the key acts as.
      sign     --key-id <id> --key-file <pem> --subpath <path> --date <ISO 8601> [--body-file <file>]
               Print the headers a request would carry, and send nothing.
      inspect  <file.cell> [--json]
               Print what a square holds, of either set.
      cell     <latitude> <longitude>
               Print the record name of the square a point is in.
    """

    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch let error as UsageError {
            printError("error: \(error.description)\n\n\(usage)")
            exit(2)
        } catch {
            printError("error: \(error)")
            exit(1)
        }
    }

    static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else { throw UsageError(description: "no command given.") }
        var options = Options(Array(arguments.dropFirst()))
        switch command {
        case "build":
            try build(&options)
        case "build-routes":
            try buildRoutes(&options)
        case "build-places":
            try buildPlaces(&options)
        case "place-filters":
            try options.finish()
            PlaceSquareBuild.osmiumFilters.forEach { print($0) }
        case "build-graph":
            try buildGraph(&options)
        case "graph-filters":
            try options.finish()
            TrailGraphSquareBuild.osmiumFilters.forEach { print($0) }
        case "build-routing":
            try await buildRouting(&options)
        case "routing-filters":
            try options.finish()
            RoutingGraphBuild.osmiumFilters.forEach { print($0) }
        case "routing-tile":
            try routingTile(&options)
        case "build-elevation":
            try await buildElevation(&options)
        case "copernicus-tile":
            try copernicusTile(&options)
        case "elevation-height":
            try elevationHeight(&options)
        case "copernicus-fixture":
            let path = try options.positional("a file to write")
            guard let south = Int(try options.required("--south")), let west = Int(try options.required("--west")) else {
                throw UsageError(description: "--south and --west take whole degrees.")
            }
            try options.finish()
            try CopernicusTile.fixture(south: south, west: west) { _, column in Float(100 + column) }
                .write(to: URL(fileURLWithPath: path))
        case "pack":
            try pack(&options)
        case "archive-tile":
            try archiveTile(&options)
        case "upload":
            try await Upload.run(&options)
        case "prune":
            try await Prune.run(&options)
        case "whoami":
            try await Upload.whoAmI(&options)
        case "sign":
            try Upload.sign(&options)
        case "inspect":
            try inspect(&options)
        case "cell":
            try cell(&options)
        case "-h", "--help", "help":
            print(usage)
        default:
            throw UsageError(description: "unknown command '\(command)'.")
        }
    }

    static func printError(_ message: String) {
        // What was printed before the error, before the error: standard
        // output is held back when it is a pipe, and standard error is not.
        fflush(stdout)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

// MARK: - Commands

private extension TrailCellsTool {
    /// What `build` and `build-routes` both take.
    static func buildOptions(_ options: inout Options) throws -> BuildOptions {
        let timestamp = try options.value("--osm-timestamp").map { text -> Date in
            guard let date = ISO8601DateFormatter().date(from: text) else {
                throw UsageError(description: "--osm-timestamp '\(text)' is not an ISO 8601 date.")
            }
            return date
        }
        let build = BuildOptions(
            relationsPath: try options.required("--relations"),
            waysPath: try options.required("--ways"),
            outputDirectory: URL(fileURLWithPath: try options.required("--out"), isDirectory: true),
            coversTheWorld: options.flag("--world"),
            osmTimestamp: timestamp
        )
        try options.finish()
        return build
    }

    static func buildRoutes(_ options: inout Options) throws {
        let build = try buildOptions(&options)
        let summary = try RouteSquareBuild.run(build)
        print("Read \(summary.relationsRead) relations: \(summary.routes) hiking routes, "
            + "\(summary.ways) ways and \(summary.points) points.")
        for level in RouteSquareLevel.shallowestFirst {
            let largest = summary.largest[level].map { ", the largest \($0.name) at \($0.bytes) bytes" } ?? ""
            print("  \(level) (zoom \(level.firstZoom) on): \(summary.squares[level] ?? 0) squares, "
                + "\(summary.bytes[level] ?? 0) bytes\(largest).")
        }
        print(build.coversTheWorld
            ? "Marked complete: a square with no file is a square with no routes."
            : "Not marked complete: the app draws nothing from squares that are not the whole world. "
                + "Pass --world for a build of the whole planet.")
    }

    static func buildPlaces(_ options: inout Options) throws {
        let nodesPath = try options.required("--nodes")
        var build = try buildOptions(&options)
        build.nodesPath = nodesPath
        let summary = try PlaceSquareBuild.run(build)
        print("Filed \(summary.places) places — \(summary.nodes) nodes, \(summary.ways) ways and "
            + "\(summary.relations) relations — in \(summary.squares) squares, \(summary.bytes) bytes in all.")
        if summary.withoutPositions > 0 {
            print("  left out \(summary.withoutPositions) running out of the extract")
        }
        if summary.acrossSquares > 0 {
            print("  filed \(summary.acrossSquares) under more than one square, reaching over a square's edge")
        }
        if let largest = summary.largest {
            print("The largest square is \(largest.name), \(largest.bytes) bytes for \(largest.places) places.")
        }
        print(build.coversTheWorld
            ? "Marked complete: a square with no file is a square with no places."
            : "Not marked complete: the app reads only squares that are the whole world, and keeps asking "
                + "Overpass. Pass --world for a build of the whole planet.")
    }

    static func buildGraph(_ options: inout Options) throws {
        let build = try buildOptions(&options)
        let summary = try TrailGraphSquareBuild.run(build)
        print("Filed \(summary.trails) trails (\(summary.nodes) nodes) in \(summary.squares) squares, "
            + "\(summary.bytes) bytes in all.")
        if summary.notWalkable > 0 {
            print("  left out \(summary.notWalkable) that may not be walked")
        }
        if summary.withoutPositions > 0 {
            print("  left out \(summary.withoutPositions) running out of the extract")
        }
        if let largest = summary.largest {
            print("The largest square is \(largest.name), \(largest.bytes) bytes for \(largest.ways) trails.")
        }
        print(build.coversTheWorld
            ? "Marked complete: a square with no file is a square with no trails."
            : "Not marked complete: the app reads only squares that are the whole world, and keeps asking "
                + "Overpass. Pass --world for a build of the whole planet.")
    }

    static func buildRouting(_ options: inout Options) async throws {
        let timestamp = try options.value("--osm-timestamp").map { text -> Date in
            guard let date = ISO8601DateFormatter().date(from: text) else {
                throw UsageError(description: "--osm-timestamp '\(text)' is not an ISO 8601 date.")
            }
            return date
        }
        let build = RoutingBuildOptions(
            relationsPath: try options.required("--relations"),
            waysPath: try options.required("--ways"),
            outputDirectory: URL(fileURLWithPath: try options.required("--out"), isDirectory: true),
            name: try options.value("--name") ?? SquareArchive.routing.listName,
            coversTheWorld: options.flag("--world"),
            osmTimestamp: timestamp
        )
        try options.finish()
        let summary = try await RoutingGraphBuild.run(build)
        print("Filed \(summary.ways) ways (\(summary.nodes) nodes), trails and the roads that join them, in "
            + "\(summary.tiles.count) tiles at zoom \(RoutingGraphArchive.zoom), \(summary.tiles.bytes) bytes in all.")
        if summary.notWalkable > 0 {
            print("  left out \(summary.notWalkable) that may not be walked, as read")
        }
        if summary.withoutPositions > 0 {
            print("  left out \(summary.withoutPositions) running out of the extract, as read")
        }
        let sizes = summary.tiles
        if let largest = sizes.largest {
            print("By tile: the median \(sizes.median) bytes, one in a hundred over \(sizes.percentile99), the largest "
                + "\(largest.name) at \(largest.bytes) bytes for \(largest.ways) ways.")
        }
        if let archive = summary.archive {
            print("Wrote \(archive.path), \(summary.archiveBytes) bytes\(summary.isClustered ? ", clustered" : "").")
        }
        print(build.coversTheWorld
            ? "Marked complete: a tile the archive does not hold is ground with no ways on it."
            : "Not marked complete: upload-routing refuses it. Pass --world for a build of the whole planet.")
    }

    static func routingTile(_ options: inout Options) throws {
        let json = options.flag("--json")
        let path = try options.positional("an archive")
        guard let x = Int(try options.positional("a tile's x")), let y = Int(try options.positional("a tile's y")) else {
            throw UsageError(description: "a tile's x and y are whole numbers.")
        }
        // A tile id is made of the bits of x and y the zoom has, so one past
        // the grid would read another tile, and a negative one would trap.
        let side = TrailGraphSquareGrid.tilesPerSide(atZoom: RoutingGraphArchive.zoom)
        guard (0..<side).contains(x), (0..<side).contains(y) else {
            throw UsageError(description: "a tile at zoom \(RoutingGraphArchive.zoom) has an x and a y from 0 to \(side - 1).")
        }
        try options.finish()
        let reader = try TileArchiveReader(url: URL(fileURLWithPath: path))
        guard let bytes = try reader.tile(z: RoutingGraphArchive.zoom, x: x, y: y) else {
            print("no tile \(RoutingGraphArchive.zoom)/\(x)/\(y)")
            return
        }
        let graph = try TrailGraphSquareFile(decoding: bytes)
        if json {
            print(try Inspection.json(of: graph))
        } else {
            print("scale \(graph.coordinateScale), \(graph.ways.count) ways, "
                + "\(graph.ways.reduce(0) { $0 + $1.nodes.count }) nodes")
            for way in graph.ways {
                print("way/\(way.id)\t\(way.highway)\t\(way.nodes.count) nodes")
            }
        }
    }

    static func build(_ options: inout Options) throws {
        let build = try buildOptions(&options)
        let summary = try TrailCellBuild.run(build)
        print("Read \(summary.relationsRead) relations.")
        for reason in TrailCellBuild.Dropped.allCases {
            guard let count = summary.dropped[reason] else { continue }
            print("  left out \(count) \(reason.rawValue)")
        }
        print("Filed \(summary.routes) routes (\(summary.points) points) in \(summary.cells) squares, "
            + "\(summary.bytes) bytes in all.")
        if let largest = summary.largest {
            print("The largest square is \(largest.name), \(largest.bytes) bytes.")
        }
        print(build.coversTheWorld
            ? "Marked complete: a square with no file is a square with no routes."
            : "Not marked complete: the app reads only squares that are the whole world, and keeps asking "
                + "Overpass. Pass --world for a build of the whole planet.")
    }

    static func inspect(_ options: inout Options) throws {
        let asJSON = options.flag("--json")
        let path = try options.positional("a square's file")
        try options.finish()
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // Each file's envelope says which it is, so the first that reads it
        // is the one. A day hike's is tried last, and says why it is none.
        let set: SquareArchive = if (try? TrailGraphSquareFile(decoding: data)) != nil {
            .routing
        } else if (try? PlaceSquareFile(decoding: data)) != nil {
            .places
        } else if (try? RouteSquareFile(decoding: data)) != nil {
            .routes
        } else {
            .trails
        }
        try printSquare(data, of: set, asJSON: asJSON)
    }

    /// What a square's file holds, read as the file a square of `set` is: a
    /// trail graph square for the trail maker's archive, whose tiles are
    /// those files too.
    static func printSquare(_ data: Data, of set: SquareArchive, asJSON: Bool) throws {
        switch set {
        case .routing:
            let graph = try TrailGraphSquareFile(decoding: data)
            if asJSON {
                print(try Inspection.json(of: graph))
                return
            }
            print("scale \(graph.coordinateScale), \(graph.ways.count) trails, "
                + "\(graph.ways.reduce(0) { $0 + $1.nodes.count }) nodes")
            for way in graph.ways {
                print("\(way.id)\t\(way.highway)\t\(way.nodes.count) nodes\t\(way.tags[.name] ?? "")")
            }

        case .places:
            let places = try PlaceSquareFile(decoding: data)
            if asJSON {
                print(try Inspection.json(of: places))
                return
            }
            print("scale \(places.coordinateScale), \(places.places.count) places")
            for place in places.places {
                print("\(place.element.name)/\(place.id)\t\(place.point.latitude) \(place.point.longitude)\t"
                    + (place.tags["name"] ?? ""))
            }

        case .routes:
            let routes = try RouteSquareFile(decoding: data)
            if asJSON {
                print(try Inspection.json(of: routes))
                return
            }
            print("scale \(routes.coordinateScale), \(routes.routes.count) routes, \(routes.lines.count) lines, "
                + "\(routes.lines.reduce(0) { $0 + $1.points.count }) points")
            for route in routes.routes {
                print("\(route.id)\t\(route.tags["network"] ?? "-")\t\(route.tags["ref"] ?? "-")\t\(route.tags["name"] ?? "")")
            }

        case .trails:
            let file = try TrailCellFile(decoding: data)
            if asJSON {
                print(try Inspection.json(of: file))
                return
            }
            print("scale \(file.coordinateScale), \(file.relations.count) relations")
            for relation in file.relations {
                let points = relation.ways.reduce(0) { $0 + $1.points.count }
                print("\(relation.id)\t\(relation.ways.count) ways\t\(points) points\t\(relation.tags["name"] ?? "")")
            }

        case .elevation:
            let square = try ElevationSquareFile(decoding: data)
            let known = square.heights.filter { $0 != ElevationSquareFile.unknown }
            let summary: [String: Any] = [
                "rows": square.rows,
                "columns": square.columns,
                "lowest": known.min().map(Int.init) as Any,
                "highest": known.max().map(Int.init) as Any,
                "unknown": square.heights.count - known.count,
                "northWest": square.height(at: 0) as Any,
            ]
            if asJSON {
                let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                return
            }
            print("\(square.rows) × \(square.columns) posts, \(square.heights.count - known.count) with no height, "
                + "from \(known.min().map(String.init) ?? "-") to \(known.max().map(String.init) ?? "-") m")
        }
    }

    static func buildElevation(_ options: inout Options) async throws {
        let area = try options.value("--area").map { text -> (south: Int, west: Int, north: Int, east: Int) in
            let parts = text.split(separator: ",").compactMap { Int($0) }
            guard parts.count == 4, parts[0] < parts[2], parts[1] < parts[3],
                  (-90...90).contains(parts[0]), (-90...90).contains(parts[2]),
                  (-180...180).contains(parts[1]), (-180...180).contains(parts[3])
            else {
                throw UsageError(description: "--area takes four whole degrees, south,west,north,east.")
            }
            return (parts[0], parts[1], parts[2], parts[3])
        }
        let jobs = try options.value("--jobs").map { text -> Int in
            guard let jobs = Int(text), jobs > 0 else { throw UsageError(description: "--jobs takes a count.") }
            return jobs
        }
        let build = ElevationBuildOptions(
            source: try options.value("--source") ?? ElevationBuild.defaultSource,
            coarser: try options.value("--coarser") ?? ElevationBuild.defaultCoarser,
            outputDirectory: URL(fileURLWithPath: try options.required("--out"), isDirectory: true),
            name: try options.value("--name"),
            area: area,
            jobs: jobs ?? 16
        )
        try options.finish()
        let summary = try await ElevationBuild.run(build)
        let record = summary.record
        print("Filed \(summary.degrees) degrees and \(summary.withheld) withheld into \(summary.squares) squares, "
            + "\(summary.seaSquares) more at sea level left out, \(record.bytes) bytes in "
            + "\(summary.archive.path).")
        print(record.complete
            ? "Marked complete: a square the archive does not hold is sea."
            : "Not marked complete: upload-archive refuses it. Leave out --area, --source and --coarser "
                + "for the whole world, read from Copernicus' buckets.")
    }

    static func elevationHeight(_ options: inout Options) throws {
        let path = try options.positional("an archive")
        let latitudeText = try options.positional("a latitude")
        let longitudeText = try options.positional("a longitude")
        try options.finish()
        guard let latitude = Double(latitudeText), let longitude = Double(longitudeText),
              let around = ElevationSquareGrid.posts(aroundLatitude: latitude, longitude: longitude)
        else { throw UsageError(description: "'\(latitudeText) \(longitudeText)' is not a place on the Earth.") }
        let reader = try TileArchiveReader(url: URL(fileURLWithPath: path))
        var squares: [ElevationSquare: ElevationSquareFile?] = [:]
        for post in around.posts {
            let square = ElevationSquareGrid.place(of: post).square
            guard squares[square] == nil else { continue }
            let tile = SquareArchive.elevation.tile(named: ElevationSquareGrid.recordName(for: square))!
            squares[square] = try reader.tile(z: tile.zoom, x: tile.x, y: tile.y).map(ElevationSquareFile.init(decoding:))
        }
        let height = around.height { post in
            let place = ElevationSquareGrid.place(of: post)
            // No tile is sea, at sea level.
            guard let square = squares[place.square] ?? nil else { return 0 }
            return square.height(at: place.index)
        }
        let names = Set(squares.keys).map(ElevationSquareGrid.recordName(for:)).sorted().joined(separator: " ")
        print("\(height.map { String(format: "%.1f m", $0) } ?? "no height")\t\(names)")
    }

    static func copernicusTile(_ options: inout Options) throws {
        let path = try options.positional("a tile")
        var posts: [(row: Int, column: Int)] = []
        while let text = try options.value("--post") {
            let parts = text.split(separator: ",").compactMap { Int($0) }
            guard parts.count == 2 else { throw UsageError(description: "--post takes a row and a column.") }
            posts.append((parts[0], parts[1]))
        }
        try options.finish()
        let tile = try CopernicusTile(file: Data(contentsOf: URL(fileURLWithPath: path)))
        let finite = tile.heights.filter(\.isFinite)
        print("\(tile.rows) × \(tile.columns) posts from \(tile.north)°N \(tile.west)°E, a step of "
            + "\(tile.rowStep)° × \(tile.columnStep)°, from \(finite.min() ?? .nan) to \(finite.max() ?? .nan) m, "
            + "\(tile.heights.count - finite.count) not a number")
        for post in posts {
            guard (0..<tile.rows).contains(post.row), (0..<tile.columns).contains(post.column) else {
                throw UsageError(description: "post \(post.row),\(post.column) is outside the tile.")
            }
            print("\(post.row),\(post.column)\t\(tile.heights[post.row * tile.columns + post.column])")
        }
    }

    static func pack(_ options: inout Options) throws {
        // The named options first, so that their values are not taken for
        // the build's directory.
        let output = try options.required("--out")
        let name = try options.value("--name")
        let pack = PackOptions(
            buildDirectory: URL(fileURLWithPath: try options.positional("a build's directory"), isDirectory: true),
            outputDirectory: URL(fileURLWithPath: output, isDirectory: true),
            name: name
        )
        try options.finish()
        let summary = try SquarePack.run(pack)
        let record = summary.record
        print("Packed \(record.squares) squares of the \(record.list), \(record.itemCount) \(summary.itemName), "
            + "into \(summary.archive.path), \(record.bytes) bytes, at zoom \(record.minimumZoom) to \(record.zoom).")
        if let largest = summary.largest {
            print("The median square is \(summary.median) bytes, the largest \(largest.name) at \(largest.bytes).")
        }
        print("Every tile read back as its square's file.")
    }

    static func archiveTile(_ options: inout Options) throws {
        let json = options.flag("--json")
        let path = try options.positional("an archive")
        let name = try options.positional("a square's name")
        try options.finish()
        guard let set = SquareArchive.allCases.first(where: { $0.tile(named: name) != nil }),
              let tile = set.tile(named: name)
        else {
            throw UsageError(description: "'\(name)' is not the name of a square of any set.")
        }
        let reader = try TileArchiveReader(url: URL(fileURLWithPath: path))
        guard (Int(reader.header.minimumZoom)...Int(reader.header.maximumZoom)).contains(tile.zoom) else {
            throw UsageError(description: "\(name) is a \(set.listName) square, at zoom \(tile.zoom), and the archive "
                + "holds zoom \(reader.header.minimumZoom) to \(reader.header.maximumZoom).")
        }
        guard let bytes = try reader.tile(z: tile.zoom, x: tile.x, y: tile.y) else {
            print("no tile \(tile.zoom)/\(tile.x)/\(tile.y)")
            return
        }
        try printSquare(bytes, of: set, asJSON: json)
    }

    static func cell(_ options: inout Options) throws {
        let latitudeText = try options.positional("a latitude")
        let longitudeText = try options.positional("a longitude")
        try options.finish()
        guard let latitude = Double(latitudeText), let longitude = Double(longitudeText),
              (-90...90).contains(latitude), longitude.isFinite
        else { throw UsageError(description: "'\(latitudeText) \(longitudeText)' is not a latitude and a longitude.") }
        print(TrailCellGrid.recordName(
            for: TrailCellGrid.cell(containingLatitude: latitude, longitude: longitude)
        ))
    }
}

/// A square of either set written out as JSON, for comparing against a
/// fixture.
enum Inspection {
    static func json(of file: TrailCellFile) throws -> String {
        let relations: [[String: Any]] = file.relations.map { relation in
            [
                "id": relation.id,
                "tags": relation.tags,
                "ways": relation.ways.map { way -> [String: Any] in
                    ["role": way.role, "points": way.points.map { [$0.latitude, $0.longitude] }]
                },
            ]
        }
        return try serialized(["scale": file.coordinateScale, "relations": relations])
    }

    static func json(of file: RouteSquareFile) throws -> String {
        let routes: [[String: Any]] = file.routes.map { ["id": $0.id, "tags": $0.tags] }
        let lines: [[String: Any]] = file.lines.map { line in
            [
                "network": "\(line.network)",
                "routes": line.routes,
                "points": line.points.map { [$0.latitude, $0.longitude] },
            ]
        }
        return try serialized(["scale": file.coordinateScale, "routes": routes, "lines": lines])
    }

    static func json(of file: PlaceSquareFile) throws -> String {
        let places: [[String: Any]] = file.places.map { place in
            [
                "element": place.element.name,
                "id": place.id,
                "point": [place.point.latitude, place.point.longitude],
                "box": [place.box.south, place.box.west, place.box.north, place.box.east],
                "tags": place.tags,
            ]
        }
        return try serialized(["scale": file.coordinateScale, "places": places])
    }

    static func json(of file: TrailGraphSquareFile) throws -> String {
        let ways: [[String: Any]] = file.ways.map { way in
            var tags: [String: String] = [:]
            for (tag, value) in way.tags {
                tags["\(tag)"] = value
            }
            return [
                "id": way.id,
                "highway": way.highway,
                "tags": tags,
                "nodes": way.nodes.map { [$0.id, Int64($0.latitude), Int64($0.longitude)] },
            ]
        }
        return try serialized(["scale": file.coordinateScale, "ways": ways])
    }

    private static func serialized(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Options

/// The command line after the command: named values, flags and what is left.
///
/// Every option a command does not take is an error rather than something
/// skipped — `finish()` is what says so, once the command has taken its own.
struct Options {
    private var remaining: [String]

    init(_ arguments: [String]) {
        remaining = arguments
    }

    mutating func flag(_ name: String) -> Bool {
        guard let index = remaining.firstIndex(of: name) else { return false }
        remaining.remove(at: index)
        return true
    }

    mutating func value(_ name: String) throws -> String? {
        guard let index = remaining.firstIndex(of: name) else { return nil }
        guard index + 1 < remaining.count, !remaining[index + 1].hasPrefix("--") else {
            throw UsageError(description: "missing value for \(name).")
        }
        let value = remaining[index + 1]
        remaining.removeSubrange(index...index + 1)
        return value
    }

    mutating func required(_ name: String) throws -> String {
        guard let value = try value(name) else { throw UsageError(description: "\(name) is required.") }
        return value
    }

    /// The next argument that is not an option. A negative number is one:
    /// `cell -33.9 151.2` names a place.
    mutating func positional(_ what: String) throws -> String {
        guard let index = remaining.firstIndex(where: { !$0.hasPrefix("--") }) else {
            throw UsageError(description: "expected \(what).")
        }
        return remaining.remove(at: index)
    }

    func finish() throws {
        guard let stray = remaining.first else { return }
        throw UsageError(description: stray.hasPrefix("--")
            ? "unknown option '\(stray)'."
            : "unexpected argument '\(stray)'.")
    }
}
