//
//  ElevationBuild.swift
//  trail-cells
//
//  `build-elevation`: the Copernicus DEM's heights at 30 m (GLO-30), filed
//  into the eighth-degree squares the app reads a line's heights from, as
//  one PMTiles archive for the tile server. `ElevationSquareGrid.swift` says
//  which posts a square holds, `ElevationSquareFile.swift` how it is packed.
//
//  ## Where the heights come from
//
//  Copernicus publishes GLO-30 as one cloud-optimized GeoTIFF a degree, in
//  a public bucket that needs no account (`copernicus-dem-30m` on AWS, in
//  eu-central-1): 26,450 tiles, 589 GB, listed here and downloaded each in
//  turn. Nothing is kept: a tile is read, filed and let go. The world took
//  2 h 47 min on 2026-11-26 with 24 tiles at once, about 60 MB/s, most of it
//  the download, and came to an archive of 66.4 GB.
//
//  A degree with no tile is sea, and so are its squares: the archive holds
//  none there, which the app reads as sea level.
//
//  ## Land with no heights
//
//  Twenty-five degrees of Armenia and Azerbaijan are in the 90 m model
//  (GLO-90) and not in the 30 m one. They are not filled from it: those 90 m
//  tiles ship under ESA's *restricted* licence ("COP-DEM-GLO-30-R"), not the
//  free one every other tile carries, and it forbids giving them to the
//  public, which is what the tile server does. Left out, they would read as
//  sea level, mountains at 0 m. So a degree the coarser model has and this
//  one does not is filed as squares of posts with no height
//  (``ElevationSquareFile/unknown``), and a line there gets no profile rather
//  than a wrong one. `--coarser` names where that list is read.
//
//  ## In order, and checked
//
//  A degree is the 8 × 8 squares under one tile of zoom 9 (see
//  ``SquareArchive``), so the degrees are taken in that zoom's tile order and
//  their squares written in theirs, and the archive is clustered. Each tile
//  is held to its band's spacing and its corner before a height of it is
//  filed. Several tiles are read at once and written in order. Once written,
//  the archive is read back by its own directories, every tile counted and
//  one in 97 compared, byte for byte, with what was written.
//
//  ## The whole world, or not
//
//  The app reads a square the archive does not hold as sea at 0 m, so an
//  archive marked complete that left a degree out puts its mountains at sea
//  level, and a hike saved there keeps those heights. A build is marked
//  complete only when nothing can have been left out: no `--area`, both
//  models listed from their public buckets, and each listing at least as
//  long as the bucket is known to be (``worldDegrees``). A directory of tiles
//  vouches for nothing, however many it holds, so a build from one is never
//  the world's, and `upload-archive` refuses it.
//

import Foundation

struct ElevationBuildOptions {
    /// The 30 m model: the bucket's URL, or a directory holding its tiles by
    /// their names.
    var source: String
    /// The 90 m model, read only for the names of its tiles: which degrees
    /// are land the 30 m one leaves out.
    var coarser: String
    var outputDirectory: URL
    var name: String?
    /// Degrees of latitude and longitude, south, west, north and east, whose
    /// south-west corners are filed; `nil` for the world.
    var area: (south: Int, west: Int, north: Int, east: Int)?
    var jobs: Int

    /// Whether this build is of the whole world: no `--area`, and both models
    /// listed from their public buckets, whose listings ``ElevationBuild/run(_:)``
    /// then holds to ``ElevationBuild/worldDegrees``. See the file header.
    var coversTheWorld: Bool {
        area == nil && source == ElevationBuild.defaultSource && coarser == ElevationBuild.defaultCoarser
    }
}

enum ElevationBuild {
    static let defaultSource = "https://copernicus-dem-30m.s3.eu-central-1.amazonaws.com"
    static let defaultCoarser = "https://copernicus-dem-90m.s3.eu-central-1.amazonaws.com"

    /// How many tiles each bucket listed on 2026-11-26, the 90 m model's
    /// being the 30 m one's and the 25 degrees it withholds. A world build
    /// whose listing comes up shorter stops: a page that never arrived would
    /// otherwise leave its degrees out of an archive marked complete.
    static let worldDegrees = (fine: 26_450, coarse: 26_475)

