//
//  Tool.swift
//  offline-countries
//
//  The countries the app downloads, cut out of the planet build the OpenHikes
//  map draws: `Scripts/offline-countries.sh` is the way in and says how.
//
//    build      cut each country's basemap and extras, read them back against
//               the source, and write the manifest beside them
//    merge      put a build's manifest into the one the server has
//    files      list a manifest's files and their sizes, for the upload
//    inspect    print an archive's header
//    selftest   cut a made-up archive and read it back (Scripts/run-script-tests.sh)
//

import Foundation

@main
struct Tool {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else { fail("no command") }
        let command = arguments.removeFirst()
        do {
            switch command {
            case "build": try await build(Options(arguments))
            case "merge": try merge(Options(arguments))
            case "files": try files(Options(arguments))
            case "inspect": try inspect(Options(arguments))
            case "selftest": try await selfTest()
            default: fail("unknown command \(command)")
            }
        } catch {
            fail("\(error)")
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("offline-countries: \(message)\n".utf8))
        exit(1)
    }
}

/// `--name value` pairs and the words between them.
struct Options {
    private var values: [String: String] = [:]
    private(set) var words: [String] = []

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--"), index + 1 < arguments.count {
                values[String(argument.dropFirst(2))] = arguments[index + 1]
                index += 2
            } else {
                words.append(argument)
                index += 1
            }
        }
    }

    func required(_ name: String) -> String {
        guard let value = values[name] else { Tool.fail("--\(name) is required") }
        return value
    }

    func optional(_ name: String) -> String? { values[name] }
}

// MARK: - build

extension Tool {
    /// How many tiles of each country are read back against the source.
    static let checkedTiles = 400
    /// How many of those are also asked of the tile server, when one is named.
    static let serverCheckedTiles = 12
    /// Douglas–Peucker tolerance for the outline the manifest carries: about
    /// half a kilometre, which the map draws at country zooms.
    static let outlineTolerance = 0.005

    /// The deepest zoom of the files every download takes. The planet's own
    /// deepest, a zoom further, is the *Extra Detail* files'.
    static let baseZoom = 14
    static let detailZoom = 15

