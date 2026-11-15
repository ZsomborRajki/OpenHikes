//
//  PackedSquareFormat.swift
//  OpenHikesTests
//
//  The two files written in `PackedBytes.swift`'s format — the day hikes'
//  squares and the hiking-routes layer's — for a suite of the shared reader
//  and envelope to hold to the same contract through each file's own
//  decoder, which is what a hiker's map reads them with.
//

import Foundation
@testable import OpenHikes
import Testing

/// One of the two files written in the packed format.
nonisolated enum PackedSquareFormat: CaseIterable, CustomTestStringConvertible {
    /// ``TrailCellFile``, OpenStreetMap's day hikes by square.
    case dayHikes
    /// ``RouteSquareFile``, the hiking-routes layer by square.
    case hikingRoutes

    var testDescription: String {
        switch self {
        case .dayHikes: "a day hikes' square"
        case .hikingRoutes: "a hiking-routes square"
        }
    }

    /// The bytes after the scale of a square with nothing in it: no strings
    /// and no routes, and for the layer no lines either.
    var emptyAfterScale: [UInt8] {
        let body = switch self {
        case .dayHikes: TrailCellFile(relations: [], coordinateScale: 1).encodedBody()
        case .hikingRoutes: RouteSquareFile(routes: [], lines: [], coordinateScale: 1).encodedBody()
        }
        return Array(body.dropFirst())
    }

    /// The body of a square holding one route of `count` points a step
    /// apart: a body DEFLATE shrinks, as it does every busy square.
    func body(points count: Int) -> [UInt8] {
        switch self {
        case .dayHikes: Array(Self.dayHikeSquare(points: count).encodedBody())
        case .hikingRoutes: Array(Self.routeSquare(points: count).encodedBody())
        }
    }

    /// The scale of the square `file` reads as, through this format's
    /// decoder.
    func coordinateScale(of file: Data) throws -> Int32 {
        switch self {
        case .dayHikes: try TrailCellFile(decoding: file).coordinateScale
        case .hikingRoutes: try RouteSquareFile(decoding: file).coordinateScale
        }
    }

    /// Whether `file` reads, through this format's decoder, as the square
    /// ``body(points:)`` is the body of.
    func reads(_ file: Data, asSquareOf count: Int) throws -> Bool {
        switch self {
        case .dayHikes: try TrailCellFile(decoding: file) == Self.dayHikeSquare(points: count)
        case .hikingRoutes: try RouteSquareFile(decoding: file) == Self.routeSquare(points: count)
        }
    }

    /// Expects this format's decoder to refuse `file` as corrupt, in the
    /// file's own words.
    func expectCorrupt(
        _ file: Data,
        _ comment: Comment? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        switch self {
        case .dayHikes:
            #expect(throws: TrailCellFileError.corrupt, comment, sourceLocation: sourceLocation) {
                try TrailCellFile(decoding: file)
            }

        case .hikingRoutes:
            #expect(throws: PackedFileError.corrupt, comment, sourceLocation: sourceLocation) {
                try RouteSquareFile(decoding: file)
            }
        }
    }

    /// A file of this format holding `body` as the envelope writes it:
    /// packed when that makes it smaller, stored as it is when not.
    func file(body: [UInt8]) -> Data {
        PackedEnvelope.file(magic: magic, version: version, body: Data(body))
    }

    /// A file of this format whose envelope says its body unpacks to
    /// `length` bytes, followed by `packed` as the DEFLATE stream of it —
    /// which may say otherwise.
    func file(declaring length: Int, packed: [UInt8]) -> Data {
        var file = Data(magic)
        file.append(version)
        file.append(PackedEnvelope.Method.deflate.rawValue)
        file.append(contentsOf: PackedVarint.bytes(of: UInt64(length)))
        file.append(contentsOf: packed)
        return file
    }

    private var magic: [UInt8] {
        switch self {
        case .dayHikes: Array("OHTC".utf8)
        case .hikingRoutes: Array("OHRS".utf8)
        }
    }

    private var version: UInt8 {
        switch self {
        case .dayHikes: TrailCellFile.formatVersion
        case .hikingRoutes: RouteSquareFile.formatVersion
        }
    }

    private static func vertices(_ count: Int) -> [(latitude: Int32, longitude: Int32)] {
        (0..<Int32(count)).map { (latitude: $0, longitude: 2 * $0) }
    }

    private static func dayHikeSquare(points count: Int) -> TrailCellFile {
        let points = vertices(count).map { TrailCellFile.Point(latitude: $0.latitude, longitude: $0.longitude) }
        return TrailCellFile(relations: [
            TrailCellFile.Relation(
                id: 1,
                tags: ["name": "Loop", "route": "hiking"],
                ways: [TrailCellFile.Way(role: "", points: points)]
            ),
        ])
    }

    private static func routeSquare(points count: Int) -> RouteSquareFile {
        let points = vertices(count).map { RouteSquareFile.Point(latitude: $0.latitude, longitude: $0.longitude) }
        return RouteSquareFile(
            routes: [RouteSquareFile.Route(id: 1, tags: ["name": "Loop"])],
            lines: [RouteSquareFile.Line(network: .local, routes: [0], points: points)],
            coordinateScale: TrailCellFile.standardCoordinateScale
        )
    }
}
