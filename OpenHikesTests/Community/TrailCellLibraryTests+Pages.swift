//
//  TrailCellLibraryTests+Pages.swift
//  OpenHikesTests
//
//  What a search wider than a valley asks of the squares: a page of what they
//  hold rather than all of it, as many squares as a map two hundred
//  kilometres across reads, and a fetch that may not finish in one try.
//
//  The answers are the same kind as next door's, an answer or none. What
//  these cases add is the part of each that grows with the width of the
//  search: which rows a page keeps, how many squares one request names, and
//  what a search that got some of them leaves for the next.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

// The coordinates of four routes and the latitudes of six searches, which
// have no better names than their own digits.
// swiftlint:disable no_magic_numbers

extension TrailCellLibraryTests {
    // MARK: - Fixtures

    /// In the valley, two kilometres south-west of its middle.
    private static let middlePath = TrailCellFixture.relation(
        66,
        name: "Middle Path",
        from: TrailCellFixture.point(47.605, 12.945),
        to: TrailCellFixture.point(47.61, 12.95)
    )
    /// In the valley's north-east corner, the furthest of the three.
    private static let edgeTrack = TrailCellFixture.relation(
        77,
        name: "Edge Track",
        from: TrailCellFixture.point(47.635, 12.995),
        to: TrailCellFixture.point(47.64, 13)
    )
    /// Two pieces of one length around the valley's middle that do not join:
    /// the nearest route there is, with nothing to draw.
    private static let brokenPath = TrailCellFile.Relation(
        id: 88,
        tags: ["name": "Broken Path", "route": "hiking"],
        ways: [
            TrailCellFile.Way(
                role: "",
                points: [TrailCellFixture.point(47.619, 12.969), TrailCellFixture.point(47.6195, 12.9695)]
            ),
            TrailCellFile.Way(
                role: "",
                points: [TrailCellFixture.point(47.6205, 12.9705), TrailCellFixture.point(47.621, 12.971)]
            ),
        ]
    )

