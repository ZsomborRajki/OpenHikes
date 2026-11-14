//
//  RouteSquareFile.swift
//  OpenHikes
//
//  One square of the hiking-routes layer, as the bytes its record's asset
//  carries. ``RouteSquareGrid`` says which square; this is what is in it.
//
//  ## Lines, not relations
//
//  A square holds the ways of OpenStreetMap's hiking routes cut to the
//  square, each **once**, with the routes it belongs to and the most
//  important network among them — what the map draws, and nothing it has to
//  work out first. The day hikes' squares hold relations as OpenStreetMap has
//  them because the app assembles each into one walkable line; this layer
//  never does, it draws paths. The routes themselves are a table at the top:
//  each one's relation id and the tags a label or a waymark would be drawn
//  from (`name`, `ref`, `network`, `osmc:symbol`, `colour`), so a later build
//  of the app can draw those without a new file.
//
//  ## The bytes
//
//  `OHRS` in the envelope ``PackedEnvelope`` writes, and then:
//
//      scale                          coordinate units in one degree
//      count, then each string        every tag key and value, once
//      count, then each route:
//          id                         as the step from the route before
//          count, then each tag       two indices into the strings
//      count, then each line:
//          network                    a ``RouteNetwork``
//          count, then each route     an index into the routes
//          count, then each point     as the step from the point before it
//
//  A point steps from the last point *written*, across lines, as in the day
//  hikes' squares, so a line that starts where the one before it ended costs
//  two bytes for its first point.
//
//  ## Compiled twice
//
//  By the app and by the tool, for the reason ``RouteSquareGrid`` gives.
//

import Foundation

/// The lines filed under one square of ``RouteSquareGrid``.
nonisolated struct RouteSquareFile: Equatable, Sendable {
    /// One vertex, in ``coordinateScale`` units.
    nonisolated struct Point: Hashable, Sendable {
        var latitude: Int32
        var longitude: Int32
    }

    /// One `route=hiking` relation with a way in the square.
    nonisolated struct Route: Equatable, Sendable {
        var id: Int64
        var tags: [String: String]
    }

    /// A way, or the part of one, inside the square.
    nonisolated struct Line: Equatable, Sendable {
        /// The most important network among ``routes``.
        var network: RouteNetwork
        /// Indices into the file's ``RouteSquareFile/routes``.
        var routes: [Int]
        var points: [Point]
    }

    /// The only version this build reads or writes.
    static let formatVersion: UInt8 = 1

    // swiftlint:disable american_spelling_in_copy
    /// The tags a route keeps in a square: what a label, a waymark or the
    /// colour of a line would be drawn from — `colour` spelled as
    /// OpenStreetMap spells its key. The rest of a relation's tags are
    /// OpenStreetMap's bookkeeping and stay there.
    static let keptTags: Set<String> = ["colour", "name", "network", "osmc:symbol", "ref"]
    // swiftlint:enable american_spelling_in_copy

    /// How many coordinate units make one degree.
    var coordinateScale: Int32
    var routes: [Route]
    var lines: [Line]

    init(routes: [Route], lines: [Line], coordinateScale: Int32) {
        self.routes = routes
        self.lines = lines
        self.coordinateScale = coordinateScale
    }

    private static let magic: [UInt8] = Array("OHRS".utf8)
}

// MARK: - Writing

