//
//  Tool.swift
//  offline-countries
//
//  The countries the app downloads, cut out of the planet build the OpenHikes
//  map draws: `Scripts/offline-countries.sh` is the way in and says how.
//
//    build      cut each country's basemap and extras, with --trails its day
//               hikes and with --elevation its heights, read them back
//               against the source, and write the manifest beside them
//    trails     cut the day hikes of the areas a manifest lists, for the
//               builds it lists them at (Trails.swift)
//    elevation  cut the heights of the areas a manifest lists, for the
//               builds it lists them at (Elevation.swift)
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
            case "areas": try areas(Options(arguments))
            case "build": try await build(Options(arguments))
            case "trails": try await trails(Options(arguments))
            case "elevation": try await elevation(Options(arguments))
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

    /// `areas`: every area `build` would cut, its code and, for a region,
    /// its country's, a line each.
    static func areas(_ options: Options) throws {
        let plan = try JSONDecoder().decode(
            AreaPlan.self,
            from: Data(contentsOf: URL(fileURLWithPath: options.required("countries")))
        )
        let areas = try Areas.all(
            plan: plan,
            countries: Outlines.features(at: URL(fileURLWithPath: options.required("outlines"))),
            regions: Outlines.features(at: URL(fileURLWithPath: options.required("regions")))
        )
        for area in areas { print([area.id, area.group].compactMap(\.self).joined(separator: "\t")) }
    }

    static func build(_ options: Options) async throws {
        let planet = try await Extractor(source: openSource(options.required("planet")))
        let extras = try await Extractor(source: openSource(options.required("extras")))
        let trails = try await trailsSource(options)
        let elevation = try await elevationSource(options)
        guard Int(planet.header.maximumZoom) == detailZoom else {
            fail("the planet goes to zoom \(planet.header.maximumZoom), and the detail files are zoom \(detailZoom)")
        }
        let build = options.required("build")
        let output = URL(fileURLWithPath: options.required("out"), isDirectory: true)
        let margin = Double(options.optional("margin-km") ?? "3") ?? 3
        let server = options.optional("server").flatMap(URL.init(string:))
        // Which builds of the app draw the extras, where the caller knows:
        // an area says so, and a build that does not leaves it off its list.
        let extrasGeneration = options.optional("extras-generation").map { text -> Int in
            guard let generation = Int(text), generation >= 1 else {
                fail("--extras-generation is \(text), not a generation")
            }
            return generation
        }
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
                    margin: margin, server: server, metadata: metadata, extrasMetadata: extrasMetadata,
                    extrasGeneration: extrasGeneration, trails: trails, elevation: elevation
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
        let extrasGeneration: Int?
        /// Where the day hikes come from, or `nil` for an area without them.
        let trails: TrailsSource?
        /// Where the heights come from, or `nil` for an area without them.
        let elevation: ElevationSource?
    }

    /// The four map files of an area: which archive each is cut from, between
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
        if let trails = cut.trails {
            // The basemap's server is the archive's name under the server's
            // root, where the trails archive is too.
            files.append(try await cutTrails(
                id: choice.id, rings: rings, build: cut.build, from: trails, into: cut.output,
                server: cut.server?.deletingLastPathComponent()
            ))
        }
        if let elevation = cut.elevation {
            files.append(try await cutElevation(
                id: choice.id, rings: rings, build: cut.build, from: elevation, into: cut.output,
                server: cut.server?.deletingLastPathComponent()
            ))
        }
        return OfflineCountryManifest.Country(
            id: choice.id,
            group: choice.group,
            names: choice.names,
            build: cut.build,
            schema: OfflineCountryManifest.readableSchema,
            extrasGeneration: cut.extrasGeneration,
            bounds: OfflineCountryManifest.Bounds(
                west: bounds.west, south: bounds.south, east: bounds.east, north: bounds.north
            ),
            outline: rings.compactMap { Outlines.simplified($0, tolerance: outlineTolerance) },
            files: files
        )
    }

    /// The source's metadata, saying which country and build it was cut for,
    /// and, where it is not the build's own, which archive it was cut from.
    static func labeled(_ metadata: [UInt8], country: String, build: String, source: String? = nil) throws -> [UInt8] {
        var object = (try JSONSerialization.jsonObject(with: Data(metadata)) as? [String: Any]) ?? [:]
        var label = ["country": country, "build": build]
        label["source"] = source
        object["openhikes"] = label
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
                switch await served(tileURL) {
                case let .some(served) where served == original: break
                case .some: fail("\(tileURL) differs from \(url.lastPathComponent)")
                case .none: fail("\(tileURL) did not answer, asked \(serverAttempts) times")
                }
            }
            checked += 1
        }
        print("  read back \(checked) tiles\(server == nil ? "" : ", \(min(checked, serverCheckedTiles)) of them against the server")")
    }

    static let serverAttempts = 3

    /// The tile server's bytes for `url`, from its first answer that is a
    /// 200: an error, or a 5xx a busy Worker gives now and then, is the
    /// network's and is asked again, where different bytes are the cut's.
    static func served(_ url: URL) async -> [UInt8]? {
        for attempt in 1...serverAttempts {
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return Array(data)
            }
            try? await Task.sleep(for: .seconds(attempt))
        }
        return nil
    }

    static func write(_ manifest: OfflineCountryManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }
}

