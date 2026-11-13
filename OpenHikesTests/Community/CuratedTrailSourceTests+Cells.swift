//
//  CuratedTrailSourceTests+Cells.swift
//  OpenHikesTests
//
//  A search the pre-built squares answer: Overpass is asked nothing, and what
//  comes back is what Overpass would have said.
//
//  Like the rest of the suite this is asserted on requests, because the point
//  of the squares is the request that is not made — a version that fetched
//  them and then asked Overpass anyway would draw exactly these rows, half a
//  minute later. The other half is the case with both sources in it: the same
//  relations as an Overpass answer and as a square have to become the same
//  routes, which is what lets everything after the first request — the cache,
//  the map's lines, the hike that is opened — not know which of the two it
//  was.
//

import Foundation
@testable import OpenHikes
import Testing

// The coordinates of five routes, which are the fixture and have no better
// names than their own digits.
// swiftlint:disable no_magic_numbers

extension CuratedTrailSourceTests {
    /// The two squares within reach of ``visibleArea``, and routes for them.
    private enum Squares {
        static let west = "trails1_550_771"
        static let east = "trails1_550_772"

        /// ``geometryBody``'s two routes, as a square holds them.
        static let nearLoop = TrailCellFile.Relation(
            id: 11,
            tags: ["name": "Near Loop", "route": "hiking", "roundtrip": "yes"],
            ways: [way("", [(47.62, 12.97), (47.628, 12.98)])]
        )
        static let farPath = TrailCellFile.Relation(
            id: 22,
            tags: ["name": "Far Path", "route": "hiking"],
            ways: [way("", [(47.7, 13.05), (47.708, 13.06)])]
        )

        /// A route with a branch off it, which only the role tells from the
        /// route: two ways that join, and an `alternative` leaving the joint.
        static let forkedRidge = TrailCellFile.Relation(
            id: 55,
            tags: ["name": "Forked Ridge", "route": "hiking", "network": "lwn"],
            ways: [
                way("", [(47.61, 12.95), (47.615, 12.96)]),
                way("", [(47.615, 12.96), (47.62, 12.965)]),
                way("alternative", [(47.615, 12.96), (47.63, 12.99)]),
            ]
        )
        /// Two pieces of one length that do not join: nothing to draw.
        static let brokenPath = TrailCellFile.Relation(
            id: 44,
            tags: ["name": "Broken Path", "route": "hiking"],
            ways: [
                way("", [(47.61, 12.96), (47.615, 12.965)]),
                way("", [(47.625, 12.985), (47.63, 12.99)]),
            ]
        )
        /// A path that starts on the map and ends in another country.
        static let continentalWay = TrailCellFile.Relation(
            id: 33,
            tags: ["name": "Continental Way", "route": "hiking"],
            ways: [way("", [(47.6, 12.94), (49, 15)])]
        )

        static func way(_ role: String, _ points: [(Double, Double)]) -> TrailCellFile.Way {
            TrailCellFile.Way(role: role, points: points.map { TrailCellFixture.point($0.0, $0.1) })
        }
    }

    /// The same four relations ``Squares`` holds, as Overpass answers them:
    /// the box of each is the extent of its ways, which is the box a square's
    /// reader works out.
    private static let sameRoutesFromOverpass = """
    {"elements":[
        {"type":"relation","id":11,"tags":{"name":"Near Loop","route":"hiking","roundtrip":"yes"},
        "bounds":{"minlat":47.62,"minlon":12.97,"maxlat":47.628,"maxlon":12.98},
        "members":[{"type":"way","role":"","geometry":[
            {"lat":47.62,"lon":12.97},{"lat":47.628,"lon":12.98}]}]},
        {"type":"relation","id":55,"tags":{"name":"Forked Ridge","route":"hiking","network":"lwn"},
        "bounds":{"minlat":47.61,"minlon":12.95,"maxlat":47.63,"maxlon":12.99},
        "members":[
            {"type":"way","role":"","geometry":[{"lat":47.61,"lon":12.95},{"lat":47.615,"lon":12.96}]},
            {"type":"way","role":"","geometry":[{"lat":47.615,"lon":12.96},{"lat":47.62,"lon":12.965}]},
            {"type":"way","role":"alternative","geometry":[{"lat":47.615,"lon":12.96},{"lat":47.63,"lon":12.99}]}]},
        {"type":"relation","id":44,"tags":{"name":"Broken Path","route":"hiking"},
        "bounds":{"minlat":47.61,"minlon":12.96,"maxlat":47.63,"maxlon":12.99},
        "members":[
            {"type":"way","role":"","geometry":[{"lat":47.61,"lon":12.96},{"lat":47.615,"lon":12.965}]},
            {"type":"way","role":"","geometry":[{"lat":47.625,"lon":12.985},{"lat":47.63,"lon":12.99}]}]},
        {"type":"relation","id":33,"tags":{"name":"Continental Way","route":"hiking"},
        "bounds":{"minlat":47.6,"minlon":12.94,"maxlat":49,"maxlon":15},
        "members":[{"type":"way","role":"","geometry":[{"lat":47.6,"lon":12.94},{"lat":49,"lon":15}]}]}
    ]}
    """

    /// A source whose squares are `database`, and the Overpass it falls back
    /// to. The library keeps nothing on disk, so every search is a request to
    /// the stub and a case can count them.
    private static func makeSource(
        squares database: StubTrailCellDatabase,
        overpass responses: [OverpassHTTPResponse] = []
    ) -> (CuratedTrailSource, CuratedTransportStub) {
        makeSource(responses, cells: TrailCellLibrary(database: database, directory: nil))
    }