    /// A degree of the Earth, by its south-west corner.
    struct Degree: Hashable, Comparable {
        var south: Int
        var west: Int

        /// Copernicus' name for it: `N47_00_E012_00`.
        var name: String {
            let latitude = String(format: "%@%02d_00", south < 0 ? "S" : "N", abs(south))
            let longitude = String(format: "%@%03d_00", west < 0 ? "W" : "E", abs(west))
            return "\(latitude)_\(longitude)"
        }

        /// The zoom-9 tile whose 8 × 8 squares it is.
        var tileID: UInt64 {
            PMTilesTileID.id(z: 9, x: west + 180, y: 89 - south)
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.tileID < rhs.tileID }

        init(south: Int, west: Int) {
            self.south = south
            self.west = west
        }

        /// The degree a Copernicus name names, as it appears in a key.
        init?(name: some StringProtocol) {
            let parts = name.split(separator: "_")
            guard parts.count == 4, let latitude = parts[0].first, let longitude = parts[2].first,
                  "NS".contains(latitude), "EW".contains(longitude),
                  let south = Int(parts[0].dropFirst()), let west = Int(parts[2].dropFirst())
            else { return nil }
            self.init(south: latitude == "S" ? -south : south, west: longitude == "W" ? -west : west)
        }
    }

    struct Summary {
        var record: SquarePack.Record
        var archive: URL
        var degrees = 0
        var withheld = 0
        var squares = 0
        var seaSquares = 0
        var downloadedBytes = 0
    }

    // MARK: - The build