// MARK: - A file added to builds already up

extension Tool {
    /// Cuts a file of `role` for every area `--manifest` lists, or those
    /// `--only` names, along the outline it lists and for the build it lists
    /// each at, into `--out` with a manifest of those areas, each with the
    /// new file in place of any of its role it had: what `trails` and
    /// `elevation` bring to builds already up, which `upload` then puts
    /// beside them.
    static func addToListed(
        _ options: Options,
        role: OfflineCountryManifest.Role,
        cut: (OfflineCountryManifest.Country, [Ring], URL) async throws -> OfflineCountryManifest.File
    ) async throws {
        let listed = try JSONDecoder().decode(
            OfflineCountryManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: options.required("manifest")))
        )
        let output = URL(fileURLWithPath: options.required("out"), isDirectory: true)
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
            let file = try await cut(country, rings, output)
            country.files.removeAll { $0.role == role }
            country.files.append(file)
            manifest.countries.append(country)
            try write(manifest, to: manifestURL)
        }
    }
}

// MARK: - merge and inspect

extension Tool {
    /// `merge --server <manifest.json> --build <manifest.json> --out <file>`:
    /// the server's manifest with every country of the build's put in it,
    /// replacing the same country of an older build, which an installed app
    /// then offers as an update. A build earlier than the one the server
    /// lists is refused: `Scripts/offline-countries.sh prune` deletes the
    /// files of a build the server has moved past, so a country's build only
    /// ever rises.
    ///
    /// Of the same build, a role the server lists and the build's entry does
    /// not is kept: see ``keepingListedRoles(of:in:)``.
    static func merge(_ options: Options) throws {
        let decoder = JSONDecoder()
        let built = try decoder.decode(
            OfflineCountryManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: options.required("build")))
        )
        // No file is a server with no manifest yet. One that does not read is
        // an error: taken as empty, the merge would write back this build's
        // countries alone, and drop every other one from the server's list.
        let serverPath = options.required("server")
        var merged = if FileManager.default.fileExists(atPath: serverPath) {
            try decoder.decode(OfflineCountryManifest.self, from: Data(contentsOf: URL(fileURLWithPath: serverPath)))
        } else {
            OfflineCountryManifest(version: OfflineCountryManifest.currentVersion, countries: [])
        }
        for country in built.countries {
            let listed = merged.countries.filter { $0.id == country.id }
            if let later = listed.first(where: { $0.build > country.build }) {
                fail("the server lists build \(later.build) of \(country.id), later than this \(country.build)")
            }
            merged.countries.removeAll { $0.id == country.id }
            merged.countries.append(keepingListedRoles(of: listed, in: country))
        }
        merged.countries.sort { $0.id < $1.id }
        try write(merged, to: URL(fileURLWithPath: options.required("out")))
        print("offline-countries: \(merged.countries.count) countries in the merged manifest")
    }

    /// `country`, with every file the server lists for the same build in a
    /// role `country` has none of.
    ///
    /// A directory cut before a role was added to its build (`trails`)
    /// still uploads cleanly, because every file it holds is the bucket's
    /// byte for byte. Taken as it is, it would take the added file off the
    /// list while the file stayed in the bucket, and every download and
    /// every map waiting for it would go without. So a role leaves an
    /// area's list only with a new build. A role both lists hold is the same
    /// file in each, because the upload refuses a name already taken by
    /// other bytes.
    static func keepingListedRoles(
        of listed: [OfflineCountryManifest.Country],
        in country: OfflineCountryManifest.Country
    ) -> OfflineCountryManifest.Country {
        let published = listed.filter { $0.build == country.build }.flatMap(\.files)
        var kept = country
        for role in OfflineCountryManifest.Role.allCases where !kept.files.contains(where: { $0.role == role }) {
            if let file = published.first(where: { $0.role == role }) {
                kept.files.append(file)
            }
        }
        return kept
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
