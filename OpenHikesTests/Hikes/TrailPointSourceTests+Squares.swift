//
//  TrailPointSourceTests+Squares.swift
//  OpenHikesTests
//
//  A place search the pre-built squares answer: Overpass is asked nothing, and
//  what comes back is what Overpass would have said.
//
//  Asserted on requests, like the day hikes' version of these cases, because
//  the point of the squares is the request that is not made — a source that
//  read them and then asked Overpass anyway would offer exactly these places,
//  half a minute later.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

// The coordinates of three places, which are the fixture and have no better
// names than their own digits.
// swiftlint:disable no_magic_numbers

extension TrailPointSourceTests {
    private enum Squares {
        static let area = CommunitySearchArea(
            coordinate: CLLocationCoordinate2D(latitude: 47.62, longitude: 12.90),
            radiusMeters: 3000
        )
        static let valley = "places1_137_192"

        /// The summit Overpass answers with below, as a square holds it.
        static let summit = PlaceSquareLibraryTests.node(1, 47.60, 12.88, ["natural": "peak", "name": "Watzmann"])
        static let spring = PlaceSquareLibraryTests.node(2, 47.61, 12.89, ["natural": "spring"])

        /// An Overpass answer of the summit and a waterfall the squares do
        /// not hold.
        static let overpassBody = """
        {"elements": [
        {"type": "node", "id": 1, "lat": 47.60, "lon": 12.88, "tags": {"natural": "peak", "name": "Watzmann"}},
        {"type": "node", "id": 9, "lat": 47.625, "lon": 12.905, "tags": {"waterway": "waterfall"}}
        ]}
        """

        static func makeSource(
            _ database: StubTrailCellDatabase,
            squares: URL? = nil,
            store: URL? = nil,
            overpass: [OverpassHTTPResponse] = []
        ) -> (TrailPointSource, CuratedTransportStub) {
            let stub = CuratedTransportStub(responses: overpass)
            let library = PlaceSquareLibrary(database: database, directory: squares, clock: TestClock().read)
            let source = TrailPointSource(
                pause: { _ in /* nothing waits in a suite */ },
                directory: store,
                squares: library,
                transport: { request in await stub.answer(request) }
            )
            return (source, stub)
        }

        static func ok(_ json: String) -> OverpassHTTPResponse {
            OverpassHTTPResponse(data: Data(json.utf8), statusCode: 200, headers: [:])
        }
    }

    @Test("a search the squares answer asks Overpass nothing")
    func squaresAnswerWithoutOverpass() async throws {
        let database = StubTrailCellDatabase(cells: [
            Squares.valley: PlaceSquareLibraryTests.found([Squares.summit, Squares.spring]),
        ])
        let (source, overpass) = Squares.makeSource(database)

        let places = try await source.places(near: Squares.area)

        #expect(await overpass.requestCount == 0)
        #expect(database.requests == [[Squares.valley]])
        #expect(places.compactMap(\.osm?.elementID).sorted() == [1, 2])
    }

    /// Nothing of the kinds asked for is mapped here, and the squares can say
    /// so: Overpass is not asked to confirm it.
    @Test("an empty answer from the squares is an answer")
    func anEmptyAnswerIsAnAnswer() async throws {
        let (source, overpass) = Squares.makeSource(StubTrailCellDatabase())

        let places = try await source.places(near: Squares.area)

        #expect(places.isEmpty)
        #expect(await overpass.requestCount == 0)
    }

    @Test("where the squares give no answer, Overpass is asked as it always was", arguments: [
        TrailCellFetch.Manifest.absent, .partial, .unread,
    ])
    func noAnswerAsksOverpass(manifest: TrailCellFetch.Manifest) async throws {
        let database = StubTrailCellDatabase(manifest: manifest)
        let (source, overpass) = Squares.makeSource(database, overpass: [Squares.ok(Squares.overpassBody)])

        let places = try await source.places(near: Squares.area)

        #expect(await overpass.requestCount == 1)
        #expect(places.compactMap(\.osm?.elementID) == [1, 9])
    }

    /// What *Add Place* offers before its search answers: the squares kept on
    /// this device and the places earlier Overpass searches wrote down, each
    /// place once.
    @Test("the device's places are its kept squares and its stored answers, each place once")
    func cachedPlacesReadBoth() async throws {
        let squares = PlaceSquareLibraryTests.scratchDirectory()
        let store = PlaceSquareLibraryTests.scratchDirectory()
        defer {
            try? FileManager.default.removeItem(at: squares)
            try? FileManager.default.removeItem(at: store)
        }
        // First a search the squares cannot answer, so it is Overpass's and
        // its answer goes into the store; then one, over the same squares'
        // directory, that keeps the square.
        let (source, overpass) = Squares.makeSource(
            StubTrailCellDatabase(manifest: .partial),
            squares: squares,
            store: store,
            overpass: [Squares.ok(Squares.overpassBody)]
        )
        _ = try await source.places(near: Squares.area)
        let world = StubTrailCellDatabase(cells: [
            Squares.valley: PlaceSquareLibraryTests.found([Squares.summit, Squares.spring]),
        ])
        let (keeping, _) = Squares.makeSource(world, squares: squares)
        _ = try await keeping.places(near: Squares.area)

        let cached = await source.cachedPlaces(near: Squares.area, limit: 10)

        #expect(await overpass.requestCount == 1)
        #expect(cached.compactMap(\.osm?.elementID).sorted() == [1, 2, 9])
    }
}

// swiftlint:enable no_magic_numbers
