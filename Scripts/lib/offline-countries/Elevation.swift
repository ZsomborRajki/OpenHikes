//
//  Elevation.swift
//  offline-countries
//
//  An area's heights: the squares of the elevation archive
//  (`SquareArchive.elevation`, one eighth-of-a-degree square of
//  `ElevationSquareGrid` a tile) that lie within a margin of the area's
//  outline, copied out of the archive the tile server lists, so a line drawn,
//  found or imported there is given heights on the device with no signal.
//
//  **Copied, never rebuilt.** Each square is the square the server sends, so
//  a height read offline is the height read online, post for post.
//
//  **Every square the file covers is a tile of it.** The world's archive has
//  no tile for a square that is sea level throughout, and the server answers
//  it with a 204, which the app reads as sea because the archive is the whole
//  world. A file of part of the world cannot say that by leaving a tile out,
//  so each such square is written as a square of posts at 0 m, of its row's
//  size: the same few hundred bytes for every square of a band of latitude.
//  A square the file has no tile for is one it says nothing about, and the
//  app asks the server for it as it did before there were downloads.
//
//  **The margin is the map's and a little more.** A height is wanted where a
//  line can be drawn or followed on the downloaded map, which reaches a few
//  kilometres past the outline, and a square is the unit: every square within
//  the margin is there whole, so a line along a border keeps its heights a
//  square or so past it. Unlike the day hikes', the margin is not wide: the
//  heights are a tenth of an area's map in the mountains, and a wide margin
//  round a small country would be more than the country.
//

import Foundation

enum ElevationSquares {
    /// How far round an area's outline its squares reach, in kilometres.
    static let defaultMarginKilometers = 5.0

    /// `ElevationSquareGrid`'s squares, counted from the South Pole as the
    /// cover counts them. The grid counts its rows from the North Pole.
    static let cover = SquareCover(perDegree: ElevationSquareGrid.squaresPerDegree)

    /// Every square with its middle inside `rings`, every square an edge of
    /// them passes through, and every square within `marginKilometers` of
    /// those.
    static func squares(rings: [Ring], marginKilometers: Double) -> [ElevationSquare] {
        cover.squares(rings: rings, marginKilometers: marginKilometers).map(square(of:))
    }

    /// The grid's square of a square of the cover: the same one, its row
    /// counted from the other pole.
    static func square(of square: SquareCover.Square) -> ElevationSquare {
        ElevationSquare(row: ElevationSquareGrid.rowCount - 1 - square.row, column: square.column)
    }

    /// West, south, east and north of `squares`, in degrees.
    static func bounds(of squares: [ElevationSquare]) -> (west: Double, south: Double, east: Double, north: Double) {
        cover.bounds(of: squares.map { SquareCover.Square(row: ElevationSquareGrid.rowCount - 1 - $0.row, column: $0.column) })
    }

    /// A square of `row` that is sea level throughout, as the app reads one:
    /// every post at 0 m. The world's archive holds none of these.
    static func seaLevel(row: Int) -> ElevationSquareFile {
        let columns = ElevationSquareGrid.columnsPerSquare(row: row)
        let rows = ElevationSquareGrid.rowsPerSquare
        return ElevationSquareFile(rows: rows, columns: columns, heights: Array(repeating: 0, count: rows * columns))
    }
}

// MARK: - Cutting

/// The elevation archive an area's squares are copied from.
struct ElevationSource {
    let extractor: Extractor
    /// Its name on the tile server, which its squares are read back from.
    let name: String
    let marginKilometers: Double
    let metadata: [UInt8]
}

extension Tool {
    /// How many of an area's squares are read back against the source, and
    /// how many of those are also asked of the tile server, when one is
    /// named. A sample, not every square: a large country is tens of
    /// thousands of them, and the bucket is read a range at a time.
    static let checkedElevationSquares = 400
    static let serverCheckedElevationSquares = 12