    static func build(_ options: Options) async throws {
        let planet = try await Extractor(source: openSource(options.required("planet")))
        let extras = try await Extractor(source: openSource(options.required("extras")))
        guard Int(planet.header.maximumZoom) == detailZoom else {
            fail("the planet goes to zoom \(planet.header.maximumZoom), and the detail files are zoom \(detailZoom)")
        }
        let build = options.required("build")
        let output = URL(fileURLWithPath: options.required("out"), isDirectory: true)
        let margin = Double(options.optional("margin-km") ?? "3") ?? 3
        let server = options.optional("server").flatMap(URL.init(string:))
        let plan = try JSONDecoder().decode(
            AreaPlan.self,
            from: Data(contentsOf: URL(fileURLWithPath: options.required("countries")))
        )
        var choices = try Areas.all(
            plan: plan,
            countries: Outlines.features(at: URL(fileURLWithPath: options.required("outlines"))),
            regions: Outlines.features(at: URL(fileURLWithPath: options.required("regions")))
        )
        if let only = options.optional("only") {
            // An area by its code, or every region of a split country by its.
            let wanted = Set(only.split(separator: ",").map(String.init))
            choices = choices.filter { wanted.contains($0.id) || $0.group.map(wanted.contains) == true }
        }
        guard !choices.isEmpty else { fail("no areas to build") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manifestURL = output.appending(path: "manifest.json")
        var manifest = (try? JSONDecoder().decode(OfflineCountryManifest.self, from: Data(contentsOf: manifestURL)))
            ?? OfflineCountryManifest(version: OfflineCountryManifest.currentVersion, countries: [])
        let metadata = try await planet.metadata()
        let extrasMetadata = try await extras.metadata()
        for (index, choice) in choices.enumerated() {
            print("[\(index + 1)/\(choices.count)] \(choice.id)")
            let country = try await cut(
                choice,
                Cut(
                    planet: planet, extras: extras, build: build, output: output,
                    margin: margin, server: server, metadata: metadata, extrasMetadata: extrasMetadata
                )
            )
            manifest.countries.removeAll { $0.id == country.id && $0.build == country.build }
            manifest.countries.append(country)
            manifest.countries.sort { ($0.id, $0.build) < ($1.id, $1.build) }
            try write(manifest, to: manifestURL)
        }
    }

    struct Cut {
        let planet: Extractor
        let extras: Extractor
        let build: String
        let output: URL
        let margin: Double
        let server: URL?
        let metadata: [UInt8]
        let extrasMetadata: [UInt8]
    }

    /// The four files of an area: which archive each is cut from, between
    /// which zooms, and what goes between the area's code and the build in
    /// its name.
    static func parts(of cut: Cut) -> [(OfflineCountryManifest.Role, Extractor, ClosedRange<Int>, [UInt8], String)] {
        let extrasZoom = Int(cut.extras.header.minimumZoom)
        return [
            (.basemap, cut.planet, 0...baseZoom, cut.metadata, ""),
            (.extras, cut.extras, extrasZoom...baseZoom, cut.extrasMetadata, "extras-"),
            (.detail, cut.planet, detailZoom...detailZoom, cut.metadata, "detail-"),
            (.detailExtras, cut.extras, detailZoom...detailZoom, cut.extrasMetadata, "detail-extras-"),
        ]
    }

    static func cut(_ choice: AreaChoice, _ cut: Cut) async throws -> OfflineCountryManifest.Country {
        let rings = choice.rings
        let coverage = TileCoverage(rings: rings, marginKilometers: cut.margin, maximumZoom: detailZoom)
        let tiles = coverage.tiles()
        print("\(choice.id): \(tiles.count) tiles, \(coverage.count(atZoom: detailZoom)) at zoom \(detailZoom)")
        let bounds = coverage.bounds
        var files: [OfflineCountryManifest.File] = []
        for (role, source, zooms, metadata, infix) in parts(of: cut) {
            let name = "\(choice.id)-\(infix)\(cut.build).pmtiles"
            let url = cut.output.appending(path: name)
            let chosen = tiles.filter { zooms.contains($0.z) }
            let ids = chosen.map { PMTilesTileID.id(z: $0.z, x: $0.x, y: $0.y) }.sorted()
            let located = try await source.locate(ids)
            var header = PMTilesHeader()
            header.minimumZoom = UInt8(zooms.lowerBound)
            header.maximumZoom = UInt8(zooms.upperBound)
            header.bounds = [bounds.west, bounds.south, bounds.east, bounds.north].map { Int32(($0 * 1e7).rounded()) }
            header.center = [(bounds.west + bounds.east) / 2, (bounds.south + bounds.north) / 2]
                .map { Int32(($0 * 1e7).rounded()) }
            header.centerZoom = UInt8(min(7, zooms.upperBound))
            let written = try await source.write(
                located,
                to: url,
                header: header,
                metadata: labeled(metadata, country: choice.id, build: cut.build)
            )
            print("  \(name): \(written.addressed) tiles, \(written.contents) distinct, \(written.bytes) bytes")
            let checksServer = role == .basemap || role == .detail
            try await check(url, against: source, located: located, sample: chosen, server: checksServer ? cut.server : nil)
            files.append(
                OfflineCountryManifest.File(
                    role: role,
                    path: "countries/\(name)",
                    byteCount: Int64(written.bytes),
                    sha256: try sha256(of: url),
                    minimumZoom: zooms.lowerBound,
                    maximumZoom: zooms.upperBound
                )
            )
        }
        return OfflineCountryManifest.Country(
            id: choice.id,
            group: choice.group,
            names: choice.names,
            build: cut.build,
            schema: OfflineCountryManifest.readableSchema,
            bounds: OfflineCountryManifest.Bounds(
                west: bounds.west, south: bounds.south, east: bounds.east, north: bounds.north
            ),
            outline: rings.compactMap { Outlines.simplified($0, tolerance: outlineTolerance) },
            files: files
        )
    }

    /// The source's metadata, saying which country and build it was cut for.
    static func labeled(_ metadata: [UInt8], country: String, build: String) throws -> [UInt8] {
        var object = (try JSONSerialization.jsonObject(with: Data(metadata)) as? [String: Any]) ?? [:]
        object["openhikes"] = ["country": country, "build": build]
        return Array(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    /// Reads tiles of the written archive back through the app's own reader,
    /// and holds them to the source's bytes and, for a few, to the tile
    /// server's.
    static func check(
        _ url: URL,
        against source: Extractor,
        located: [LocatedTile],
        sample tiles: [(z: Int, x: Int, y: Int)],
        server: URL?
    ) async throws {
        let archive = try PMTilesArchive(contentsOf: url)
        let byID = Dictionary(located.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let step = max(tiles.count / checkedTiles, 1)
        var checked = 0
        for index in stride(from: 0, to: tiles.count, by: step) {
            let tile = tiles[index]
            let written = try archive.tile(z: tile.z, x: tile.x, y: tile.y)
            guard let where_ = byID[PMTilesTileID.id(z: tile.z, x: tile.x, y: tile.y)] else {
                guard written == nil else { fail("\(url.lastPathComponent) has \(tile) the source does not") }
                continue
            }
            let raw = try await source.source.read(offset: source.header.tileDataOffset + where_.offset, length: where_.length)
            let original = try PMTilesGzip.unpacked(raw, compression: source.header.tileCompression)
            guard written.map(Array.init) == original else { fail("\(url.lastPathComponent) differs at \(tile)") }
            if let server, checked < serverCheckedTiles {
                let tileURL = server.appending(path: "\(tile.z)/\(tile.x)/\(tile.y).mvt")
                let (served, _) = try await URLSession.shared.data(from: tileURL)
                guard Array(served) == original else { fail("\(tileURL) differs from \(url.lastPathComponent)") }
            }
            checked += 1
        }
        print("  read back \(checked) tiles\(server == nil ? "" : ", \(min(checked, serverCheckedTiles)) of them against the server")")
    }

    static func write(_ manifest: OfflineCountryManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }
}

// MARK: - merge and inspect

extension Tool {
    /// `merge --server <manifest.json> --build <manifest.json> --out <file>`:
    /// the server's manifest with every country of the build's put in it,
    /// replacing the same country of an older build, which an installed app
    /// then offers as an update.
    static func merge(_ options: Options) throws {
        let decoder = JSONDecoder()
        let built = try decoder.decode(
            OfflineCountryManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: options.required("build")))
        )
        let serverPath = options.required("server")
        var merged = (try? decoder.decode(OfflineCountryManifest.self, from: Data(contentsOf: URL(fileURLWithPath: serverPath))))
            ?? OfflineCountryManifest(version: OfflineCountryManifest.currentVersion, countries: [])
        for country in built.countries {
            merged.countries.removeAll { $0.id == country.id }
            merged.countries.append(country)
        }
        merged.countries.sort { $0.id < $1.id }
        try write(merged, to: URL(fileURLWithPath: options.required("out")))
        print("offline-countries: \(merged.countries.count) countries in the merged manifest")
    }

    /// `files <manifest.json>`: each file's path, size and SHA-256, a line
    /// each.
    static func files(_ options: Options) throws {
        guard let path = options.words.first else { fail("files needs a manifest") }
        let manifest = try JSONDecoder().decode(OfflineCountryManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for file in manifest.countries.flatMap(\.files) {
            print("\(file.path)\t\(file.byteCount)\t\(file.sha256)")
        }
    }

    static func inspect(_ options: Options) throws {
        for path in options.words {
            let archive = try PMTilesArchive(contentsOf: URL(fileURLWithPath: path))
            let header = archive.header
            print("""
            \(path)
              zooms \(header.minimumZoom)–\(header.maximumZoom), \(header.addressedTiles) tiles, \
            \(header.tileEntries) entries, \(header.tileContents) distinct, clustered \(header.isClustered)
              bounds \(header.bounds.map { Double($0) / 1e7 }), tile data \(header.tileDataLength) bytes
            """)
        }
    }
}
