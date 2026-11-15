//
//  TrailGraphSquareFileTests.swift
//  OpenHikesTests
//
//  What one square of trails is as bytes, and the two rules the tool that
//  writes it shares with the Overpass decoder: which trails may be walked, and
//  which hiking route names one.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail graph square file")
struct TrailGraphSquareFileTests {
    static let path = TrailGraphSquareFile.Way(
        id: 10,
        highway: "path",
        tags: [.name: "Local Path", .hikingRoute: "Alpine Route", .surface: "gravel", .tracktype: "grade2"],
        nodes: [
            TrailGraphSquareFile.Node(id: 1, latitude: 47_630_000, longitude: 12_860_000),
            TrailGraphSquareFile.Node(id: 2, latitude: 47_631_000, longitude: 12_860_000),
        ]
    )
    static let steps = TrailGraphSquareFile.Way(
        id: 7,
        highway: "steps",
        tags: [.sacScale: "mountain_hiking", .trailVisibility: "good", .access: "yes"],
        nodes: [
            TrailGraphSquareFile.Node(id: 2, latitude: 47_631_000, longitude: 12_860_000),
            TrailGraphSquareFile.Node(id: 9_000_000_001, latitude: -33_900_000, longitude: -70_100_000),
        ]
    )

    @Test("a square reads back as the trails it was written with, by id")
    func aSquareRoundTrips() throws {
        let file = TrailGraphSquareFile(ways: [Self.path, Self.steps])

        let read = try TrailGraphSquareFile(decoding: file.encoded())

        #expect(read.ways == [Self.steps, Self.path])
        #expect(read.encodedBody() == file.encodedBody(), "the same trails give the same body in any order")
    }

    @Test("bytes that are not a square are refused, never read as trails")
    func otherBytesAreRefused() {
        let offTheEarth = TrailGraphSquareFile(ways: [
            TrailGraphSquareFile.Way(
                id: 1,
                highway: "path",
                tags: [:],
                nodes: [TrailGraphSquareFile.Node(id: 1, latitude: 91_000_000, longitude: 0)]
            ),
        ])

        #expect(throws: TrailGraphSquareFileError.notASquare) {
            try TrailGraphSquareFile(decoding: TrailCellFile(relations: []).encoded())
        }
        #expect(throws: TrailGraphSquareFileError.truncated) {
            try TrailGraphSquareFile(decoding: TrailGraphSquareFile(ways: [Self.path]).encoded().prefix(5))
        }
        #expect(throws: TrailGraphSquareFileError.corrupt) {
            try TrailGraphSquareFile(decoding: offTheEarth.encoded())
        }
    }

    /// The rule both the tool and the Overpass decoder apply, so a trail is
    /// walkable or not whichever brought it.
    @Test("a trail may be walked unless foot or access says no, and foot outranks access")
    func whoMayWalk() {
        #expect(TrailGraphSquareFile.permitsWalking(["highway": "path"]))
        #expect(!TrailGraphSquareFile.permitsWalking(["foot": "no"]))
        #expect(!TrailGraphSquareFile.permitsWalking(["access": "private"]))
        #expect(TrailGraphSquareFile.permitsWalking(["access": "private", "foot": "designated"]))
        #expect(!TrailGraphSquareFile.permitsWalking(["access": "yes", "foot": "private"]))
        #expect(
            OverpassTrailGraphProvider.permitsWalking(["access": "no"])
                == TrailGraphSquareFile.permitsWalking(["access": "no"])
        )
    }

    @Test("a hiking route names its ways by name, else by number, and the first in order wins")
    func routeNames() {
        #expect(TrailGraphSquareFile.hikingRouteName(["route": "hiking", "name": "Alpine Route"]) == "Alpine Route")
        #expect(TrailGraphSquareFile.hikingRouteName(["route": "hiking", "ref": "E4"]) == "E4")
        #expect(TrailGraphSquareFile.hikingRouteName(["route": "bicycle", "name": "Velo"]) == nil)
        #expect(TrailGraphSquareFile.hikingRouteName(of: ["Zugspitzweg", "Alpine Route"]) == "Alpine Route")
    }
}
