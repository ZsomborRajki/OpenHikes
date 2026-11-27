//
//  Trails.swift
//  offline-countries
//
//  An area's day hikes: the squares of the Community tab's trails archive
//  (`SquareArchive.trails`, one quarter-degree square of `TrailCellGrid` a
//  tile) that lie within a margin of the area's outline, copied out of the
//  archive the tile server lists, so a search there is answered on the device
//  with no signal.
//
//  **Copied, never rebuilt from an extract of the area.** A square of the
//  planet's build holds every route filed under it, whole, wherever the route
//  runs; one built from an extract would leave out a route that runs out of
//  the area, and nothing on screen would say so. So each square here is the
//  square the server sends.
//
//  **Every square the file covers is a tile of it.** The planet's archive has
//  no tile for a square with no routes, and the server answers it with a 204,
//  which the app reads as *nothing here* because the archive is the whole
//  world. A file of part of the world cannot say that by leaving a tile out,
//  so each square it covers that the archive has no tile for is written as an
//  empty `TrailCellFile`, the same few bytes for every one of them. A square
//  the file has no tile for is one it says nothing about, and the app asks
//  the server for it as it did before there were downloads.
//
//  **A wide margin**, much wider than the map's, because the squares are
//  small beside a map and a search near a border reaches over it: a search
//  of the map up to the margin, less the ten kilometres a search reads round
//  the map it is about (`TrailCellGrid.reachMeters`), from the outline is
//  answered from the file alone.
//

import Foundation

enum TrailSquares {
    /// How far round an area's outline its squares reach, in kilometres.
    static let defaultMarginKilometers = 50.0

    /// `TrailCellGrid`'s squares, whose rows run from the South Pole as the
    /// cover's do.
    static let cover = SquareCover(perDegree: TrailCellGrid.cellsPerDegree)

    /// Every square with its middle inside `rings`, every square an edge of
    /// them passes through, and every square within `marginKilometers` of
    /// those.
    static func squares(rings: [Ring], marginKilometers: Double) -> [TrailCell] {
        cover.squares(rings: rings, marginKilometers: marginKilometers).map { TrailCell(row: $0.row, column: $0.column) }
    }

    /// West, south, east and north of `squares`, in degrees: the whole width
    /// of the world where they wrap round the antimeridian.
    static func bounds(of squares: [TrailCell]) -> (west: Double, south: Double, east: Double, north: Double) {
        cover.bounds(of: squares.map { SquareCover.Square(row: $0.row, column: $0.column) })
    }
}

// MARK: - Cutting

/// The trails archive an area's squares are copied from.
struct TrailsSource {
    let extractor: Extractor
    /// Its name on the tile server, which its squares are read back from.
    let name: String
    let marginKilometers: Double
    let metadata: [UInt8]
}

extension Tool {
    /// How many of an area's squares are also asked of the tile server, when
    /// one is named.
    static let serverCheckedSquares = 12

    /// Cuts the squares of `rings` out of `trails` into `<id>-trails-<build>`,
    /// reads every one back through the app's reader against the source, and
    /// returns the file as the manifest lists it.
    static func cutTrails(
        id: String,
        rings: [Ring],
        build: String,
        from trails: TrailsSource,
        into output: URL,
        server: URL?
    ) async throws -> OfflineCountryManifest.File {
        let source = trails.extractor
        guard source.header.tileCompression == PMTilesCompression.uncompressed.rawValue else {
            fail("\(trails.name)'s tiles are packed (\(source.header.tileCompression)); an empty square is written as it is")
        }
        let squares = TrailSquares.squares(rings: rings, marginKilometers: trails.marginKilometers)
        var tiles: [UInt64: TrailCell] = [:]
        for square in squares {
            guard let tile = SquareArchive.trails.tile(named: TrailCellGrid.recordName(for: square)) else {
                fail("square \(square) of \(id) is no tile of the trails archive")
            }
            tiles[PMTilesTileID.id(z: tile.zoom, x: tile.x, y: tile.y)] = square
        }
        let ids = tiles.keys.sorted()
        let located = try await source.locate(ids)
        let zoom = SquareArchive.trails.zoom
        let bounds = TrailSquares.bounds(of: squares)
        var header = PMTilesHeader()
        header.minimumZoom = UInt8(zoom)
        header.maximumZoom = UInt8(zoom)
        header.bounds = [bounds.west, bounds.south, bounds.east, bounds.north].map { Int32(($0 * 1e7).rounded()) }
        header.center = [(bounds.west + bounds.east) / 2, (bounds.south + bounds.north) / 2]
            .map { Int32(($0 * 1e7).rounded()) }
        header.centerZoom = UInt8(zoom)
        let empty = Array(TrailCellFile(relations: []).encoded())
        let name = "\(id)-trails-\(build).pmtiles"
        let url = output.appending(path: name)
        let written = try await source.write(
            located,
            filling: Dictionary(uniqueKeysWithValues: ids.map { ($0, empty) }),
            to: url,
            header: header,
            metadata: labeled(trails.metadata, country: id, build: build, source: trails.name)
        )
        print("  \(name): \(written.addressed) squares, \(located.count) with routes, \(written.bytes) bytes")
        try await checkTrails(url, squares: tiles, against: source, located: located, empty: empty, server: server.map {
            $0.appending(path: trails.name)
        })
        return OfflineCountryManifest.File(
            role: .trails,
            path: "countries/\(name)",
            byteCount: Int64(written.bytes),
            sha256: try sha256(of: url),
            minimumZoom: zoom,
            maximumZoom: zoom
        )
    }

