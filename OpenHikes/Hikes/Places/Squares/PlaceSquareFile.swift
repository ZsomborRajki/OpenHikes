//
//  PlaceSquareFile.swift
//  OpenHikes
//
//  One square of OpenStreetMap's places, as the bytes its record's asset
//  carries. ``PlaceSquareGrid`` says which square; this is what is in it.
//
//  ## What a square holds: the elements an Overpass search would answer with
//
//  Each place is its element — a node, or the way or relation a hut or a
//  campsite is mapped as — with one point and the tags a place is read from.
//  The point is the node's own, or the middle of the box around a way's or a
//  relation's ways, which is what Overpass's `out center` puts on one. Which
//  symbol a place is drawn as, and whether it is one at all, stays
//  ``TrailPointDecoding``'s to decide, on exactly what it decides it on for an
//  Overpass answer, so a place reads the same whichever of the two brought it.
//
//  What the tool that writes these does decide is which elements are filed —
//  the ones ``kinds`` names, which are the ones ``TrailPointQuery`` asks for —
//  and which of their tags are kept: ``keptTagKeys``, everything a place, its
//  symbol and its card are read from, and nothing else, because the rest of
//  an element's tags are most of a square and nothing reads them.
//
//  ## The bytes
//
//  An envelope — `OHPS`, a version, how the rest is packed and how long it is
//  unpacked; see ``PackedEnvelope`` — and then the body, which is unsigned
//  LEB128 integers throughout:
//
//      scale                          coordinate units in one degree
//      count, then each string        every tag key and value, once
//      count, then each place:
//          element                    0 a node, 1 a way, 2 a relation
//          id                         as the step from the place before
//          point                      as the step from the place before
//          count, then each tag       two indices into the strings
//
//  Places are written by element and then by id, and steps are zigzag-encoded,
//  so a step back costs what a step forward does.
//
//  ## Compiled twice
//
//  By the app and by the tool, for the reason ``PlaceSquareGrid`` gives, so
//  this file imports Foundation and nothing of the app's. The envelope and the
//  integers are `PackedBytes.swift`'s.
//

import Foundation