    private static var squaresOfTheValley: StubTrailCellDatabase {
        StubTrailCellDatabase(cells: [
            Squares.west: TrailCellFixture.found([Squares.nearLoop]),
            Squares.east: TrailCellFixture.found([Squares.farPath]),
        ])
    }

    // MARK: - The request that is not made

    @Test("a search the squares answer asks Overpass nothing")
    func theSquaresAnswer() async throws {
        let database = Self.squaresOfTheValley
        let (source, overpass) = Self.makeSource(squares: database)

        let completion = try await Self.completion(source, area: Self.visibleArea)

        #expect(completion.trails.map(\.relationID) == [11])
        #expect(completion.trails.allSatisfy { $0.route.count > 1 }, "the rows arrive with their lines")
        #expect(completion.outage == nil)
        #expect(database.requests == [[Squares.west, Squares.east]])
        #expect(await overpass.requestCount == 0)
    }

    @Test("a route the squares offered is opened, and found by name, without asking anybody")
    func whatTheSquaresOfferedIsKept() async throws {
        let database = Self.squaresOfTheValley
        let (source, overpass) = Self.makeSource(squares: database)

        _ = try await Self.search(source, area: Self.visibleArea)
        let opened = try await source.trail(of: 11)
        let named = await source.trails(matching: "loop", limit: 5)

        #expect(opened?.name == "Near Loop")
        #expect(named.map(\.relationID) == [11])
        #expect(database.requests.count == 1)
        #expect(await overpass.requestCount == 0)
    }

    /// The wait the squares are for is longest here: a wide search is two
    /// turns in Overpass's queue.
    @Test("a wide search the squares answer comes with its lines, and makes no second pass")
    func aWideSearchNeedsNoGeometryPass() async throws {
        let database = Self.squaresOfTheValley
        let (source, overpass) = Self.makeSource(squares: database)
        let wide = CommunitySearchArea(
            coordinate: Self.visibleArea.coordinate,
            radiusMeters: CommunityQueryPolicy.minimumRadiusMeters * 2,
            visibleSpan: CommunitySearchArea.Span(latitudeDelta: 0.36, longitudeDelta: 0.4)
        )

        let completion = try await Self.completion(source, area: wide)

        #expect(completion.trails.map(\.relationID) == [11, 22], "nearest first, as an Overpass answer is")
        #expect(completion.trails.allSatisfy { $0.route.count > 1 })
        #expect(database.requests.count == 1)
        #expect(await overpass.requestCount == 0)
    }

    /// The answer the squares can give that Overpass never could quickly.
    /// Asking Overpass to confirm it would bring the wait back for every
    /// search beside a lake.
    @Test("no trails in the squares is an answer, and Overpass is not asked to confirm it")
    func noTrailsIsAnAnswer() async throws {
        let (source, overpass) = Self.makeSource(squares: StubTrailCellDatabase(manifest: .complete))

        let listed = try await source.listings(near: Self.visibleArea, limit: 25)

        #expect(listed.isEmpty)
        #expect(await overpass.requestCount == 0)
    }

    // MARK: - Where the squares have no answer

    @Test(
        "where the squares do not reach, Overpass is asked as it always was",
        arguments: [TrailCellFetch.Manifest.absent, .partial]
    )
    func whereTheSquaresDoNotReach(manifest: TrailCellFetch.Manifest) async throws {
        let (source, overpass) = Self.makeSource(
            squares: StubTrailCellDatabase(manifest: manifest),
            overpass: [Self.ok(Self.areaWithLinesBody)]
        )

        let trails = try await Self.search(source, area: Self.visibleArea)

        #expect(trails.map(\.relationID) == [11, 22])
        #expect(await overpass.requestCount == 1)
    }

    @Test("squares that cannot be read send the search to Overpass")
    func squaresThatCannotBeRead() async throws {
        let database = Self.squaresOfTheValley
        database.fail(with: URLError(.timedOut))
        let (source, overpass) = Self.makeSource(squares: database, overpass: [Self.ok(Self.areaWithLinesBody)])

        let trails = try await Self.search(source, area: Self.visibleArea)

        #expect(trails.map(\.relationID) == [11, 22])
        #expect(await overpass.requestCount == 1)
    }

    /// Both out of reach is the old outage, raised the old way, for
    /// ``MergedCommunityTransport`` to report and fall back from.
    @Test("with the squares and Overpass both out of reach, the search fails as an Overpass search does")
    func bothOutOfReach() async throws {
        let database = Self.squaresOfTheValley
        database.fail(with: URLError(.timedOut))
        let (source, _) = Self.makeSource(
            squares: database,
            overpass: [OverpassHTTPResponse(data: Data(), statusCode: Self.httpRateLimited, headers: [:])]
        )

        await #expect(throws: TrailGraphProviderError.self) {
            try await source.listings(near: Self.visibleArea, limit: 25)
        }
    }

    // MARK: - One answer, from either

    @Test("the same relations become the same routes, from a square and from Overpass")
    func aSquareAndOverpassAgree() async throws {
        let relations = [Squares.nearLoop, Squares.forkedRidge, Squares.brokenPath, Squares.continentalWay]
        let (fromSquares, _) = Self.makeSource(
            squares: StubTrailCellDatabase(cells: [Squares.west: TrailCellFixture.found(relations)])
        )
        let (fromOverpass, _) = Self.makeSource([Self.ok(Self.sameRoutesFromOverpass)])

        let squares = try await Self.search(fromSquares, area: Self.visibleArea)
        let overpass = try await Self.search(fromOverpass, area: Self.visibleArea)

        #expect(overpass.map(\.relationID) == [55, 11], "the broken path and the continental one are not offered")
        #expect(squares == overpass)
        #expect(squares.first?.route.count == 3, "the ridge is its two main ways, and not the branch off them")
    }
}

// swiftlint:enable no_magic_numbers