    /// Cuts the squares of `rings` out of `elevation` into
    /// `<id>-elevation-<build>`, reads them back through the app's reader
    /// against the source, and returns the file as the manifest lists it.
    static func cutElevation(
        id: String,
        rings: [Ring],
        build: String,
        from elevation: ElevationSource,
        into output: URL,
        server: URL?
    ) async throws -> OfflineCountryManifest.File {
        let source = elevation.extractor
        guard source.header.tileCompression == PMTilesCompression.uncompressed.rawValue else {
            fail("\(elevation.name)'s tiles are packed (\(source.header.tileCompression)); a sea-level square is written as it is")
        }
        let squares = ElevationSquares.squares(rings: rings, marginKilometers: elevation.marginKilometers)
        guard !squares.isEmpty else { fail("\(id) covers no elevation square") }
        var tiles: [UInt64: ElevationSquare] = [:]
        for square in squares {
            guard let tile = SquareArchive.elevation.tile(named: ElevationSquareGrid.recordName(for: square)) else {
                fail("square \(square) of \(id) is no tile of the elevation archive")
            }
            tiles[PMTilesTileID.id(z: tile.zoom, x: tile.x, y: tile.y)] = square
        }
        let ids = tiles.keys.sorted()
        let located = try await source.locate(ids)
        // Sea level, a square of its band's size for each row that needs one.
        var seaByRow: [Int: [UInt8]] = [:]
        var filling: [UInt64: [UInt8]] = [:]
        let had = Set(located.map(\.id))
        for (tileID, square) in tiles where !had.contains(tileID) {
            if seaByRow[square.row] == nil {
                seaByRow[square.row] = Array(ElevationSquares.seaLevel(row: square.row).encoded())
            }
            filling[tileID] = seaByRow[square.row]
        }
        let zoom = SquareArchive.elevation.zoom
        let bounds = ElevationSquares.bounds(of: squares)
        var header = PMTilesHeader()
        header.minimumZoom = UInt8(zoom)
        header.maximumZoom = UInt8(zoom)
        header.bounds = [bounds.west, bounds.south, bounds.east, bounds.north].map { Int32(($0 * 1e7).rounded()) }
        header.center = [(bounds.west + bounds.east) / 2, (bounds.south + bounds.north) / 2]
            .map { Int32(($0 * 1e7).rounded()) }
        header.centerZoom = UInt8(zoom)
        let name = "\(id)-elevation-\(build).pmtiles"
        let url = output.appending(path: name)
        let written = try await source.write(
            located,
            filling: filling,
            to: url,
            header: header,
            metadata: labeled(elevation.metadata, country: id, build: build, source: elevation.name)
        )
        print("  \(name): \(written.addressed) squares, \(located.count) above sea level, \(written.bytes) bytes")
        try await checkElevation(
            url,
            squares: tiles,
            against: source,
            located: located,
            filling: filling,
            server: server.map { $0.appending(path: elevation.name) }
        )
        return OfflineCountryManifest.File(
            role: .elevation,
            path: "countries/\(name)",
            byteCount: Int64(written.bytes),
            sha256: try sha256(of: url),
            minimumZoom: zoom,
            maximumZoom: zoom
        )
    }