    private static func searchCenter(atLatitude latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: 15)
    }

    /// The widest map the app searches, at `latitude`, as the squares are
    /// asked about it. A hair inside the ceiling, so that the arithmetic of
    /// building it cannot land a hair outside.
    private static func widestSearch(atLatitude latitude: Double) -> [CuratedTrailQuery.BoundingBox] {
        let degrees = 1.998 * CuratedTrailQuery.maximumRadiusMeters / RouteGeometry.metersPerDegreeLatitude
        return CuratedTrailQuery.searchBoxes(
            for: CommunitySearchArea(
                coordinate: searchCenter(atLatitude: latitude),
                radiusMeters: CuratedTrailQuery.maximumRadiusMeters,
                visibleSpan: CommunitySearchArea.Span(
                    latitudeDelta: degrees,
                    longitudeDelta: degrees / cos(latitude * .pi / 180)
                )
            )
        )
    }

    // MARK: - A page of the answer

    @Test("a page is the routes nearest the point asked about, nearest first, and no longer than was asked for")
    func aPageIsTheNearestRoutes() async throws {
        let database = StubTrailCellDatabase(cells: [
            Self.westSquare: TrailCellFixture.found([Self.edgeTrack, Self.nearLoop, Self.middlePath]),
        ])
        let library = Self.makeLibrary(database)

        let page = try await library.trails(in: [Self.valley], nearest: Self.valleyCenter, limit: 2)
        let all = try await library.trails(in: [Self.valley], nearest: Self.valleyCenter, limit: 50)

        #expect(Self.offered(page) == [11, 66])
        #expect(Self.offered(all) == [11, 66, 77], "fewer than were asked for is all there are")
    }

    /// The page is filled from routes that can be drawn, so the nearest one
    /// being in pieces costs the hiker nothing.
    @Test("a route with nothing to draw takes no row from one that has")
    func anUndrawableRouteTakesNoRow() async throws {
        let database = StubTrailCellDatabase(cells: [
            Self.westSquare: TrailCellFixture.found([Self.brokenPath, Self.middlePath, Self.nearLoop]),
        ])

        let answer = try await Self.makeLibrary(database)
            .trails(in: [Self.valley], nearest: Self.valleyCenter, limit: 1)

        #expect(Self.offered(answer) == [11])
    }

    // MARK: - How many squares a search reads

    /// As far north as Svalbard's islands go. A map's count depends on where
    /// it stands on the grid as well as how far north, so the last two are
    /// where it falls worst: a map panned north of Longyearbyen, which needs
    /// 378 squares, and one short of 81°N, which needs 468.
    @Test(
        "the widest search the app makes is answered from the squares, each asked for once, a request at a time",
        arguments: [0, 47, 60, 70, 78.45, 80.758] as [Double]
    )
    func theWidestSearchIsAnswered(latitude: Double) async throws {
        let database = StubTrailCellDatabase(manifest: .complete)

        let answer = try await Self.makeLibrary(database).trails(
            in: Self.widestSearch(atLatitude: latitude),
            nearest: Self.searchCenter(atLatitude: latitude),
            limit: CommunityQueryPolicy.wideResultLimit
        )

        let asked = database.requests.flatMap(\.self)
        #expect(answer == .trails([]))
        #expect(database.requests.count > 1, "wider than one request names")
        #expect(database.requests.allSatisfy { $0.count <= TrailCellLibrary.maximumCellsPerRequest })
        #expect(Set(asked).count == asked.count)
        #expect(asked.count <= TrailCellLibrary.maximumCellsPerSearch)
    }

    /// The valley's two squares, and every search the map above the sheet
    /// makes, are still one round trip.
    @Test("a search of no more squares than one request names is one request")
    func anOrdinarySearchIsOneRequest() async throws {
        let database = StubTrailCellDatabase(manifest: .complete)

        _ = try await Self.makeLibrary(database).trails(in: [Self.valley], nearest: Self.valleyCenter, limit: 25)

        #expect(database.requests == [[Self.westSquare, Self.eastSquare]])
    }

    /// Fewer, and a search would push out squares it had just kept, and ask
    /// for them again the next time.
    @Test("the device keeps at least as many squares as one search may read")
    func aSearchFitsInTheStore() {
        #expect(TrailCellStore.maximumFiles >= TrailCellLibrary.maximumCellsPerSearch)
    }

    // MARK: - A fetch that got some of them

    /// Several requests at 60°N, and a square of the second cannot be read.
    /// The ones after it would be asked on behalf of a search that already
    /// has no whole answer; what the first brought, and the rest of the
    /// second, is the part it has, and what the next try does not have to ask
    /// for.
    @Test("a request that could not be read whole ends the fetch, and the next search asks only for what is left")
    func aFailedRequestEndsTheFetch() async throws {
        let boxes = Self.widestSearch(atLatitude: 60)
        let center = Self.searchCenter(atLatitude: 60)
        let rehearsal = StubTrailCellDatabase(manifest: .complete)
        _ = try await Self.makeLibrary(rehearsal).trails(in: boxes, nearest: center, limit: 50)
        let requests = rehearsal.requests
        try #require(requests.count > 2, "precondition: this search is more than two requests")
        let unreadable = try #require(requests[1].first)

        let database = StubTrailCellDatabase(manifest: .complete, cells: [unreadable: .failed])
        let library = Self.makeLibrary(database, directory: Self.scratchDirectory())
        let first = try await library.trails(in: boxes, nearest: center, limit: 50)
        let firstAsked: [[String]] = database.requests
        database.hold(TrailCellFixture.found([]), as: unreadable)
        let second = try await library.trails(in: boxes, nearest: center, limit: 50)
        let secondAsked: [String] = database.requests.dropFirst(2).flatMap(\.self)
        let left: [String] = [unreadable] + requests.dropFirst(2).flatMap(\.self)

        #expect(first == .partial([]))
        #expect(second == .trails([]))
        #expect(firstAsked == Array(requests.prefix(2)))
        #expect(secondAsked == left)
    }

    /// The same search with a square of the second request arriving as bytes
    /// this build cannot read. The server answered, so the requests after it
    /// are asked as they would have been, and their routes are the part's.
    @Test("a square that arrives unreadable does not end the fetch")
    func anUnreadableSquareDoesNotEndTheFetch() async throws {
        let boxes = Self.widestSearch(atLatitude: 60)
        let center = Self.searchCenter(atLatitude: 60)
        let rehearsal = StubTrailCellDatabase(manifest: .complete)
        _ = try await Self.makeLibrary(rehearsal).trails(in: boxes, nearest: center, limit: 50)
        let requests = rehearsal.requests
        try #require(requests.count > 2, "precondition: this search is more than two requests")
        let unreadable = try #require(requests[1].first)

        let database = StubTrailCellDatabase(
            manifest: .complete,
            cells: [unreadable: .found(Data("not a square".utf8))]
        )
        let answer = try await Self.makeLibrary(database).trails(in: boxes, nearest: center, limit: 50)

        #expect(answer == .partial([]))
        #expect(database.requests == requests, "every request was asked")
    }

    /// The request that was out finished rather than heard of it, as one may.
    /// The browser starts the next search only once this one has ended, so
    /// the requests after it would be time the hiker waits through.
    @Test("a wide search superseded while a request is out asks for nothing after it")
    func aSupersededWideSearchStops() async {
        let database = StubTrailCellDatabase(manifest: .complete)
        database.cancelCallers(answering: true)
        let library = Self.makeLibrary(database)

        // A task of its own, because it is the one the stub cancels.
        let search = Task {
            try await library.trails(
                in: Self.widestSearch(atLatitude: 60),
                nearest: Self.searchCenter(atLatitude: 60),
                limit: CommunityQueryPolicy.wideResultLimit
            )
        }

        await #expect(throws: CancellationError.self) {
            try await search.value
        }
        #expect(database.requests.count == 1)
    }

    /// What lets a wide search finish on a connection too slow to carry it in
    /// one request's time: each try asks only for what the one before could
    /// not read.
    @Test("a search that could not read every square keeps the ones it did, and the next asks only for the rest")
    func aPartialFetchIsKept() async throws {
        let database = StubTrailCellDatabase(cells: [
            Self.westSquare: TrailCellFixture.found([Self.nearLoop]),
            Self.eastSquare: .failed,
        ])
        let library = Self.makeLibrary(database, directory: Self.scratchDirectory())

        let first = try await library.trails(in: [Self.valley], nearest: Self.valleyCenter, limit: 25)
        database.hold(TrailCellFixture.found([Self.farPath]), as: Self.eastSquare)
        let second = try await library.trails(in: [Self.valley], nearest: Self.valleyCenter, limit: 25)

        #expect(Self.offeredInPart(first) == [11])
        #expect(Self.offered(second) == [11])
        #expect(database.requests == [[Self.westSquare, Self.eastSquare], [Self.eastSquare]])
    }
}

// swiftlint:enable no_magic_numbers
