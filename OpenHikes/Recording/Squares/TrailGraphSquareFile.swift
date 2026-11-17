//
//  TrailGraphSquareFile.swift
//  OpenHikes
//
//  One square of OpenStreetMap's trails, as the bytes its record's asset
//  carries. ``TrailGraphSquareGrid`` says which square; this is what is in it.
//
//  ## What a square holds: the ways an Overpass answer would
//
//  Each trail is its way: its id, its `highway`, the six other tags an edge of
//  ``TrailGraph`` keeps, the name of a hiking route it is part of, and every
//  one of its nodes, with the node's id and position. Node ids because the
//  graph is joined at them: two ways that share a node are a junction, and a
//  graph read from a square has to merge with one read from Overpass, which
//  names its nodes the same way. Which segments are edges and how long each is
//  stays the app's to decide — see `TrailGraphSquareLibrary.swift`.
//
//  What the tool that writes these decides is what cannot be left for later:
//  which ways are trails (``TrailGraphHighway/trails``), which of them may be
//  walked (``permitsWalking(_:)``), and which hiking route names one
//  (``hikingRouteName(_:)``) — the two rules `OverpassTrailGraphDecoding`
//  applies to an Overpass answer, written here once for both.
//
//  ## The bytes
//
//  An envelope — `OHGS`, a version, how the rest is packed and how long it is
//  unpacked; see ``PackedEnvelope`` — and then the body, which is unsigned
//  LEB128 integers throughout:
//
//      scale                          coordinate units in one degree
//      count, then each string        every tag value, once
//      count, then each way:
//          id                         as the step from the way before
//          highway                    an index into the strings
//          tags                       a bit for each of ``Tag`` the way has
//          each tag it has            an index into the strings
//          count, then each node:
//              id                     as the step from the node before
//              point                  as the step from the node before
//
//  A node steps from the last node *written*, across ways, so a way that
//  starts where the one before it ended costs a few bytes for the joint.
//
//  ## Compiled twice
//
//  By the app and by the tool, for the reason ``TrailGraphSquareGrid`` gives,
//  so this file imports Foundation and nothing of the app's.
//

import Foundation

/// The trails filed under one square of ``TrailGraphSquareGrid``.
nonisolated struct TrailGraphSquareFile: Equatable, Sendable {
    /// One node of a way: its OpenStreetMap id, and its position in
    /// ``coordinateScale`` units.
    nonisolated struct Node: Hashable, Sendable {
        var id: Int64
        var latitude: Int32
        var longitude: Int32
    }

    /// The tags a trail keeps beside its `highway`, in the order their bits
    /// are numbered. ``hikingRoute`` is not a tag of the way but the name of
    /// a hiking route it is part of — see ``hikingRouteName(_:)``.
    nonisolated enum Tag: Int, CaseIterable, Sendable {
        case name = 0
        case hikingRoute = 1
        case sacScale = 2
        case trailVisibility = 3
        case access = 4
        case surface = 5
        case tracktype = 6

        // periphery:ignore - the tool behind `Scripts/trail-cells.sh`, which
        // compiles this file, reads a way's tags by it.
        /// The way's own key, or `nil` for the one that is not a tag of it.
        var key: String? {
            switch self {
            case .name: "name"
            case .hikingRoute: nil
            case .sacScale: "sac_scale"
            case .trailVisibility: "trail_visibility"
            case .access: "access"
            case .surface: "surface"
            case .tracktype: "tracktype"
            }
        }
    }

    /// One trail.
    nonisolated struct Way: Equatable, Sendable {
        var id: Int64
        var highway: String
        var tags: [Tag: String]
        var nodes: [Node]
    }

    /// The only version this build reads or writes — see
    /// ``TrailGraphSquareGrid/generation`` for where another would go.
    static let formatVersion: UInt8 = 1

    /// The scale the tool writes: millionths of a degree, about 11 cm, the
    /// day hikes' squares' own. See ``TrailCellFile/standardCoordinateScale``.
    static let standardCoordinateScale: Int32 = 1_000_000

    var coordinateScale: Int32
    var ways: [Way]

    init(ways: [Way], coordinateScale: Int32 = Self.standardCoordinateScale) {
        self.ways = ways
        self.coordinateScale = coordinateScale
    }
}

// MARK: - The rules a trail is read by

nonisolated extension TrailGraphSquareFile {
    /// Whether a way tagged `tags` may be walked: not where `foot` says no,
    /// and not where `access` does unless `foot` says yes.
    static func permitsWalking(_ tags: [String: String]) -> Bool {
        if let foot = tags["foot"], foot == "no" || foot == "private" { return false }
        guard let access = tags["access"], access == "no" || access == "private" else { return true }
        return ["yes", "designated", "permissive"].contains(tags["foot"])
    }

    /// The name a hiking route gives the ways it is made of: its `name`, or
    /// its `ref` where it has none, and `nil` for a relation that is not a
    /// hiking route or has neither. Where several routes name a way, the
    /// first in sort order is its name — see ``hikingRouteName(of:)``.
    static func hikingRouteName(_ tags: [String: String]) -> String? {
        guard tags["route"] == "hiking" else { return nil }
        return tags["name"] ?? tags["ref"]
    }

    /// The name of a way that `names` hiking routes are made of: the first
    /// in sort order, so the same ways always read the same.
    static func hikingRouteName(of names: some Sequence<String>) -> String? {
        names.min()
    }
}

/// Why some bytes are not a square this build can read.
nonisolated enum TrailGraphSquareFileError: Error, Equatable {
    case corrupt
    case notASquare
    case truncated
    case unsupportedCompression(UInt8)
    case unsupportedVersion(UInt8)
}

// MARK: - Writing