    /// Reads the written file back through the app's own reader: a tile for
    /// every square and no other, and for a sample of them the source's
    /// bytes, or sea level where the source has none, each a square the app
    /// reads at its row's size. A few are held to the tile server's answer
    /// too, a 204 for sea.
    static func checkElevation(
        _ url: URL,
        squares: [UInt64: ElevationSquare],
        against source: Extractor,
        located: [LocatedTile],
        filling: [UInt64: [UInt8]],
        server: URL?
    ) async throws {
        let archive = try PMTilesArchive(contentsOf: url)
        guard archive.header.addressedTiles == UInt64(squares.count) else {
            fail("\(url.lastPathComponent) addresses \(archive.header.addressedTiles) squares, not \(squares.count)")
        }
        let byID = Dictionary(located.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = squares.sorted { $0.key < $1.key }
        // Every sea-level square once, whatever the sample takes.
        var checkedSea: Set<[UInt8]> = []
        let step = max(sorted.count / checkedElevationSquares, 1)
        // Of the squares read back, every so many is asked of the server too.
        let sampled = (sorted.count + step - 1) / step
        let serverStep = max(sampled / serverCheckedElevationSquares, 1)
        var checked = 0
        var asked = 0
        for (index, (id, square)) in sorted.enumerated() {
            guard let tile = SquareArchive.elevation.tile(named: ElevationSquareGrid.recordName(for: square)),
                  let written = try archive.tile(z: tile.zoom, x: tile.x, y: tile.y)
            else { fail("\(url.lastPathComponent) has no tile for square \(square)") }
            let sea = filling[id]
            let isNewSea = sea.map { checkedSea.insert($0).inserted } ?? false
            guard index % step == 0 || isNewSea else { continue }
            let original: [UInt8]
            if let where_ = byID[id] {
                let raw = try await source.source.read(offset: source.header.tileDataOffset + where_.offset, length: where_.length)
                original = try PMTilesGzip.unpacked(raw, compression: source.header.tileCompression)
            } else if let sea {
                original = sea
            } else {
                fail("\(url.lastPathComponent)'s square \(square) is neither the source's nor sea level")
            }
            guard Array(written) == original else { fail("\(url.lastPathComponent) differs at square \(square)") }
            guard let file = try? ElevationSquareFile(decoding: written),
                  file.rows == ElevationSquareGrid.rowsPerSquare,
                  file.columns == ElevationSquareGrid.columnsPerSquare(row: square.row)
            else { fail("\(url.lastPathComponent)'s square \(square) is no square the app reads at its size") }
            guard byID[id] != nil || file.isSeaLevel else { fail("\(url.lastPathComponent)'s sea at \(square) is not at sea level") }
            checked += 1
            if let server, (checked - 1) % serverStep == 0, asked < serverCheckedElevationSquares {
                let tileURL = server.appending(path: "\(tile.zoom)/\(tile.x)/\(tile.y).\(SquareArchive.tileExtension)")
                switch await servedSquare(tileURL) {
                case .some(.some(let bytes)) where bytes == original: break
                case .some(.none) where byID[id] == nil: break
                case .some: fail("\(tileURL) differs from \(url.lastPathComponent)")
                case .none: fail("\(tileURL) did not answer, asked \(serverAttempts) times")
                }
                asked += 1
            }
        }
        print("  read back \(checked) of \(squares.count) squares\(server == nil ? "" : ", \(asked) of them against the server")")
    }

    /// `elevation --manifest <manifest.json> --elevation <archive>
    /// --elevation-name <name> --out <dir>` with the outlines `build` takes:
    /// the heights of every area `manifest` lists, or those `--only` names,
    /// cut along the outline its map was cut along and named for the build
    /// it lists them at, into `<dir>` with a manifest of those areas, each
    /// with the file added in place of any it had. What brings the squares
    /// to builds already up, which `upload` then puts beside them.
    static func elevation(_ options: Options) async throws {
        guard let source = try await elevationSource(options) else { fail("elevation needs --elevation") }
        let server = options.optional("server").flatMap(URL.init(string:))
        try await addToListed(options, role: .elevation) { country, rings, output in
            try await cutElevation(id: country.id, rings: rings, build: country.build, from: source, into: output, server: server)
        }
    }

    /// The elevation archive `--elevation` names, as `--elevation-name` on
    /// the tile server, with `--elevation-margin-km` round each area, or
    /// `nil` where no archive is named.
    static func elevationSource(_ options: Options) async throws -> ElevationSource? {
        guard let path = options.optional("elevation") else { return nil }
        let extractor = try await Extractor(source: openSource(path))
        guard Int(extractor.header.minimumZoom) == SquareArchive.elevation.zoom,
              Int(extractor.header.maximumZoom) == SquareArchive.elevation.zoom
        else {
            fail("\(path) is zooms \(extractor.header.minimumZoom)–\(extractor.header.maximumZoom), not the elevation archive's \(SquareArchive.elevation.zoom)")
        }
        let name = options.required("elevation-name")
        guard SquareArchive.elevation.isArchiveName(name) else { fail("\(name) is no name of an elevation archive") }
        let margin = Double(options.optional("elevation-margin-km") ?? "") ?? ElevationSquares.defaultMarginKilometers
        return ElevationSource(
            extractor: extractor,
            name: name,
            marginKilometers: margin,
            metadata: try await extractor.metadata()
        )
    }
}
