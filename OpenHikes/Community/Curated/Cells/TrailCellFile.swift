//
//  TrailCellFile.swift
//  OpenHikes
//
//  One square of OpenStreetMap's hiking routes, as the bytes its record's
//  asset carries. ``TrailCellGrid`` says which square; this is what is in it.
//
//  ## What a square holds: the relations as OpenStreetMap has them
//
//  Each route is its relation's id, its tags, and its member ways in member
//  order — every way with its role and its points. **Not an assembled line.**
//  Which ways are the route, how they join into one walkable line and whether
//  enough of them join to draw is ``CuratedTrailDecoding``'s to decide, and it
//  decides it here on exactly what it decides it on for an Overpass answer:
//  see ``CuratedTrailDecoding/trails(in:touching:)``. So a route reads the
//  same whichever of the two brought it, and a change to those rules is a
//  change to the app rather than a rebuild of the world. What the tool that
//  writes these does decide is only what cannot be left for later, because it
//  is what keeps a square small: which relations are filed at all — see
//  ``TrailCellGrid/maximumRouteSpanMeters``.
//
//  A relation's bounding box is not stored. It is the extent of the points
//  that are, which is what the tool measured it from, so the reader cannot be
//  handed a box that disagrees with the ways beside it. (Overpass's own box
//  also counts a relation's node members, a guidepost standing off the path
//  among them; these do not, and the difference measured over the Pilis hills
//  was one route of 77, by 25 meters.)
//
//  ## The bytes
//
//  An envelope — `OHTC`, a version, how the rest is packed and how long it is
//  unpacked; see ``PackedEnvelope`` — and then the body, which is unsigned LEB128 integers
//  throughout:
//
//      scale                          coordinate units in one degree
//      count, then each string        every role, tag key and tag value, once
//      count, then each relation:
//          id                         as the step from the relation before
//          count, then each tag       two indices into the strings
//          count, then each way:
//              role                   an index into the strings
//              count, then each point as the step from the point before it
//
//  Steps are zigzag-encoded so a step back costs what a step forward does,
//  and a point steps from the last point *written*, across ways and across
//  relations, so the first point of a way that starts where the one before
//  ended is two bytes.
//
//  Coordinates are whole numbers of 1/``coordinateScale`` of a degree, and the
//  tool writes ``standardCoordinateScale`` — a millionth, about 11 cm.
//  OpenStreetMap keeps one digit more, and measured on the routes of the
//  Berchtesgaden and Pilis searches that digit was a quarter of every square's
//  size for a centimeter nobody surveyed. Two ways that share a node still
//  share the number after rounding, which is all the line assembly asks.
//
//  ## Compiled twice
//
//  By the app and by the tool, for the reason ``TrailCellGrid`` gives, so this
//  file imports Foundation and nothing of the app's. The envelope and the
//  integers are `PackedBytes.swift`'s, which the hiking-routes layer's squares
//  are written in too.
//

import Foundation

/// The routes filed under one square of ``TrailCellGrid``.
nonisolated struct TrailCellFile: Equatable, Sendable {
    /// One vertex of a way, in ``coordinateScale`` units.
    nonisolated struct Point: Hashable, Sendable {
        var latitude: Int32
        var longitude: Int32
    }

    /// One member way of a relation.
    nonisolated struct Way: Equatable, Sendable {
        /// The member's role, exactly as OpenStreetMap has it — see
        /// ``CuratedTrailDecoding/mainRoles`` for what reads it.
        var role: String
        var points: [Point]
    }

    /// One `route=hiking` relation.
    nonisolated struct Relation: Equatable, Sendable {
        var id: Int64
        var tags: [String: String]
        /// The member ways, in member order. Members that are nodes or other
        /// relations are not carried: nothing draws them.
        var ways: [Way]
    }

    /// The only version this build reads or writes. A file of another
    /// version is refused — see ``TrailCellGrid/generation`` for where one
    /// would be put.
    static let formatVersion: UInt8 = 1

    /// The scale the tool writes: millionths of a degree. See this file's
    /// header for the measurement.
    static let standardCoordinateScale: Int32 = 1_000_000

    /// How many coordinate units make one degree.
    var coordinateScale: Int32
    var relations: [Relation]

    init(relations: [Relation], coordinateScale: Int32 = Self.standardCoordinateScale) {
        self.relations = relations
        self.coordinateScale = coordinateScale
    }
}

/// Why some bytes are not a square this build can read.
nonisolated enum TrailCellFileError: Error, Equatable {
    /// The body says something no writer of this format would: an index past
    /// the end of the strings, a count larger than what is left, a coordinate
    /// off the Earth.
    case corrupt
    /// The first four bytes are not this format's.
    case notACell
    /// The bytes stop before the file does.
    case truncated
    case unsupportedCompression(UInt8)
    case unsupportedVersion(UInt8)
}

// MARK: - Writing

