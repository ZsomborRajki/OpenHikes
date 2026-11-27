//
//  SelfTest.swift
//  offline-countries
//
//  `selftest`: a made-up world archive, deep enough to need leaf directories,
//  cut along a square and read back through the app's reader. What
//  Scripts/run-script-tests.sh runs, so the tool is held to the app's files
//  it compiles.
//

import Foundation

extension Tool {
    static func selfTest() async throws {
        // The format's own examples for the curve.
        let examples: [((Int, Int, Int), UInt64)] = [
            ((0, 0, 0), 0), ((1, 0, 0), 1), ((1, 0, 1), 2), ((1, 1, 1), 3), ((1, 1, 0), 4),
            ((2, 0, 0), 5), ((12, 3423, 1763), 19_078_479),
        ]
        for ((z, x, y), id) in examples where PMTilesTileID.id(z: z, x: x, y: y) != id {
            fail("tile \(z)/\(x)/\(y) has id \(PMTilesTileID.id(z: z, x: x, y: y)), not \(id)")
        }

        let directory = FileManager.default.temporaryDirectory.appending(path: "offline-countries-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Every tile of zooms 0 to 7, each holding its own address, except the
        // sea: a quarter of the world, all one tile, written once.
        let maximumZoom = 7
        var tiles: [(id: UInt64, bytes: [UInt8])] = []
        for zoom in 0...maximumZoom {
            for x in 0..<1 << zoom {
                for y in 0..<1 << zoom {
                    let sea = zoom >= 3 && x < 1 << (zoom - 1) && y >= 1 << (zoom - 1)
                    tiles.append((PMTilesTileID.id(z: zoom, x: x, y: y), Array((sea ? "sea" : "\(zoom)/\(x)/\(y)").utf8)))
                }
            }
        }
        tiles.sort { $0.id < $1.id }
        var data: [UInt8] = []
        var entries: [PMTilesEntry] = []
        var sea: UInt64?
        for tile in tiles {
            let isSea = tile.bytes == Array("sea".utf8)
            let offset: UInt64
            if isSea, let written = sea {
                offset = written
            } else {
                offset = UInt64(data.count)
                data += tile.bytes
                if isSea { sea = offset }
            }
            entries.append(PMTilesEntry(tileID: tile.id, offset: offset, length: UInt64(tile.bytes.count), runLength: 1))
        }
        var header = PMTilesHeader()
        header.maximumZoom = UInt8(maximumZoom)
        header.tileType = 1
        let world = directory.appending(path: "world.pmtiles")
        let prefix = PMTilesLayout.prefix(header: header, entries: entries, metadata: Array("{}".utf8),
                                          tileDataLength: UInt64(data.count))
        try Data(prefix + data).write(to: world)
        guard PMTilesLayout.directories(for: entries).leaves.count > 0 else { fail("the world needed no leaves") }

        // A square over the Alps, cut with a margin, and read back.
        let ring: Ring = [(9.5, 46.4), (17.2, 46.4), (17.2, 49.0), (9.5, 49.0), (9.5, 46.4)]
        let coverage = TileCoverage(rings: [ring], marginKilometers: 3, maximumZoom: maximumZoom)
        let wanted = coverage.tiles()
        let extractor = try await Extractor(source: FileSource(url: world))
        let located = try await extractor.locate(wanted.map { PMTilesTileID.id(z: $0.z, x: $0.x, y: $0.y) }.sorted())
        guard located.count == wanted.count else { fail("located \(located.count) of \(wanted.count) tiles") }
        let cut = directory.appending(path: "cut.pmtiles")
        _ = try await extractor.write(located, to: cut, header: header, metadata: Array("{}".utf8))
        let archive = try PMTilesArchive(contentsOf: cut)
        for tile in wanted {
            guard let bytes = try archive.tile(z: tile.z, x: tile.x, y: tile.y),
                  String(decoding: bytes, as: UTF8.self) == "\(tile.z)/\(tile.x)/\(tile.y)"
            else { fail("the cut has the wrong bytes at \(tile)") }
        }
        guard try archive.tile(z: maximumZoom, x: 0, y: 0) == nil else { fail("the cut kept a tile it should not") }
        guard archive.header.isClustered else { fail("the cut is not clustered") }
        try checkAreas()
        let squares = try await checkTrails(in: directory)
        checkEdges()
        let heights = try await checkElevationCut(in: directory)
        print("""
        offline-countries: selftest passed (\(wanted.count) tiles cut, \(tiles.count) in the world, \
        \(squares) squares, \(heights) squares of heights)
        """)
    }

    /// The day hikes: a made-up trails archive with routes in three squares
    /// round Ljubljana and one in Brazil, cut along a square of Slovenia with
    /// a margin. Every square within it is read back, the three with their
    /// routes and the rest empty, and neither Brazil's nor one past the
    /// margin is there. And the margin goes on round the antimeridian, and
    /// round the pole.
    static func checkTrails(in directory: URL) async throws -> Int {
        func route(_ id: Int64) -> TrailCellFile {
            let point = TrailCellFile.Point(latitude: 46_000_000, longitude: 14_500_000)
            return TrailCellFile(relations: [
                TrailCellFile.Relation(id: id, tags: ["route": "hiking"], ways: [TrailCellFile.Way(role: "", points: [point])]),
            ])
        }
        let routed: [TrailCell: TrailCellFile] = [
            TrailCellGrid.cell(containingLatitude: 46.05, longitude: 14.5): route(1),
            TrailCellGrid.cell(containingLatitude: 46.3, longitude: 14.1): route(2),
            TrailCellGrid.cell(containingLatitude: 45.6, longitude: 13.6): route(3),
            TrailCellGrid.cell(containingLatitude: -22.9, longitude: -43.2): route(4),
        ]
        var tiles: [(id: UInt64, bytes: [UInt8])] = []
        for (square, file) in routed {
            guard let tile = SquareArchive.trails.tile(named: TrailCellGrid.recordName(for: square)) else {
                fail("square \(square) is no tile")
            }
            tiles.append((PMTilesTileID.id(z: tile.zoom, x: tile.x, y: tile.y), Array(file.encoded())))
        }
        tiles.sort { $0.id < $1.id }
        var data: [UInt8] = []
        var entries: [PMTilesEntry] = []
        for tile in tiles {
            entries.append(PMTilesEntry(tileID: tile.id, offset: UInt64(data.count), length: UInt64(tile.bytes.count), runLength: 1))
            data += tile.bytes
        }
        var header = PMTilesHeader()
        header.minimumZoom = UInt8(SquareArchive.trails.zoom)
        header.maximumZoom = UInt8(SquareArchive.trails.zoom)
        let world = directory.appending(path: "trails-20261122-00.pmtiles")
        let prefix = PMTilesLayout.prefix(header: header, entries: entries, metadata: Array("{}".utf8),
                                          tileDataLength: UInt64(data.count))
        try Data(prefix + data).write(to: world)

        let slovenia: Ring = [(13.4, 45.5), (16.5, 45.5), (16.5, 46.8), (13.4, 46.8), (13.4, 45.5)]
        let margin = 30.0
        let source = TrailsSource(
            extractor: try await Extractor(source: FileSource(url: world)),
            name: "trails-20261122-00",
            marginKilometers: margin,
            metadata: Array("{}".utf8)
        )
        let file = try await cutTrails(id: "SI", rings: [slovenia], build: "20261117", from: source, into: directory, server: nil)
        guard file.role == .trails, file.path == "countries/SI-trails-20261117.pmtiles", file.hasSafeName else {
            fail("the day hikes are listed as \(file)")
        }
        let archive = try PMTilesArchive(contentsOf: directory.appending(path: file.fileName))
        let covered = TrailSquares.squares(rings: [slovenia], marginKilometers: margin)
        func read(_ square: TrailCell) throws -> TrailCellFile? {
            guard let tile = SquareArchive.trails.tile(named: TrailCellGrid.recordName(for: square)),
                  let bytes = try archive.tile(z: tile.zoom, x: tile.x, y: tile.y)
            else { return nil }
            return try TrailCellFile(decoding: bytes)
        }
        for square in covered {
            let expected = routed[square] ?? TrailCellFile(relations: [])
            guard try read(square) == expected else { fail("the day hikes read wrong at \(square)") }
        }
        // 13.4°E less 30 km, a quarter of a degree further, is past the margin.
        let beyond = TrailCellGrid.cell(containingLatitude: 46.0, longitude: 13.4 - 30 / (110 * cos(46 * Double.pi / 180)) - 0.3)
        for outside in [TrailCellGrid.cell(containingLatitude: -22.9, longitude: -43.2), beyond] where try read(outside) != nil {
            fail("the day hikes hold \(outside), outside the margin")
        }
        guard covered.count == Int(archive.header.addressedTiles) else { fail("the day hikes address other squares") }

        // A square on the antimeridian takes in squares on both sides of it,
        // and one by the pole takes in the whole of its row.
        let fiji = TrailSquares.squares(rings: [[(179.8, -17.0), (179.95, -17.0), (179.95, -16.8), (179.8, -17.0)]],
                                        marginKilometers: margin)
        guard fiji.contains(where: { $0.column == 0 }), fiji.contains(where: { $0.column == TrailCellGrid.columnCount - 1 }) else {
            fail("the margin does not go round the antimeridian")
        }
        let pole = TrailSquares.squares(rings: [[(10, 89.7), (10.2, 89.7), (10.2, 89.8), (10, 89.7)]], marginKilometers: margin)
        guard pole.filter({ $0.row == TrailCellGrid.rowCount - 1 }).count == TrailCellGrid.columnCount else {
            fail("the margin does not go round the pole")
        }
        return covered.count
    }

    /// An edge takes in every square it crosses: a sliver along 80°N, all of
    /// it south of its row's middle line and its ends sixteen columns
    /// apart, with no margin round it, still covers the squares between.
    static func checkEdges() {
        let sliver: Ring = [(10.0, 80.01), (12.0, 80.02), (10.0, 80.015)]
        let covered = Set(ElevationSquares.squares(rings: [sliver], marginKilometers: 0))
        for longitude in stride(from: 10.0, through: 12.0, by: 0.1) {
            let square = ElevationSquares.square(
                of: ElevationSquares.cover.square(containingLatitude: 80.01 + (longitude - 10) * 0.005, longitude: longitude)
            )
            guard covered.contains(square) else { fail("the cover leaves out \(square), which an edge crosses at \(longitude)° E") }
        }
    }

    /// The heights: a made-up elevation archive with two squares of land
    /// round Ljubljana, cut along a square of Slovenia with a margin, and
    /// along a square across 60°N with no land at all. Every square within
    /// each reads back at its row's size, the two as they were and the rest
    /// at sea level, which across 60°N is two sizes of square; and a square
    /// past the margin is not there.
    static func checkElevationCut(in directory: URL) async throws -> Int {
        func square(_ latitude: Double, _ longitude: Double) -> ElevationSquare {
            ElevationSquares.square(of: ElevationSquares.cover.square(containingLatitude: latitude, longitude: longitude))
        }
        func land(_ square: ElevationSquare, base: Int16) -> ElevationSquareFile {
            let rows = ElevationSquareGrid.rowsPerSquare
            let columns = ElevationSquareGrid.columnsPerSquare(row: square.row)
            let heights = (0..<rows * columns).map { base + Int16($0 % columns / 10) - Int16($0 / columns / 10) }
            return ElevationSquareFile(rows: rows, columns: columns, heights: heights)
        }
        let ljubljana = square(46.05, 14.5)
        let kamnik = square(46.22, 14.6)
        let landed = [ljubljana: land(ljubljana, base: 300), kamnik: land(kamnik, base: 900)]
        var tiles: [(id: UInt64, bytes: [UInt8])] = []
        for (square, file) in landed {
            guard let tile = SquareArchive.elevation.tile(named: ElevationSquareGrid.recordName(for: square)) else {
                fail("square \(square) is no tile")
            }
            tiles.append((PMTilesTileID.id(z: tile.zoom, x: tile.x, y: tile.y), Array(file.encoded())))
        }
        tiles.sort { $0.id < $1.id }
        var data: [UInt8] = []
        var entries: [PMTilesEntry] = []
        for tile in tiles {
            entries.append(PMTilesEntry(tileID: tile.id, offset: UInt64(data.count), length: UInt64(tile.bytes.count), runLength: 1))
            data += tile.bytes
        }
        var header = PMTilesHeader()
        header.minimumZoom = UInt8(SquareArchive.elevation.zoom)
        header.maximumZoom = UInt8(SquareArchive.elevation.zoom)
        let world = directory.appending(path: "elevation-20261126-20.pmtiles")
        let prefix = PMTilesLayout.prefix(header: header, entries: entries, metadata: Array("{}".utf8),
                                          tileDataLength: UInt64(data.count))
        try Data(prefix + data).write(to: world)

        let margin = 5.0
        let source = ElevationSource(
            extractor: try await Extractor(source: FileSource(url: world)),
            name: "elevation-20261126-20",
            marginKilometers: margin,
            metadata: Array("{}".utf8)
        )
        let slovenia: Ring = [(14.3, 45.9), (14.8, 45.9), (14.8, 46.3), (14.3, 46.3), (14.3, 45.9)]
        let sixty: Ring = [(5.0, 59.9), (5.2, 59.9), (5.2, 60.1), (5.0, 60.1), (5.0, 59.9)]
        var count = 0
        for (id, ring) in [("SI", slovenia), ("NO", sixty)] {
            let file = try await cutElevation(id: id, rings: [ring], build: "20261124", from: source, into: directory, server: nil)
            guard file.role == .elevation, file.path == "countries/\(id)-elevation-20261124.pmtiles", file.hasSafeName,
                  file.minimumZoom == SquareArchive.elevation.zoom
            else { fail("the heights are listed as \(file)") }
            let archive = try PMTilesArchive(contentsOf: directory.appending(path: file.fileName))
            let covered = ElevationSquares.squares(rings: [ring], marginKilometers: margin)
            guard covered.count == Int(archive.header.addressedTiles) else { fail("the heights of \(id) address other squares") }
            var sizes: Set<Int> = []
            for square in covered {
                guard let tile = SquareArchive.elevation.tile(named: ElevationSquareGrid.recordName(for: square)),
                      let bytes = try archive.tile(z: tile.zoom, x: tile.x, y: tile.y),
                      let read = try? ElevationSquareFile(decoding: bytes)
                else { fail("the heights of \(id) have no square \(square)") }
                let expected = landed[square] ?? ElevationSquares.seaLevel(row: square.row)
                guard read == expected else { fail("the heights of \(id) read wrong at \(square)") }
                sizes.insert(read.columns)
            }
            // 14.3°E less the margin, and a square further, is past it.
            let beyond = square(46.0, 14.3 - margin / (110 * cos(46 * Double.pi / 180)) - 0.13)
            if id == "SI", let tile = SquareArchive.elevation.tile(named: ElevationSquareGrid.recordName(for: beyond)),
               try archive.tile(z: tile.zoom, x: tile.x, y: tile.y) != nil {
                fail("the heights hold \(beyond), outside the margin")
            }
            if id == "SI", !covered.contains(ljubljana) || !covered.contains(kamnik) {
                fail("the heights of Slovenia leave out its land")
            }
            if id == "NO", sizes != [ElevationSquareGrid.columnsPerSquare(row: square(59.95, 5.1).row),
                                     ElevationSquareGrid.columnsPerSquare(row: square(60.05, 5.1).row)] {
                fail("the sea across 60°N is squares of \(sizes.sorted()) posts a row")
            }
            count += covered.count
        }
        return count
    }

    /// What is cut: a split country as its regions, a region filed under it
    /// whose code names another country in that country, an area with no
    /// code joined to the country the plan names and otherwise left out.
    static func checkAreas() throws {
        func square(_ west: Double, _ south: Double) -> [String: Any] {
            ["type": "Polygon", "coordinates": [[[west, south], [west + 1, south], [west + 1, south + 1], [west, south]]]]
        }
        func feature(_ properties: [String: Any], _ geometry: [String: Any]) -> [String: Any] {
            ["properties": properties, "geometry": geometry]
        }
        let countries = [
            feature(["ISO_A2_EH": "UA", "NAME": "Ukraine"], square(30, 48)),
            feature(["ISO_A2_EH": "RU", "NAME": "Russia"], square(40, 55)),
            feature(["ISO_A2_EH": "SO", "NAME": "Somalia"], square(45, 3)),
            feature(["ISO_A2_EH": "-99", "NAME": "Somaliland"], square(45, 9)),
            feature(["ISO_A2_EH": "-99", "NAME": "Siachen Glacier"], square(77, 35)),
        ]
        let regions = [
            feature(["iso_a2": "RU", "iso_3166_2": "RU-MOW", "name_en": "Moscow", "name_de": "Moskau"], square(37, 55)),
            feature(["iso_a2": "RU", "iso_3166_2": "UA-43", "name_en": "Crimea"], square(34, 45)),
            feature(["iso_a2": "RU", "iso_3166_2": "RU-X01~"], square(50, 70)),
            feature(["iso_a2": "FR", "iso_3166_2": "FR-75"], square(2, 48)),
        ]
        let areas = try Areas.all(
            plan: AreaPlan(split: ["RU"], attach: ["Somaliland": "SO"]),
            countries: countries,
            regions: regions
        )
        let byID = Dictionary(uniqueKeysWithValues: areas.map { ($0.id, $0) })
        guard areas.map(\.id) == ["RU-MOW", "SO", "UA"] else { fail("the areas are \(areas.map(\.id))") }
        guard byID["UA"]?.rings.count == 2 else { fail("Crimea is not in Ukraine") }
        guard byID["SO"]?.rings.count == 2 else { fail("Somaliland is not in Somalia") }
        guard let moscow = byID["RU-MOW"], moscow.group == "RU", moscow.names["de"] == "Moskau" else {
            fail("Moscow is not a region of Russia named in German")
        }
        guard byID["UA"]?.group == nil, byID["UA"]?.names.isEmpty == true else { fail("Ukraine is not a whole country") }
    }
}