nonisolated extension RouteSquareFile {
    /// The file: the envelope and the body, packed when that makes it
    /// smaller.
    func encoded() -> Data {
        PackedEnvelope.file(magic: Self.magic, version: Self.formatVersion, body: encodedBody())
    }

    /// The body alone, unpacked: what a square's digest is taken over, for
    /// the reason ``TrailCellFile/encodedBody()`` gives.
    func encodedBody() -> Data {
        var strings = PackedStringTable()
        var table = PackedWriter()
        var previousID: Int64 = 0
        for route in routes {
            table.write(step: route.id &- previousID)
            previousID = route.id
            let tags = route.tags.sorted { $0.key < $1.key }
            table.write(UInt64(tags.count))
            for (key, value) in tags {
                table.write(strings.index(of: key))
                table.write(strings.index(of: value))
            }
        }

        var drawn = PackedWriter()
        var previous = Point(latitude: 0, longitude: 0)
        for line in lines {
            drawn.write(UInt64(line.network.rawValue))
            drawn.write(UInt64(line.routes.count))
            for route in line.routes {
                drawn.write(UInt64(route))
            }
            drawn.write(UInt64(line.points.count))
            for point in line.points {
                drawn.write(step: Int64(point.latitude) - Int64(previous.latitude))
                drawn.write(step: Int64(point.longitude) - Int64(previous.longitude))
                previous = point
            }
        }

        var body = PackedWriter()
        body.write(UInt64(coordinateScale))
        body.write(strings: strings)
        body.write(UInt64(routes.count))
        body.bytes.append(contentsOf: table.bytes)
        body.write(UInt64(lines.count))
        body.bytes.append(contentsOf: drawn.bytes)
        return Data(body.bytes)
    }
}

// MARK: - Reading

nonisolated extension RouteSquareFile {
    /// Reads a file ``encoded()`` wrote, checking everything on the way in
    /// for the reason ``TrailCellFile/init(decoding:)`` gives.
    init(decoding file: Data) throws {
        var reader = PackedReader(
            bytes: try PackedEnvelope.body(of: file, magic: Self.magic, version: Self.formatVersion)
        )
        let scale = try reader.readVarint()
        guard scale > 0, scale <= UInt64(Int32.max) else { throw PackedFileError.corrupt }
        let strings = try reader.readStrings()

        var routes: [Route] = []
        var routeID: Int64 = 0
        for _ in try 0..<reader.readCount() {
            routeID &+= try reader.readStep()
            var tags: [String: String] = [:]
            for _ in try 0..<reader.readCount() {
                let key = try reader.readIndexedString(strings)
                tags[key] = try reader.readIndexedString(strings)
            }
            routes.append(Route(id: routeID, tags: tags))
        }

        var lines: [Line] = []
        var cursor = PointCursor(unitsPerDegree: Int64(scale))
        for _ in try 0..<reader.readCount() {
            guard let network = RouteNetwork(rawValue: UInt8(clamping: try reader.readVarint())) else {
                throw PackedFileError.corrupt
            }
            let indices = try (0..<reader.readCount()).map { _ in
                let index = try reader.readVarint()
                guard index < UInt64(routes.count) else { throw PackedFileError.corrupt }
                return Int(index)
            }
            let points = try (0..<reader.readCount()).map { _ in try cursor.step(&reader) }
            lines.append(Line(network: network, routes: indices, points: points))
        }
        guard reader.isAtEnd else { throw PackedFileError.corrupt }
        self.init(routes: routes, lines: lines, coordinateScale: Int32(scale))
    }
}

/// Where the last point left off, which the next one steps from, and how far
/// a point may be from the equator and from Greenwich before it is not one.
nonisolated private struct PointCursor {
    private static let poleDegrees: Int64 = 90
    private static let antimeridianDegrees: Int64 = 180

    private var latitude: Int64 = 0
    private var longitude: Int64 = 0
    private let pole: Int64
    private let antimeridian: Int64

    init(unitsPerDegree: Int64) {
        pole = Self.poleDegrees * unitsPerDegree
        antimeridian = Self.antimeridianDegrees * unitsPerDegree
    }

    /// The next point, or an error when it is off the Earth. Held between
    /// two bounds rather than measured with `abs`, for the reason the day
    /// hikes' cursor gives.
    mutating func step(_ reader: inout PackedReader) throws -> RouteSquareFile.Point {
        latitude &+= try reader.readStep()
        longitude &+= try reader.readStep()
        guard (-pole...pole).contains(latitude), (-antimeridian...antimeridian).contains(longitude),
              let north = Int32(exactly: latitude), let east = Int32(exactly: longitude)
        else { throw PackedFileError.corrupt }
        return RouteSquareFile.Point(latitude: north, longitude: east)
    }
}