/// The places filed under one square of ``PlaceSquareGrid``.
nonisolated struct PlaceSquareFile: Equatable, Sendable {
    /// Which kind of OpenStreetMap element a place is.
    nonisolated enum Element: UInt8, CaseIterable, Comparable, Sendable {
        case node = 0
        case way = 1
        case relation = 2

        /// The element's type as Overpass and ``TrailPlaceOSM`` spell it.
        var name: String {
            switch self {
            case .node: "node"
            case .way: "way"
            case .relation: "relation"
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One point, in ``coordinateScale`` units.
    nonisolated struct Point: Hashable, Sendable {
        var latitude: Int32
        var longitude: Int32
    }

    /// One place.
    nonisolated struct Place: Equatable, Sendable {
        var element: Element
        var id: Int64
        var point: Point
        /// The element's tags that ``keptTagKeys`` names.
        var tags: [String: String]
    }

    /// One kind of place: the tag that makes an element one, and whether a
    /// way or a relation carrying it is one as well as a node.
    nonisolated struct Kind: Hashable, Sendable {
        var key: String
        var value: String
        var includesAreas: Bool
    }

    /// The only version this build reads or writes. A file of another
    /// version is refused — see ``PlaceSquareGrid/generation`` for where one
    /// would be put.
    static let formatVersion: UInt8 = 1

    /// The scale the tool writes: millionths of a degree, about 11 cm, the
    /// day hikes' squares' own. See ``TrailCellFile/standardCoordinateScale``.
    static let standardCoordinateScale: Int32 = 1_000_000

    /// Every kind of place the tool files: ``TrailPointQuery/kinds`` without
    /// their symbols, which the tool cannot compile. `PlaceSquareFileTests`
    /// holds the two lists to one.
    static let kinds: [Kind] = [
        Kind(key: "natural", value: "peak", includesAreas: false),
        Kind(key: "natural", value: "saddle", includesAreas: false),
        Kind(key: "waterway", value: "waterfall", includesAreas: false),
        Kind(key: "natural", value: "spring", includesAreas: false),
        Kind(key: "amenity", value: "drinking_water", includesAreas: false),
        Kind(key: "tourism", value: "alpine_hut", includesAreas: true),
        Kind(key: "tourism", value: "wilderness_hut", includesAreas: true),
        Kind(key: "amenity", value: "shelter", includesAreas: true),
        Kind(key: "tourism", value: "viewpoint", includesAreas: false),
        Kind(key: "tourism", value: "camp_site", includesAreas: true),
        Kind(key: "amenity", value: "parking", includesAreas: false),
    ]

    /// The tags a place keeps in a square: the ones its kind is read from,
    /// its name, its Wikidata link and every fact its card shows — see
    /// ``TrailPlaceFact/Kind/tagKeys``, which `PlaceSquareFileTests` holds
    /// this to. OpenStreetMap's spellings, as its keys are.
    static let keptTagKeys: Set<String> = Set(kinds.map(\.key)).union([
        "name", "wikidata",
        "access", "capacity", "description", "drinking_water", "ele", "fee", "opening_hours", "operator",
        "phone", "contact:phone", "website", "contact:website", "url",
    ])

    /// How many coordinate units make one degree.
    var coordinateScale: Int32
    var places: [Place]

    init(places: [Place], coordinateScale: Int32 = Self.standardCoordinateScale) {
        self.places = places
        self.coordinateScale = coordinateScale
    }

    /// Whether an element carrying `tags` is a place: a node with any kind's
    /// tag, or a way or a relation with the tag of a kind that is mapped as
    /// an area — the elements ``TrailPointQuery/query(in:symbols:)`` asks for.
    static func isPlace(_ element: Element, tags: [String: String]) -> Bool {
        kinds.contains { kind in
            (element == .node || kind.includesAreas) && tags[kind.key] == kind.value
        }
    }
}

/// Why some bytes are not a square this build can read.
nonisolated enum PlaceSquareFileError: Error, Equatable {
    /// The body says something no writer of this format would.
    case corrupt
    /// The first four bytes are not this format's.
    case notASquare
    /// The bytes stop before the file does.
    case truncated
    case unsupportedCompression(UInt8)
    case unsupportedVersion(UInt8)
}

// MARK: - Writing

nonisolated extension PlaceSquareFile {
    /// The file: the envelope and the body, packed when that makes it
    /// smaller.
    func encoded() -> Data {
        PackedEnvelope.file(magic: Self.magic, version: Self.formatVersion, body: encodedBody())
    }

    /// The body alone, unpacked: what a square's digest is taken over, for
    /// the reason ``TrailCellFile/encodedBody()`` gives.
    ///
    /// The same places always give the same bytes: they are written by
    /// element and id, their tags in key order, and strings are numbered in
    /// the order they are met.
    func encodedBody() -> Data {
        var strings = PackedStringTable()
        var written = PackedWriter()
        var previousID: Int64 = 0
        var previous = Point(latitude: 0, longitude: 0)
        for place in places.sorted(by: Self.isWrittenBefore) {
            written.write(UInt64(place.element.rawValue))
            written.write(step: place.id &- previousID)
            previousID = place.id
            written.write(step: Int64(place.point.latitude) - Int64(previous.latitude))
            written.write(step: Int64(place.point.longitude) - Int64(previous.longitude))
            previous = place.point
            let tags = place.tags.sorted { $0.key < $1.key }
            written.write(UInt64(tags.count))
            for (key, value) in tags {
                written.write(strings.index(of: key))
                written.write(strings.index(of: value))
            }
        }

        var body = PackedWriter()
        body.write(UInt64(coordinateScale))
        body.write(strings: strings)
        body.write(UInt64(places.count))
        body.bytes.append(contentsOf: written.bytes)
        return Data(body.bytes)
    }

    private static func isWrittenBefore(_ lhs: Place, _ rhs: Place) -> Bool {
        (lhs.element, lhs.id) < (rhs.element, rhs.id)
    }
}

// MARK: - Reading

nonisolated extension PlaceSquareFile {
    /// Reads a file ``encoded()`` wrote.
    ///
    /// Everything is checked on the way in, for the reason
    /// ``TrailCellFile/init(decoding:)`` is: bytes that are not a square have
    /// to be an error, never a pin in an ocean.
    init(decoding file: Data) throws {
        do {
            self = try Self(body: PackedEnvelope.body(of: file, magic: Self.magic, version: Self.formatVersion))
        } catch let error as PackedFileError {
            throw PlaceSquareFileError(error)
        }
    }

    private init(body: [UInt8]) throws {
        var reader = PackedReader(bytes: body)
        let scale = try reader.readVarint()
        guard scale > 0, scale <= UInt64(Int32.max) else { throw PlaceSquareFileError.corrupt }
        let strings = try reader.readStrings()
        var places: [Place] = []
        var cursor = PlaceCursor(unitsPerDegree: Int64(scale))
        for _ in try 0..<reader.readCount() {
            places.append(try reader.readPlace(strings: strings, cursor: &cursor))
        }
        guard reader.isAtEnd else { throw PlaceSquareFileError.corrupt }
        self.init(places: places, coordinateScale: Int32(scale))
    }

    /// The four letters a square's file starts with.
    private static let magic: [UInt8] = Array("OHPS".utf8)
}

nonisolated private extension PlaceSquareFileError {
    /// The shared reader's reason, in this file's words.
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

/// Where the last place left off, which the next one steps from — and how far
/// a point may be from the equator and from Greenwich before it is not one.
nonisolated private struct PlaceCursor {
    private static let poleDegrees: Int64 = 90
    private static let antimeridianDegrees: Int64 = 180

    var id: Int64 = 0
    var latitude: Int64 = 0
    var longitude: Int64 = 0
    let unitsPerDegree: Int64

    init(unitsPerDegree: Int64) {
        self.unitsPerDegree = unitsPerDegree
    }

    /// The point the cursor stands on, or `nil` when that is off the Earth.
    /// Held between two bounds rather than measured with `abs`, for the
    /// reason the day hikes' cursor is: see `TrailCellFile.swift`.
    var point: PlaceSquareFile.Point? {
        let pole = Self.poleDegrees * unitsPerDegree
        let antimeridian = Self.antimeridianDegrees * unitsPerDegree
        guard (-pole...pole).contains(latitude),
              (-antimeridian...antimeridian).contains(longitude),
              let north = Int32(exactly: latitude),
              let east = Int32(exactly: longitude)
        else { return nil }
        return PlaceSquareFile.Point(latitude: north, longitude: east)
    }
}

nonisolated private extension PackedReader {
    mutating func readPlace(strings: [String], cursor: inout PlaceCursor) throws -> PlaceSquareFile.Place {
        let elementCode = try readVarint()
        guard elementCode <= UInt64(UInt8.max),
              let element = PlaceSquareFile.Element(rawValue: UInt8(elementCode))
        else { throw PlaceSquareFileError.corrupt }
        cursor.id &+= try readStep()
        cursor.latitude &+= try readStep()
        cursor.longitude &+= try readStep()
        guard let point = cursor.point else { throw PlaceSquareFileError.corrupt }
        var tags: [String: String] = [:]
        for _ in try 0..<readCount() {
            let key = try readIndexedString(strings)
            tags[key] = try readIndexedString(strings)
        }
        return PlaceSquareFile.Place(element: element, id: cursor.id, point: point, tags: tags)
    }
}