    static func run(_ options: ElevationBuildOptions) async throws -> Summary {
        let fineDegrees = try await degrees(in: options.source, resolution: .fine)
        let coarseDegrees = try await degrees(in: options.coarser, resolution: .coarse)
        if options.coversTheWorld {
            guard fineDegrees.count >= worldDegrees.fine, coarseDegrees.count >= worldDegrees.coarse else {
                throw ElevationBuildError.shortListing(fine: fineDegrees.count, coarse: coarseDegrees.count)
            }
        }
        let inArea: (Degree) -> Bool = { degree in
            guard let area = options.area else { return true }
            return (area.south..<area.north).contains(degree.south) && (area.west..<area.east).contains(degree.west)
        }
        let read = fineDegrees.keys.filter(inArea).sorted()
        let withheld = Set(coarseDegrees.keys).subtracting(fineDegrees.keys).filter(inArea)
        let work = (read.map { ($0, true) } + withheld.map { ($0, false) }).sorted { $0.0 < $1.0 }
        print("\(read.count) degrees to read, \(withheld.count) withheld from the 30 m model and filed with no heights.")

        let builtAt = Date()
        let name = options.name ?? defaultName(builtAt: builtAt)
        let manager = FileManager.default
        try manager.createDirectory(
            at: options.outputDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard try SquarePack.isReplaceable(options.outputDirectory) else {
            throw ElevationBuildError.outputHoldsOtherFiles(options.outputDirectory.path)
        }
        let staging = options.outputDirectory.appendingPathExtension("staging-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let archiveName = "\(name).pmtiles"
        let staged = staging.appendingPathComponent(archiveName)
        let writer = try TileArchiveWriter(url: staged, zooms: SquareArchive.elevation.zooms)

        var summary = Summary(record: placeholderRecord, archive: staged)
        var checks: [UInt64: UInt64] = [:]
        let write = { (degreeFiled: FiledDegree) throws in
            for square in degreeFiled.squares {
                try writer.append(square.bytes, tileID: square.tileID)
                if square.tileID % 97 == 0 { checks[square.tileID] = fingerprint(square.bytes) }
            }
            summary.squares += degreeFiled.squares.count
            summary.seaSquares += degreeFiled.seaSquares
            summary.downloadedBytes += degreeFiled.downloadedBytes
            if degreeFiled.isWithheld { summary.withheld += 1 } else { summary.degrees += 1 }
        }
        let started = Date()
        var done = 0
        // A degree that fails, after its download's own retries, is set
        // aside and tried once more at the end rather than ending a build
        // hours long; its squares are then the only ones out of order.
        var failed: [(degree: Degree, isRead: Bool, error: any Error)] = []
        for batch in stride(from: 0, to: work.count, by: max(options.jobs, 1)).map({
            Array(work[$0..<min($0 + max(options.jobs, 1), work.count)])
        }) {
            let filed = await withTaskGroup(of: (Degree, Result<FiledDegree, any Error>).self) { group in
                for (degree, isRead) in batch {
                    let location = isRead ? fineDegrees[degree] : nil
                    group.addTask { [degree, location] in
                        let result: Result<FiledDegree, any Error>
                        do {
                            result = .success(try await file(degree, from: location))
                        } catch {
                            result = .failure(error)
                        }
                        return (degree, result)
                    }
                }
                var filed: [Degree: Result<FiledDegree, any Error>] = [:]
                for await (degree, result) in group { filed[degree] = result }
                return filed
            }
            for (degree, isRead) in batch {
                switch filed[degree] {
                case .success(let degreeFiled):
                    try write(degreeFiled)
                case .failure(let error):
                    print("\(degree.name) failed, to be tried again at the end: \(error)")
                    failed.append((degree, isRead, error))
                case nil:
                    failed.append((degree, isRead, ElevationBuildError.status(0, degree.name)))
                }
            }
            let previous = done
            done += batch.count
            if done == work.count || done / reportEvery != previous / reportEvery {
                report(done: done, of: work.count, summary: summary, since: started)
            }
        }
        var stillFailing: [String] = []
        for (degree, isRead, _) in failed {
            do {
                try write(try await file(degree, from: isRead ? fineDegrees[degree] : nil))
                print("\(degree.name) filed on its second try.")
            } catch {
                stillFailing.append("\(degree.name): \(error)")
            }
        }
        guard stillFailing.isEmpty else { throw ElevationBuildError.degreesFailed(stillFailing) }

        // Pack's keys, with the licence's credit for OpenStreetMap's.
        let metadata = try JSONSerialization.data(
            withJSONObject: [
                "name": "OpenHikes \(SquareArchive.elevation.listName)",
                "description": "The Copernicus DEM's GLO-30 heights in whole metres, one OpenHikes elevation "
                    + "square a tile (ElevationSquareFile), filed as OpenHikes' SquareArchive.elevation says.",
                "attribution": ElevationCredit.notice,
                "list": SquareArchive.elevation.listName,
                "generation": SquareArchive.elevation.generation,
                "complete": options.coversTheWorld,
                "vector_layers": [Any](),
            ] as [String: Any],
            options: [.sortedKeys]
        )
        let archiveBytes = try writer.finish(metadata: metadata)
        try readBack(staged, squares: summary.squares, checks: checks)

        let record = SquarePack.Record(
            name: name,
            list: SquareArchive.elevation.listName,
            generation: SquareArchive.elevation.generation,
            minimumZoom: SquareArchive.elevation.zooms.lowerBound,
            zoom: SquareArchive.elevation.zoom,
            complete: options.coversTheWorld,
            builtAt: builtAt,
            packedAt: Date(),
            osmTimestamp: nil,
            squares: summary.squares,
            itemCount: summary.degrees,
            bytes: archiveBytes
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: staging.appendingPathComponent(SquarePack.recordFileName))

        // As pack replaces its output: the record goes first and comes back
        // last, so the output never holds a record without its archive.
        try manager.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        try? manager.removeItem(at: options.outputDirectory.appendingPathComponent(SquarePack.recordFileName))
        for file in try manager.contentsOfDirectory(atPath: options.outputDirectory.path)
        where file.hasSuffix(".pmtiles") {
            try manager.removeItem(at: options.outputDirectory.appendingPathComponent(file))
        }
        let archive = options.outputDirectory.appendingPathComponent(archiveName)
        try manager.moveItem(at: staged, to: archive)
        try manager.moveItem(
            at: staging.appendingPathComponent(SquarePack.recordFileName),
            to: options.outputDirectory.appendingPathComponent(SquarePack.recordFileName)
        )
        summary.record = record
        summary.archive = archive
        return summary
    }

    /// `elevation-20261126-19`: the list's name, then the day and the hour
    /// the build began, in UTC. The heights have no date of their own that
    /// changes, so the build's names it.
    static func defaultName(builtAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HH"
        return "\(SquareArchive.elevation.listName)-\(formatter.string(from: builtAt))"
    }

    private static let placeholderRecord = SquarePack.Record(
        name: "", list: "", generation: 0, minimumZoom: 0, zoom: 0, complete: false, builtAt: Date(),
        packedAt: Date(), osmTimestamp: nil, squares: 0, itemCount: 0, bytes: 0
    )

    /// How many degrees go between two lines of progress.
    private static let reportEvery = 100

    private static func report(done: Int, of total: Int, summary: Summary, since started: Date) {
        let elapsed = Date().timeIntervalSince(started)
        let left = done > 0 ? elapsed / Double(done) * Double(total - done) : 0
        print(String(
            format: "%d of %d degrees, %d squares, %.1f GB read, %.0f s so far, about %.0f min to go",
            done, total, summary.squares, Double(summary.downloadedBytes) / 1e9, elapsed, left / 60
        ))
        fflush(stdout)
    }
}

// MARK: - One degree

extension ElevationBuild {
    struct FiledSquare {
        var tileID: UInt64
        var bytes: Data
    }

    struct FiledDegree {
        var squares: [FiledSquare]
        var seaSquares = 0
        var downloadedBytes = 0
        var isWithheld: Bool
    }

    /// A degree's squares, in tile order: read from the tile at `location`,
    /// or, for land the 30 m model withholds, every post with no height.
    static func file(_ degree: Degree, from location: Location?) async throws -> FiledDegree {
        let rows = ElevationSquareGrid.rowsPerSquare
        let columnsPerDegree = ElevationSquareGrid.postsPerDegreeOfLongitude(tileSouth: degree.south)
        let columns = columnsPerDegree / ElevationSquareGrid.squaresPerDegree
        let firstRow = (89 - degree.south) * ElevationSquareGrid.squaresPerDegree
        let firstColumn = (degree.west + 180) * ElevationSquareGrid.squaresPerDegree

        guard let location else {
            let blank = ElevationSquareFile(
                rows: rows, columns: columns,
                heights: [Int16](repeating: ElevationSquareFile.unknown, count: rows * columns)
            ).encoded()
            let squares = squareOrigins.map { row, column in
                FiledSquare(
                    tileID: PMTilesTileID.id(
                        z: SquareArchive.elevation.zoom, x: firstColumn + column, y: firstRow + row
                    ),
                    bytes: blank
                )
            }
            return FiledDegree(squares: squares.sorted { $0.tileID < $1.tileID }, isWithheld: true)
        }

        let file = try await location.data()
        let tile = try CopernicusTile(file: file)
        try check(tile, of: degree, columnsPerDegree: columnsPerDegree)
        var filed = FiledDegree(squares: [], downloadedBytes: file.count, isWithheld: false)
        for (row, column) in squareOrigins {
            var heights = [Int16](repeating: 0, count: rows * columns)
            for line in 0..<rows {
                let source = (row * rows + line) * tile.columns + column * columns
                for post in 0..<columns {
                    heights[line * columns + post] = wholeMetres(tile.heights[source + post])
                }
            }
            let square = ElevationSquareFile(rows: rows, columns: columns, heights: heights)
            guard !square.isSeaLevel else {
                filed.seaSquares += 1
                continue
            }
            filed.squares.append(FiledSquare(
                tileID: PMTilesTileID.id(z: SquareArchive.elevation.zoom, x: firstColumn + column, y: firstRow + row),
                bytes: square.encoded()
            ))
        }
        filed.squares.sort { $0.tileID < $1.tileID }
        return filed
    }

    /// The 64 squares of a degree, by row and column within it.
    private static let squareOrigins: [(Int, Int)] = (0..<ElevationSquareGrid.squaresPerDegree).flatMap { row in
        (0..<ElevationSquareGrid.squaresPerDegree).map { (row, $0) }
    }

    /// A height in whole metres, or no height for one no ground has:
    /// Copernicus fills its voids, so this is a guard, not a fill.
    static func wholeMetres(_ height: Float) -> Int16 {
        guard height.isFinite, (lowestGround...highestGround).contains(height) else {
            return ElevationSquareFile.unknown
        }
        return Int16(height.rounded())
    }

    /// The Dead Sea's shore is −430 m, Everest 8,849 m.
    private static let lowestGround: Float = -500
    private static let highestGround: Float = 9000

    /// Holds a tile to the degree it is named for: 3,600 rows, its band's
    /// columns, and its north-west post on the degree's corner.
    private static func check(_ tile: CopernicusTile, of degree: Degree, columnsPerDegree: Int) throws {
        let tolerance = 1e-9
        guard tile.rows == ElevationSquareGrid.postsPerDegreeOfLatitude,
              tile.columns == columnsPerDegree,
              abs(tile.west - Double(degree.west)) < tolerance,
              abs(tile.north - Double(degree.south + 1)) < tolerance,
              abs(tile.columnStep * Double(columnsPerDegree) - 1) < tolerance,
              abs(tile.rowStep * Double(ElevationSquareGrid.postsPerDegreeOfLatitude) - 1) < tolerance
        else {
            throw ElevationBuildError.misplaced(
                degree.name,
                "\(tile.rows) × \(tile.columns) posts from \(tile.north)°, \(tile.west)°, "
                    + "a step of \(tile.rowStep)° × \(tile.columnStep)°"
            )
        }
    }
}

// MARK: - Where the tiles are

extension ElevationBuild {
    enum Resolution {
        case fine
        case coarse

        /// What each tile's name starts with: Copernicus' product, then its
        /// spacing in tenths of an arc-second, 10 for the 30 m model and 30
        /// for the 90 m one.
        var prefix: String {
            switch self {
            case .fine: "Copernicus_DSM_COG_10_"
            case .coarse: "Copernicus_DSM_COG_30_"
            }
        }
    }

    /// Where one tile is.
    enum Location: Sendable {
        case url(URL)
        case file(URL)

        func data() async throws -> Data {
            switch self {
            case .file(let url):
                return try Data(contentsOf: url)
            case .url(let url):
                return try await ElevationBuild.download(url)
            }
        }
    }

    /// Every degree the model at `source` has a tile for, and where it is.
    static func degrees(in source: String, resolution: Resolution) async throws -> [Degree: Location] {
        if let url = URL(string: source), url.scheme == "https" {
            return try await bucketDegrees(url, resolution: resolution)
        }
        let directory = URL(fileURLWithPath: source, isDirectory: true)
        var found: [Degree: Location] = [:]
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path)
        where file.hasPrefix(resolution.prefix) && file.hasSuffix("_DEM.tif") {
            let name = file.dropFirst(resolution.prefix.count).dropLast("_DEM.tif".count)
            guard let degree = Degree(name: name) else { continue }
            found[degree] = .file(directory.appendingPathComponent(file))
        }
        return found
    }

    /// The bucket's folders, a tile each, a thousand to a page.
    private static func bucketDegrees(_ bucket: URL, resolution: Resolution) async throws -> [Degree: Location] {
        var found: [Degree: Location] = [:]
        var token: String?
        repeat {
            var components = URLComponents(url: bucket, resolvingAgainstBaseURL: false)!
            // Encoded by hand: a continuation token holds `+`, `/` and `=`,
            // which `queryItems` leaves as they are, and S3 reads a bare `+`
            // as a space and answers 400.
            let query: [(name: String, value: String)] = [("list-type", "2"), ("delimiter", "/")]
                + (token.map { [("continuation-token", $0)] } ?? [])
            components.percentEncodedQuery = query
                .map { "\($0.name)=\(queryEncoded($0.value))" }
                .joined(separator: "&")
            let page = String(decoding: try await download(components.url!), as: UTF8.self)
            for folder in matches(of: "Prefix", in: page) where folder.hasPrefix(resolution.prefix) {
                let stem = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
                let name = stem.dropFirst(resolution.prefix.count).dropLast("_DEM".count)
                guard let degree = Degree(name: name) else { continue }
                found[degree] = .url(bucket.appendingPathComponent(stem).appendingPathComponent("\(stem).tif"))
            }
            token = matches(of: "NextContinuationToken", in: page).first
        } while token != nil
        return found
    }

    /// A query value with everything but S3's unreserved characters
    /// percent-encoded, as S3 signs and reads it.
    private static func queryEncoded(_ value: String) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// The text of every `<element>` in an S3 listing, unescaped as S3
    /// escapes a key.
    private static func matches(of element: String, in page: String) -> [String] {
        page.components(separatedBy: "<\(element)>").dropFirst().compactMap { piece in
            piece.components(separatedBy: "</\(element)>").first?
                .replacingOccurrences(of: "&amp;", with: "&")
        }
    }

    /// A URL's body, asked again after a pause when the network or S3
    /// fails, as a world of downloads will now and then.
    static func download(_ url: URL) async throws -> Data {
        var lastError: (any Error)?
        for attempt in 0..<downloadAttempts {
            if attempt > 0 { try await Task.sleep(for: .seconds(2 << attempt)) }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = downloadTimeout
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw ElevationBuildError.status(status, url.lastPathComponent) }
                if let expected = (response as? HTTPURLResponse)?.expectedContentLength, expected >= 0,
                   Int64(data.count) != expected {
                    throw ElevationBuildError.short(url.lastPathComponent)
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ElevationBuildError.status(0, url.lastPathComponent)
    }

    private static let downloadAttempts = 6
    private static let downloadTimeout: TimeInterval = 300
}

// MARK: - Reading it back

extension ElevationBuild {
    /// Counts the archive's tiles by its own directories, and compares every
    /// tile `checks` names with the fingerprint of what was written.
    static func readBack(_ archive: URL, squares: Int, checks: [UInt64: UInt64]) throws {
        let reader = try TileArchiveReader(url: archive)
        let count = try reader.tileCount()
        guard count == UInt64(squares) else { throw ElevationBuildError.readBack("\(count) tiles, not \(squares)") }
        for (id, expected) in checks {
            guard let bytes = try reader.tile(id: id), fingerprint(bytes) == expected,
                  (try? ElevationSquareFile(decoding: bytes)) != nil
            else { throw ElevationBuildError.readBack("tile \(id) does not read back as written") }
        }
        print("Read back: \(count) tiles, \(checks.count) of them compared with what was written.")
    }

    /// FNV-1a, enough to tell a tile from a different one.
    static func fingerprint(_ data: Data) -> UInt64 {
        data.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x0100_0000_01b3 }
    }
}

enum ElevationBuildError: Error, CustomStringConvertible {
    case misplaced(String, String)
    case status(Int, String)
    case short(String)
    case readBack(String)
    case outputHoldsOtherFiles(String)
    case degreesFailed([String])
    case shortListing(fine: Int, coarse: Int)

    var description: String {
        switch self {
        case .misplaced(let degree, let found):
            "\(degree) is not the tile its name says: \(found)."
        case .status(let status, let name):
            "\(name) answered \(status)."
        case .short(let name):
            "\(name) arrived shorter than it said it was."
        case .readBack(let what):
            "the archive did not read back: \(what)."
        case .outputHoldsOtherFiles(let path):
            "\(path) holds files no earlier build wrote; build into a directory of its own."
        case .degreesFailed(let failures):
            "\(failures.count) degrees could not be filed, twice:\n" + failures.joined(separator: "\n")
        case let .shortListing(fine, coarse):
            "the buckets listed \(fine) tiles at 30 m and \(coarse) at 90 m, fewer than the "
                + "\(ElevationBuild.worldDegrees.fine) and \(ElevationBuild.worldDegrees.coarse) they hold, so "
                + "the world cannot be built from them."
        }
    }
}