nonisolated extension TrailGraphSquareFile {
    /// The file: the envelope and the body, packed when that makes it
    /// smaller.
    func encoded() -> Data {
        PackedEnvelope.file(magic: Self.magic, version: Self.formatVersion, body: encodedBody())
    }

    /// The body alone, unpacked: what a square's digest is taken over, for
    /// the reason ``TrailCellFile/encodedBody()`` gives. Ways are written by
    /// id, so the same ways always give the same bytes.
    func encodedBody() -> Data {
        var strings = PackedStringTable()
        var written = PackedWriter()
        var previousWay: Int64 = 0
        var previous = Node(id: 0, latitude: 0, longitude: 0)
        for way in ways.sorted(by: { $0.id < $1.id }) {
            written.write(step: way.id &- previousWay)
            previousWay = way.id
            written.write(strings.index(of: way.highway))
            let present = Tag.allCases.filter { way.tags[$0] != nil }
            written.write(present.reduce(UInt64(0)) { $0 | (1 << UInt64($1.rawValue)) })
            for tag in present {
                written.write(strings.index(of: way.tags[tag] ?? ""))
            }
            written.write(UInt64(way.nodes.count))
            for node in way.nodes {
                written.write(step: node.id &- previous.id)
                written.write(step: Int64(node.latitude) - Int64(previous.latitude))
                written.write(step: Int64(node.longitude) - Int64(previous.longitude))
                previous = node
            }
        }

        var body = PackedWriter()
        body.write(UInt64(coordinateScale))
        body.write(strings: strings)
        body.write(UInt64(ways.count))
        body.bytes.append(contentsOf: written.bytes)
        return Data(body.bytes)
    }
}

// MARK: - Reading

nonisolated extension TrailGraphSquareFile {
    /// Reads a file ``encoded()`` wrote, checking everything on the way in,
    /// for the reason ``TrailCellFile/init(decoding:)`` does.
    init(decoding file: Data) throws {
        do {
            self = try Self(body: PackedEnvelope.body(of: file, magic: Self.magic, version: Self.formatVersion))
        } catch let error as PackedFileError {
            throw TrailGraphSquareFileError(error)
        }
    }

    private init(body: [UInt8]) throws {
        var reader = PackedReader(bytes: body)
        let scale = try reader.readVarint()
        guard scale > 0, scale <= UInt64(Int32.max) else { throw TrailGraphSquareFileError.corrupt }
        let strings = try reader.readStrings()
        var ways: [Way] = []
        var cursor = GraphCursor(unitsPerDegree: Int64(scale))
        for _ in try 0..<reader.readCount() {
            ways.append(try reader.readGraphWay(strings: strings, cursor: &cursor))
        }
        guard reader.isAtEnd else { throw TrailGraphSquareFileError.corrupt }
        self.init(ways: ways, coordinateScale: Int32(scale))
    }

    private static let magic: [UInt8] = Array("OHGS".utf8)
}

nonisolated private extension TrailGraphSquareFileError {
    init(_ error: PackedFileError) {
        switch error {
        case .corrupt: self = .corrupt
        case .wrongFormat: self = .notASquare
        case .truncated: self = .truncated
        case .unsupportedCompression(let method): self = .unsupportedCompression(method)
        case .unsupportedVersion(let version): self = .unsupportedVersion(version)
        }
    }
}

/// Where the last way and the last node left off, which the next ones step
/// from — and how far a point may be from the equator and from Greenwich
/// before it is not one, held between two bounds for the reason
/// `TrailCellFile.swift`'s cursor is.
nonisolated private struct GraphCursor {
    private static let poleDegrees: Int64 = 90
    private static let antimeridianDegrees: Int64 = 180

    var way: Int64 = 0
    var node: Int64 = 0
    var latitude: Int64 = 0
    var longitude: Int64 = 0
    let unitsPerDegree: Int64

    init(unitsPerDegree: Int64) {
        self.unitsPerDegree = unitsPerDegree
    }

    var current: TrailGraphSquareFile.Node? {
        let pole = Self.poleDegrees * unitsPerDegree
        let antimeridian = Self.antimeridianDegrees * unitsPerDegree
        guard (-pole...pole).contains(latitude),
              (-antimeridian...antimeridian).contains(longitude),
              let north = Int32(exactly: latitude),
              let east = Int32(exactly: longitude)
        else { return nil }
        return TrailGraphSquareFile.Node(id: node, latitude: north, longitude: east)
    }
}

nonisolated private extension PackedReader {
    /// The bits a way's tags are written as can name no tag past the last.
    private static var tagMask: UInt64 { (1 << UInt64(TrailGraphSquareFile.Tag.allCases.count)) - 1 }

    mutating func readGraphWay(strings: [String], cursor: inout GraphCursor) throws -> TrailGraphSquareFile.Way {
        cursor.way &+= try readStep()
        let highway = try readIndexedString(strings)
        let bits = try readVarint()
        guard bits & ~Self.tagMask == 0 else { throw TrailGraphSquareFileError.corrupt }
        var tags: [TrailGraphSquareFile.Tag: String] = [:]
        for tag in TrailGraphSquareFile.Tag.allCases where bits & (1 << UInt64(tag.rawValue)) != 0 {
            tags[tag] = try readIndexedString(strings)
        }
        var nodes: [TrailGraphSquareFile.Node] = []
        for _ in try 0..<readCount() {
            cursor.node &+= try readStep()
            cursor.latitude &+= try readStep()
            cursor.longitude &+= try readStep()
            guard let node = cursor.current else { throw TrailGraphSquareFileError.corrupt }
            nodes.append(node)
        }
        return TrailGraphSquareFile.Way(id: cursor.way, highway: highway, tags: tags, nodes: nodes)
    }
}
