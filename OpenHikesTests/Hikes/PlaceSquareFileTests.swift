//
//  PlaceSquareFileTests.swift
//  OpenHikesTests
//
//  What one square of places is as bytes, and the two lists the tool that
//  writes it carries in place of the app's: which elements are places, and
//  which of their tags are kept.
//
//  The tool compiles the file this tests and cannot compile
//  ``TrailPointQuery``, so the kinds are written twice. The case below that
//  holds the two to one answer is what keeps a square from filing a kind no
//  search asks for, or leaving out one every search does.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Place square file")
struct PlaceSquareFileTests {
    private static let peak = PlaceSquareFile.Place(
        element: .node,
        id: 26_863_613,
        point: PlaceSquareFile.Point(latitude: 47_593_738, longitude: 13_067_046),
        tags: ["ele": "2522", "name": "Hoher Göll, „Gipfel“ = 100%", "natural": "peak", "wikidata": "Q694427"]
    )
    private static let hut = PlaceSquareFile.Place(
        element: .way,
        id: 31_008_412,
        point: PlaceSquareFile.Point(latitude: 47_563_041, longitude: 12_936_290),
        tags: ["name": "Kärlingerhaus", "tourism": "alpine_hut"]
    )
    private static let shelter = PlaceSquareFile.Place(
        element: .relation,
        id: 1234,
        point: PlaceSquareFile.Point(latitude: -33_900_000, longitude: -70_100_000),
        tags: ["amenity": "shelter"]
    )

    @Test("a square reads back as the places it was written with")
    func aSquareRoundTrips() throws {
        let file = PlaceSquareFile(places: [Self.peak, Self.hut, Self.shelter])

        let read = try PlaceSquareFile(decoding: file.encoded())

        #expect(read == file)
    }

    /// A square's digest is taken over its body, so the same places have to
    /// give the same bytes however a build met them.
    @Test("the same places give the same body, in whatever order they came")
    func theBodyIsDeterministic() throws {
        let forward = PlaceSquareFile(places: [Self.peak, Self.hut, Self.shelter])
        let backward = PlaceSquareFile(places: [Self.shelter, Self.hut, Self.peak])

        let read = try PlaceSquareFile(decoding: backward.encoded())

        #expect(forward.encodedBody() == backward.encodedBody())
        #expect(read.places.map(\.id) == [Self.peak, Self.hut, Self.shelter].map(\.id), "by element, then by id")
    }

    @Test("bytes that are not a square are refused, never read as places")
    func otherBytesAreRefused() {
        let encoded = PlaceSquareFile(places: [Self.peak]).encoded()
        let offTheEarth = PlaceSquareFile(places: [
            PlaceSquareFile.Place(
                element: .node,
                id: 1,
                point: PlaceSquareFile.Point(latitude: 91_000_000, longitude: 0),
                tags: [:]
            ),
        ])

        #expect(throws: PlaceSquareFileError.notASquare) {
            try PlaceSquareFile(decoding: TrailCellFile(relations: []).encoded())
        }
        // Cut inside the envelope: a body cut short is a packed stream that
        // does not unpack, which is `corrupt`.
        #expect(throws: PlaceSquareFileError.truncated) {
            try PlaceSquareFile(decoding: encoded.prefix(5))
        }
        #expect(throws: PlaceSquareFileError.corrupt) {
            try PlaceSquareFile(decoding: offTheEarth.encoded())
        }
    }

    @Test("the tool files exactly the kinds a place search asks for")
    func theKindsAreTheQuerysKinds() {
        let asked = TrailPointQuery.kinds.map { kind in
            PlaceSquareFile.Kind(key: kind.key, value: kind.value, includesAreas: kind.includesAreas)
        }

        #expect(PlaceSquareFile.kinds == asked)
    }

    @Test("a square keeps every tag a place, its symbol and its card are read from")
    func theKeptTagsAreEveryTagRead() {
        let read = Set(TrailPlaceFact.Kind.allCases.flatMap(\.tagKeys))
            .union(TrailPointQuery.kinds.map(\.key))
            .union(["name", "wikidata"])

        #expect(PlaceSquareFile.keptTagKeys == read)
    }

    /// The shape of ``TrailPointQuery/query(in:symbols:)``: every kind as a
    /// node, and only some as ways and relations.
    @Test("a node of any kind is a place, and a way or a relation only of a kind mapped as an area")
    func whatIsAPlace() {
        #expect(PlaceSquareFile.isPlace(.node, tags: ["amenity": "parking"]))
        #expect(!PlaceSquareFile.isPlace(.way, tags: ["amenity": "parking"]))
        #expect(PlaceSquareFile.isPlace(.way, tags: ["tourism": "alpine_hut"]))
        #expect(PlaceSquareFile.isPlace(.relation, tags: ["amenity": "shelter", "building": "yes"]))
        #expect(!PlaceSquareFile.isPlace(.node, tags: ["tourism": "information"]))
    }
}
