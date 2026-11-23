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

    /// Kilometres in a degree, rounded down from the least a degree is, so a
    /// margin counted in squares is never short of the one asked for.
    private static let kilometersPerDegree = 110.0
    /// The smallest cosine a margin across longitudes is divided by, which
    /// only keeps the arithmetic finite: at a pole the margin takes in
    /// every column. (`TrailCellGrid` divides by a far larger one, and a
    /// search that near a pole reads too many squares to be answered.)
    private static let minimumCosine = 1e-9

    private static var squareKilometers: Double { kilometersPerDegree / Double(TrailCellGrid.cellsPerDegree) }

    /// Every square with its middle inside `rings`, every square a vertex of
    /// them is in, and every square within `marginKilometers` of those.
    static func squares(rings: [Ring], marginKilometers: Double) -> [TrailCell] {
        let rows = grown(inside(rings), by: marginKilometers)
        return rows.keys.sorted().flatMap { row in
            (rows[row] ?? []).flatMap { run in run.map { TrailCell(row: row, column: $0) } }
        }
    }

    /// The squares `rings` cover, as runs of columns along each row.
    static func inside(_ rings: [Ring]) -> [Int: [ClosedRange<Int>]] {
        let perDegree = Double(TrailCellGrid.cellsPerDegree)
        var runs: [Int: [ClosedRange<Int>]] = [:]
        let latitudes = rings.flatMap { $0.map(\.lat) }
        guard let south = latitudes.min(), let north = latitudes.max() else { return [:] }
        let first = TrailCellGrid.cell(containingLatitude: south, longitude: 0).row
        let last = TrailCellGrid.cell(containingLatitude: north, longitude: 0).row
        for row in first...last {
            let latitude = (Double(row) + 0.5) / perDegree - 90
            var crossings: [Double] = []
            for ring in rings {
                for (index, vertex) in ring.enumerated() {
                    let previous = ring[index == 0 ? ring.count - 1 : index - 1]
                    guard (previous.lat > latitude) != (vertex.lat > latitude) else { continue }
                    let along = (latitude - previous.lat) / (vertex.lat - previous.lat)
                    crossings.append(previous.lon + along * (vertex.lon - previous.lon))
                }
            }
            crossings.sort()
            for pair in stride(from: 0, to: crossings.count - 1, by: 2) {
                // The columns whose middles fall between the two crossings.
                let west = Int(((crossings[pair] + 180) * perDegree - 0.5).rounded(.up))
                let east = Int(((crossings[pair + 1] + 180) * perDegree - 0.5).rounded(.down))
                if west <= east { runs[row, default: []].append(west...east) }
            }
        }
        // Every vertex's own square, so a sliver no square's middle falls in
        // is still there.
        for vertex in rings.joined() {
            let cell = TrailCellGrid.cell(containingLatitude: vertex.lat, longitude: vertex.lon)
            runs[cell.row, default: []].append(cell.column...cell.column)
        }
        return runs.mapValues(TileCoverage.merged)
    }

    /// `rows` grown by `marginKilometers` each way: rows by the square's
    /// height, columns by its width at the poleward edge of either row, the
    /// narrowest it is there, and round the antimeridian.
    static func grown(_ rows: [Int: [ClosedRange<Int>]], by marginKilometers: Double) -> [Int: [ClosedRange<Int>]] {
        let columns = TrailCellGrid.columnCount
        let rowReach = Int((marginKilometers / squareKilometers).rounded(.up))
        var grown: [Int: [ClosedRange<Int>]] = [:]
        for (row, runs) in rows {
            let targets = max(row - rowReach, 0)...min(row + rowReach, TrailCellGrid.rowCount - 1)
            for target in targets {
                let poleward = max(abs(edgeLatitude(of: min(row, target))), abs(edgeLatitude(of: max(row, target) + 1)))
                let cosine = max(cos(poleward * .pi / 180), minimumCosine)
                let reach = Int(min((marginKilometers / (squareKilometers * cosine)).rounded(.up), Double(columns)))
                for run in runs {
                    let west = run.lowerBound - reach
                    let east = run.upperBound + reach
                    guard east - west + 1 < columns else {
                        grown[target, default: []].append(0...(columns - 1))
                        continue
                    }
                    // Round the antimeridian: a run past either end of the
                    // grid goes on from the other.
                    let wrappedWest = (west % columns + columns) % columns
                    let wrappedEast = wrappedWest + (east - west)
                    if wrappedEast < columns {
                        grown[target, default: []].append(wrappedWest...wrappedEast)
                    } else {
                        grown[target, default: []].append(wrappedWest...(columns - 1))
                        grown[target, default: []].append(0...(wrappedEast - columns))
                    }
                }
            }
        }
        return grown.mapValues(TileCoverage.merged)
    }

    /// The latitude of a row's southern edge.
    private static func edgeLatitude(of row: Int) -> Double {
        Double(row) / Double(TrailCellGrid.cellsPerDegree) - 90
    }

    /// West, south, east and north of `squares`, in degrees: the whole width
    /// of the world where they wrap round the antimeridian.
    static func bounds(of squares: [TrailCell]) -> (west: Double, south: Double, east: Double, north: Double) {
        let perDegree = Double(TrailCellGrid.cellsPerDegree)
        let rows = squares.map(\.row)
        let columns = squares.map(\.column)
        let south = Double(rows.min() ?? 0) / perDegree - 90
        let north = Double((rows.max() ?? 0) + 1) / perDegree - 90
        let wraps = columns.contains(0) && columns.contains(TrailCellGrid.columnCount - 1)
        let west = wraps ? -180 : Double(columns.min() ?? 0) / perDegree - 180
        let east = wraps ? 180 : Double((columns.max() ?? 0) + 1) / perDegree - 180
        return (west, south, east, north)
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
            filling: ids,
            with: empty,
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
    /// <name> --out <dir>`: the day hikes of every area `manifest` lists, or
    /// those `--only` names, cut along the outline it lists them with and
    /// named for the build it lists them at, into `<dir>` with a manifest of
    /// those areas, each with the file added in place of any it had. What
    /// brings the squares to builds already up, which `upload` then puts
    /// beside them.
    static func trails(_ options: Options) async throws {
        let listed = try JSONDecoder().decode(
            OfflineCountryManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: options.required("manifest")))
        )
        guard let source = try await trailsSource(options) else { fail("trails needs --trails") }
        let output = URL(fileURLWithPath: options.required("out"), isDirectory: true)
        let server = options.optional("server").flatMap(URL.init(string:))
        var countries = listed.countries
        if let only = options.optional("only") {
            let wanted = Set(only.split(separator: ",").map(String.init))
            countries = countries.filter { wanted.contains($0.id) || $0.group.map(wanted.contains) == true }
        }
        guard !countries.isEmpty else { fail("no areas to cut") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manifestURL = output.appending(path: "manifest.json")
        var manifest = OfflineCountryManifest(version: listed.version, countries: [])
        for (index, listedCountry) in countries.enumerated() {
            print("[\(index + 1)/\(countries.count)] \(listedCountry.id), build \(listedCountry.build)")
            var country = listedCountry
            let rings = country.outline.map { ring in ring.compactMap { $0.count >= 2 ? (lon: $0[0], lat: $0[1]) : nil } }
            let file = try await cutTrails(
                id: country.id, rings: rings, build: country.build, from: source, into: output, server: server
            )
            country.files.removeAll { $0.role == .trails }
            country.files.append(file)
            manifest.countries.append(country)
            try write(manifest, to: manifestURL)
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