    /// Reads every square of the written file back through the app's own
    /// reader: each the source's bytes, or the empty square where the source
    /// has none, each a file the app reads, and no tile besides. A few are
    /// held to the tile server's answer too, a 204 for an empty one.
    static func checkTrails(
        _ url: URL,
        squares: [UInt64: TrailCell],
        against source: Extractor,
        located: [LocatedTile],
        empty: [UInt8],
        server: URL?
    ) async throws {
        let archive = try PMTilesArchive(contentsOf: url)
        guard archive.header.addressedTiles == UInt64(squares.count) else {
            fail("\(url.lastPathComponent) addresses \(archive.header.addressedTiles) squares, not \(squares.count)")
        }
        let byID = Dictionary(located.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let step = max(squares.count / serverCheckedSquares, 1)
        var asked = 0
        for (index, (id, square)) in squares.sorted(by: { $0.key < $1.key }).enumerated() {
            guard let tile = SquareArchive.trails.tile(named: TrailCellGrid.recordName(for: square)),
                  let written = try archive.tile(z: tile.zoom, x: tile.x, y: tile.y)
            else { fail("\(url.lastPathComponent) has no tile for square \(square)") }
            var original = empty
            if let where_ = byID[id] {
                let raw = try await source.source.read(offset: source.header.tileDataOffset + where_.offset, length: where_.length)
                original = try PMTilesGzip.unpacked(raw, compression: source.header.tileCompression)
            }
            guard Array(written) == original else { fail("\(url.lastPathComponent) differs at square \(square)") }
            guard (try? TrailCellFile(decoding: written)) != nil else {
                fail("\(url.lastPathComponent)'s square \(square) is no file the app reads")
            }
            if let server, index % step == 0, asked < serverCheckedSquares {
                let tileURL = server.appending(path: "\(tile.zoom)/\(tile.x)/\(tile.y).\(SquareArchive.tileExtension)")
                let served = await servedSquare(tileURL)
                switch served {
                case .some(.some(let bytes)) where bytes == original: break
                case .some(.none) where byID[id] == nil: break
                case .some: fail("\(tileURL) differs from \(url.lastPathComponent)")
                case .none: fail("\(tileURL) did not answer, asked \(serverAttempts) times")
                }
                asked += 1
            }
        }
        print("  read back \(squares.count) squares\(server == nil ? "" : ", \(asked) of them against the server")")
    }

    /// The tile server's answer for a square: its bytes for a 200, `.some(nil)`
    /// for a 204, and `nil` where it gave neither after a few tries.
    static func servedSquare(_ url: URL) async -> [UInt8]?? {
        for attempt in 1...serverAttempts {
            if let (data, response) = try? await URLSession.shared.data(from: url),
               let status = (response as? HTTPURLResponse)?.statusCode {
                if status == 200 { return .some(Array(data)) }
                if status == 204 { return .some(nil) }
            }
            try? await Task.sleep(for: .seconds(attempt))
        }
        return nil
    }

    /// `trails --manifest <manifest.json> --trails <archive> --trails-name
    /// <name> --out <dir>` with the outlines `build` takes: the day hikes of
    /// every area `manifest` lists, or those `--only` names, cut along the
    /// outline its map was cut along and named for the build it lists them
    /// at, into `<dir>` with a manifest of those areas, each with the file
    /// added in place of any it had. What brings the squares to builds
    /// already up, which `upload` then puts beside them.
    static func trails(_ options: Options) async throws {
        guard let source = try await trailsSource(options) else { fail("trails needs --trails") }
        let server = options.optional("server").flatMap(URL.init(string:))
        try await addToListed(options, role: .trails) { country, rings, output in
            try await cutTrails(id: country.id, rings: rings, build: country.build, from: source, into: output, server: server)
        }
    }

    /// The trails archive `--trails` names, as `--trails-name` on the tile
    /// server, with `--trails-margin-km` round each area, or `nil` where no
    /// archive is named.
    static func trailsSource(_ options: Options) async throws -> TrailsSource? {
        guard let path = options.optional("trails") else { return nil }
        let extractor = try await Extractor(source: openSource(path))
        guard Int(extractor.header.minimumZoom) == SquareArchive.trails.zoom,
              Int(extractor.header.maximumZoom) == SquareArchive.trails.zoom
        else {
            fail("\(path) is zooms \(extractor.header.minimumZoom)–\(extractor.header.maximumZoom), not the trails archive's \(SquareArchive.trails.zoom)")
        }
        let name = options.required("trails-name")
        guard SquareArchive.trails.isArchiveName(name) else { fail("\(name) is no name of a trails archive") }
        let margin = Double(options.optional("trails-margin-km") ?? "") ?? TrailSquares.defaultMarginKilometers
        return TrailsSource(
            extractor: extractor,
            name: name,
            marginKilometers: margin,
            metadata: try await extractor.metadata()
        )
    }
}
