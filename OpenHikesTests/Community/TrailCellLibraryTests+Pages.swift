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

// The coordinates of four routes and the latitudes of five searches, which
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

    /// As far north as Svalbard's settlements, which is past anywhere a
    /// waymarked route has been mapped.
    @Test(
        "the widest search the app makes is answered from the squares, each asked for once, in requests of sixty",
        arguments: [0, 47, 60, 70, 78] as [Double]
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

    /// Three requests at 60°N, and a square of the second cannot be read.
    /// The third would be asked on behalf of a search that already has no
    /// answer; what the first brought, and the rest of the second, is what
    /// the next try does not have to ask for.
    @Test("a request that could not be read whole ends the fetch, and the next search asks only for what is left")
    func aFailedRequestEndsTheFetch() async throws {
        let boxes = Self.widestSearch(atLatitude: 60)
        let center = Self.searchCenter(atLatitude: 60)
        let rehearsal = StubTrailCellDatabase(manifest: .complete)
        _ = try await Self.makeLibrary(rehearsal).trails(in: boxes, nearest: center, limit: 50)
        let requests = rehearsal.requests
        try #require(requests.count == 3, "precondition: this search is three requests")
        let unreadable = try #require(requests[1].first)

        let database = StubTrailCellDatabase(manifest: .complete, cells: [unreadable: .failed])
        let library = Self.makeLibrary(database, directory: Self.scratchDirectory())
        let first = try await library.trails(in: boxes, nearest: center, limit: 50)
        database.hold(TrailCellFixture.found([]), as: unreadable)
        let second = try await library.trails(in: boxes, nearest: center, limit: 50)

        #expect(first == .unreachable)
        #expect(second == .trails([]))
        #expect(database.requests == [requests[0], requests[1], [unreadable] + requests[2]])
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

        #expect(first == .unreachable)
        #expect(Self.offered(second) == [11])
        #expect(database.requests == [[Self.westSquare, Self.eastSquare], [Self.eastSquare]])
    }
}

// swiftlint:enable no_magic_numbers
