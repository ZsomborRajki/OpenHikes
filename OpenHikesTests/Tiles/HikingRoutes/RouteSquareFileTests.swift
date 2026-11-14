//
//  RouteSquareFileTests.swift
//  OpenHikesTests
//
//  A hiking-routes square written and read back, and the bytes that must be
//  refused rather than drawn: what arrives here came over a network.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Route square file")
struct RouteSquareFileTests {
    private static let file = RouteSquareFile(
        routes: [
            RouteSquareFile.Route(id: 18_722, tags: ["name": "Voralpenweg 04", "network": "nwn", "ref": "04"]),
            RouteSquareFile.Route(
                id: 222_517,
                tags: ["name": "AV Weg 443", "network": "lwn", "osmc:symbol": "red:white:red_bar"]
            ),
        ],
        lines: [
            RouteSquareFile.Line(
                network: .national,
                routes: [0, 1],
                points: [
                    RouteSquareFile.Point(latitude: 47_591_000, longitude: 12_988_000),
                    RouteSquareFile.Point(latitude: 47_592_500, longitude: 12_989_250),
                ]
            ),
            RouteSquareFile.Line(
                network: .local,
                routes: [1],
                points: [
                    RouteSquareFile.Point(latitude: 47_592_500, longitude: 12_989_250),
                    RouteSquareFile.Point(latitude: 47_590_000, longitude: 12_970_000),
                    RouteSquareFile.Point(latitude: -33_900_000, longitude: -151_200_000),
                ]
            ),
        ],
        coordinateScale: 1_000_000
    )

    @Test("a square reads back as it was written")
    func roundTrip() throws {
        #expect(try RouteSquareFile(decoding: Self.file.encoded()) == Self.file)
    }

    @Test("an empty square reads back empty")
    func emptyRoundTrip() throws {
        let empty = RouteSquareFile(routes: [], lines: [], coordinateScale: 1)
        #expect(try RouteSquareFile(decoding: empty.encoded()) == empty)
    }

    /// The digest the upload compares is taken over this, so the same lines
    /// have to give the same bytes whatever order a dictionary hands the tags
    /// over in.
    @Test("the same square always gives the same body")
    func stableBody() {
        var shuffled = Self.file
        shuffled.routes[0].tags = Dictionary(uniqueKeysWithValues: Self.file.routes[0].tags.reversed())
        #expect(shuffled.encodedBody() == Self.file.encodedBody())
    }

    @Test("the other set's squares are not read as this one's")
    func dayHikeSquaresAreRefused() {
        let dayHikes = TrailCellFile(relations: []).encoded()
        #expect(throws: PackedFileError.wrongFormat) { try RouteSquareFile(decoding: dayHikes) }
        #expect(throws: TrailCellFileError.notACell) { try TrailCellFile(decoding: Self.file.encoded()) }
    }

    @Test("a square cut short is refused")
    func truncated() {
        let bytes = Self.file.encoded()
        for length in [0, 3, 6, bytes.count - 1] {
            #expect(throws: PackedFileError.self) { try RouteSquareFile(decoding: bytes.prefix(length)) }
        }
    }

    @Test("a line naming a route the square does not hold is refused")
    func routeIndexOutOfRange() {
        var broken = Self.file
        broken.lines[0].routes = [2]
        #expect(throws: PackedFileError.corrupt) { try RouteSquareFile(decoding: broken.encoded()) }
    }

    @Test("a point off the Earth is refused")
    func pointOffTheEarth() {
        var broken = Self.file
        broken.lines[0].points[0] = RouteSquareFile.Point(latitude: 91_000_000, longitude: 0)
        #expect(throws: PackedFileError.corrupt) { try RouteSquareFile(decoding: broken.encoded()) }
    }

    @Test("a network this build does not know is refused")
    func unknownNetwork() throws {
        // The first line's network is the byte after the route table; a body
        // is rewritten with a sixth network there, and the envelope rebuilt.
        let body = Array(Self.file.encodedBody())
        let networkIndex = try #require(networkOffset(in: body))
        var broken = body
        broken[networkIndex] = 5
        let rebuilt = PackedEnvelope.file(
            magic: Array("OHRS".utf8),
            version: RouteSquareFile.formatVersion,
            body: Data(broken)
        )
        #expect(throws: PackedFileError.corrupt) { try RouteSquareFile(decoding: rebuilt) }
    }

    /// Where the first line's network byte sits: after the scale, the
    /// strings, the routes and the line count, all of which this square
    /// writes in known lengths. Found by encoding the same square without its
    /// lines and counting.
    private func networkOffset(in body: [UInt8]) -> Int? {
        let withoutLines = RouteSquareFile(
            routes: Self.file.routes,
            lines: [],
            coordinateScale: Self.file.coordinateScale
        )
        let prefix = withoutLines.encodedBody().count
        // The line count is one byte for two lines, written where the empty
        // file wrote its zero; the network follows it.
        guard prefix <= body.count else { return nil }
        return prefix
    }
}