nonisolated extension TrailCellFile {
    /// The file: the envelope and the body, packed when that makes it
    /// smaller.
    func encoded() -> Data {
        PackedEnvelope.file(magic: Self.magic, version: Self.formatVersion, body: encodedBody())
    }

    /// The body alone, unpacked: what a square's digest is taken over.
    ///
    /// The same relations always give the same bytes — tags are written in
    /// key order and strings are numbered in the order they are met — which
    /// the packed file does not promise from one release of the system's
    /// compressor to the next. So the tool compares squares by this, and a
    /// new macOS does not look like a new world.
    func encodedBody() -> Data {
        var strings = PackedStringTable()
        var routes = PackedWriter()
        var previousID: Int64 = 0
        var previous = Point(latitude: 0, longitude: 0)
        for relation in relations {
            routes.write(step: relation.id &- previousID)
            previousID = relation.id
            let tags = relation.tags.sorted { $0.key < $1.key }
            routes.write(UInt64(tags.count))
            for (key, value) in tags {
                routes.write(strings.index(of: key))
                routes.write(strings.index(of: value))
            }
            routes.write(UInt64(relation.ways.count))
            for way in relation.ways {
                routes.write(strings.index(of: way.role))
                routes.write(UInt64(way.points.count))
                for point in way.points {
                    routes.write(step: Int64(point.latitude) - Int64(previous.latitude))
                    routes.write(step: Int64(point.longitude) - Int64(previous.longitude))
                    previous = point
                }
            }
        }

        var body = PackedWriter()
        body.write(UInt64(coordinateScale))
        body.write(strings: strings)
        body.write(UInt64(relations.count))
        body.bytes.append(contentsOf: routes.bytes)
        return Data(body.bytes)
    }
}

// MARK: - Reading

nonisolated extension TrailCellFile {
    /// Reads a file ``encoded()`` wrote.
    ///
    /// Everything is checked on the way in — a count against the bytes that
    /// are left, an index against the strings, a coordinate against the
    /// Earth — because what arrives here came over a network and is drawn on
    /// a map: bytes that are not a square have to be an error, never a route
    /// across an ocean.
    init(decoding file: Data) throws {
        do {
            self = try Self(body: PackedEnvelope.body(of: file, magic: Self.magic, version: Self.formatVersion))
        } catch let error as PackedFileError {
            throw TrailCellFileError(error)
        }
    }

    private init(body: [UInt8]) throws {
        var reader = PackedReader(bytes: body)
        let scale = try reader.readVarint()
        guard scale > 0, scale <= UInt64(Int32.max) else { throw TrailCellFileError.corrupt }
        let strings = try reader.readStrings()
        var relations: [Relation] = []
        var cursor = Cursor(unitsPerDegree: Int64(scale))
        for _ in try 0..<reader.readCount() {
            relations.append(try reader.readRelation(strings: strings, cursor: &cursor))
        }
        guard reader.isAtEnd else { throw TrailCellFileError.corrupt }
        self.init(relations: relations, coordinateScale: Int32(scale))
    }

    /// The four letters a square's file starts with.
    private static let magic: [UInt8] = Array("OHTC".utf8)
}

nonisolated private extension TrailCellFileError {
    /// The shared reader's reason, in this file's words.
    init(_ error: PackedFileError) {
        switch error {
        case .corrupt: self = .corrupt
        case .wrongFormat: self = .notACell
        case .truncated: self = .truncated
        case .unsupportedCompression(let method): self = .unsupportedCompression(method)
        case .unsupportedVersion(let version): self = .unsupportedVersion(version)
        }
    }
}

/// Where the last relation and the last point left off, which the next ones
/// step from — and how far a point may be from the equator and from Greenwich
/// before it is not one.
nonisolated private struct Cursor {
    private static let poleDegrees: Int64 = 90
    private static let antimeridianDegrees: Int64 = 180

    var relationID: Int64 = 0
    var latitude: Int64 = 0
    var longitude: Int64 = 0
    let unitsPerDegree: Int64

    init(unitsPerDegree: Int64) {
        self.unitsPerDegree = unitsPerDegree
    }

    /// The point the cursor stands on, or `nil` when that is off the Earth.
    ///
    /// Held between two bounds rather than measured with `abs`: a step is any
    /// 64-bit number a file cares to spell, so the cursor can stand on
    /// `Int64.min`, which has no absolute value and would stop the app where
    /// this is meant to refuse the file.
    var point: TrailCellFile.Point? {
        let pole = Self.poleDegrees * unitsPerDegree
        let antimeridian = Self.antimeridianDegrees * unitsPerDegree
        guard (-pole...pole).contains(latitude),
              (-antimeridian...antimeridian).contains(longitude),
              let north = Int32(exactly: latitude),
              let east = Int32(exactly: longitude)
        else { return nil }
        return TrailCellFile.Point(latitude: north, longitude: east)
    }
}

nonisolated private extension PackedReader {
    mutating func readRelation(strings: [String], cursor: inout Cursor) throws -> TrailCellFile.Relation {
        cursor.relationID &+= try readStep()
        var tags: [String: String] = [:]
        for _ in try 0..<readCount() {
            let key = try readIndexedString(strings)
            tags[key] = try readIndexedString(strings)
        }
        var ways: [TrailCellFile.Way] = []
        for _ in try 0..<readCount() {
            let role = try readIndexedString(strings)
            let points = try (0..<readCount()).map { _ in try readPoint(cursor: &cursor) }
            ways.append(TrailCellFile.Way(role: role, points: points))
        }
        return TrailCellFile.Relation(id: cursor.relationID, tags: tags, ways: ways)
    }

    private mutating func readPoint(cursor: inout Cursor) throws -> TrailCellFile.Point {
        cursor.latitude &+= try readStep()
        cursor.longitude &+= try readStep()
        guard let point = cursor.point else { throw TrailCellFileError.corrupt }
        return point
    }
}
