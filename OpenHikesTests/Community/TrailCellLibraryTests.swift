//
//  TrailCellLibraryTests.swift
//  OpenHikesTests
//
//  What the pre-built squares answer a search with — and, as much, when they
//  decline to answer.
//
//  The library's contract is that an answer is complete or it is not given.
//  ``CuratedTrailSource`` takes an empty answer to mean there are no waymarked
//  day hikes in the area and says so to the hiker, and takes no answer to mean
//  *ask Overpass*. So the cases worth having are the ones on the line between
//  the two: a square that is missing, which is either a place with no routes
//  or a place nothing is known about, and it is the manifest that says which.
//
//  The database is a stub and the directory is the case's own, for the reason
//  the repository's *Deliberate test seams* section gives.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail cell library")
struct TrailCellLibraryTests {
    // MARK: - Fixtures

    /// The map above a half-height sheet at a five-kilometre view — the area
    /// `CuratedTrailSourceTests+OneRequest` searches — which is within reach
    /// of exactly two squares.
    static let valley = CuratedTrailQuery.BoundingBox(south: 47.598, west: 12.93675, north: 47.642, east: 13.00325)
    static let westSquare = "trails1_550_771"
    static let eastSquare = "trails1_550_772"

    /// In the valley, and filed in the western square.
    static let nearLoop = TrailCellFixture.relation(
        11,
        name: "Near Loop",
        from: TrailCellFixture.point(47.62, 12.97),
        to: TrailCellFixture.point(47.628, 12.98)
    )
    /// North of the valley, and filed in the eastern square.
    static let farPath = TrailCellFixture.relation(
        22,
        name: "Far Path",
        from: TrailCellFixture.point(47.7, 13.05),
        to: TrailCellFixture.point(47.708, 13.06)
    )

    private static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("trail-cells-\(UUID().uuidString)")
    }

    /// - Parameter directory: Where the library keeps squares. `nil`, the
    ///   default, is a library that keeps none, so every search is a request
    ///   and a case can count them.
    private static func makeLibrary(
        _ database: StubTrailCellDatabase,
        directory: URL? = nil,
        clock: TestClock = TestClock()
    ) -> TrailCellLibrary {
        TrailCellLibrary(database: database, directory: directory, clock: clock.read)
    }

    /// The relations an answer offers, or a recorded issue when it is not an
    /// answer at all.
    private static func offered(
        _ answer: TrailCellAnswer,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> [Int64] {
        guard case .trails(let trails) = answer else {
            Issue.record("the squares gave no answer: \(answer)", sourceLocation: sourceLocation)
            return []
        }
        return trails.map(\.relationID)
    }

    // MARK: - An answer

    @Test("a search asks once, for the squares within reach of it, and offers what is in the area")
    func aSearchIsAnswered() async throws {
        let database = StubTrailCellDatabase(cells: [
            Self.westSquare: TrailCellFixture.found([Self.nearLoop]),
            Self.eastSquare: TrailCellFixture.found([Self.farPath]),
        ])
        let library = Self.makeLibrary(database)

        let answer = try await library.trails(in: [Self.valley])

        #expect(database.requests == [[Self.westSquare, Self.eastSquare]])
        guard case .trails(let trails) = answer else {
            Issue.record("the squares gave no answer: \(answer)")
            return
        }
        #expect(trails.map(\.relationID) == [11], "Far Path is in a square that was read, and not in the area")
        #expect(trails.first?.name == "Near Loop")
        #expect(trails.first?.route.count == 2, "a route out of a square comes with its line")
    }

    /// What a zoomed-in map needs: a forest road can cross the whole screen
    /// without one of its vertices on it.
    @Test("a route that crosses the area between two points outside it is in the area")
    func aRouteThatOnlyCrosses() async throws {
        let crossing = TrailCellFixture.relation(
            33,
            name: "Straight Through",
            from: TrailCellFixture.point(47.6, 12.9),
            to: TrailCellFixture.point(47.64, 13.04)
        )
        let passing = TrailCellFixture.relation(
            44,
            name: "Passing By",
            from: TrailCellFixture.point(47.6, 12.9),
            to: TrailCellFixture.point(47.64, 12.93)
        )
        let database = StubTrailCellDatabase(cells: [
            Self.westSquare: TrailCellFixture.found([crossing, passing]),
        ])

        let answer = try await Self.makeLibrary(database).trails(in: [Self.valley])

        #expect(Self.offered(answer) == [33])
    }

    /// An upload replaces squares one at a time, so for its duration a route
    /// whose box moved can be in the old square and in the new.
    @Test("a route two squares both hold is offered once")
    func aRouteInTwoSquares() async throws {
        let database = StubTrailCellDatabase(cells: [
            Self.westSquare: TrailCellFixture.found([Self.nearLoop]),
            Self.eastSquare: TrailCellFixture.found([Self.nearLoop]),
        ])

        let answer = try await Self.makeLibrary(database).trails(in: [Self.valley])

        #expect(Self.offered(answer) == [11])
    }

    // MARK: - A square that is not there

    @Test("in squares that are the whole world, a missing square is one with no routes")
    func aMissingSquareOfTheWholeWorld() async throws {
        let database = StubTrailCellDatabase(
            manifest: .complete,
            cells: [Self.westSquare: TrailCellFixture.found([Self.nearLoop])]
        )

        let answer = try await Self.makeLibrary(database).trails(in: [Self.valley])

        #expect(Self.offered(answer) == [11])
    }

    @Test("in squares that are the whole world, an area with no squares at all has no trails, and that is an answer")
    func anEmptyArea() async throws {
        let database = StubTrailCellDatabase(manifest: .complete)

        let answer = try await Self.makeLibrary(database).trails(in: [Self.valley])

        #expect(answer == .trails([]))
    }

    @Test(
        "where the squares are not the whole world, a missing square is no answer",
        arguments: [TrailCellFetch.Manifest.partial, .absent]
    )
    func aMissingSquareOfPartOfTheWorld(manifest: TrailCellFetch.Manifest) async throws {
        let database = StubTrailCellDatabase(
            manifest: manifest,
            cells: [Self.westSquare: TrailCellFixture.found([Self.nearLoop])]
        )

        let answer = try await Self.makeLibrary(database).trails(in: [Self.valley])

        #expect(answer == .uncovered, "Near Loop is there, and the list would look complete without the east")
    }

    /// A regional build in development, or the first upload still under way:
    /// where every square the area needs has arrived, the answer is whole.
    @Test("squares that are not the whole world still answer where none is missing")
    func aRegionalSetAnswersWhereItReaches() async throws {
        let database = StubTrailCellDatabase(
            manifest: .partial,
            cells: [
                Self.westSquare: TrailCellFixture.found([Self.nearLoop]),
                Self.eastSquare: TrailCellFixture.found([Self.farPath]),
            ]
        )

        let answer = try await Self.makeLibrary(database).trails(in: [Self.valley])

        #expect(Self.offered(answer) == [11])
    }

    // MARK: - A square that could not be read

    @Test("a square that could not be read is no answer, whatever else was")
    func aSquareThatFailed() async throws {
        let database = StubTrailCellDatabase(cells: [
            Self.westSquare: TrailCellFixture.found([Self.nearLoop]),
            Self.eastSquare: .failed,
        ])

        let answer = try await Self.makeLibrary(database).trails(in: [Self.valley])

        #expect(answer == .unreachable)
    }

    @Test("a manifest that could not be read does not make a missing square an empty one")
    func anUnreadManifest() async throws {
        let database = StubTrailCellDatabase(manifest: .unread)

        let answer = try await Self.makeLibrary(database).trails(in: [Self.valley])

        #expect(answer == .unreachable)
    }

    @Test("a request that fails is no answer")
    func aRequestThatFails() async throws {
        let database = StubTrailCellDatabase()
        database.fail(with: URLError(.notConnectedToInternet))

        let answer = try await Self.makeLibrary(database).trails(in: [Self.valley])

        #expect(answer == .unreachable)
    }

    @Test("bytes that are not a square are no answer, and are not kept")
    func bytesThatAreNotASquare() async throws {
        let database = StubTrailCellDatabase(cells: [Self.westSquare: .found(Data("not a square".utf8))])
        let library = Self.makeLibrary(database, directory: Self.scratchDirectory())

        let first = try await library.trails(in: [Self.valley])
        database.hold(TrailCellFixture.found([Self.nearLoop]), as: Self.westSquare)
        let second = try await library.trails(in: [Self.valley])

        #expect(first == .unreachable)
        #expect(Self.offered(second) == [11])
        #expect(database.requests.count == 2, "the bad bytes were not what the second search found on disk")
    }

    /// A search superseded while its request is out. Reporting that as an
    /// unreachable square would send the question to Overpass on behalf of a
    /// search nobody is waiting for.
    @Test("a superseded search leaves as a cancellation, not as an unreachable square")
    func aSupersededSearch() async {
        let database = StubTrailCellDatabase()
        database.cancelCallers()
        let library = Self.makeLibrary(database)

        // A task of its own, because it is the one the stub cancels: the
        // case's own has assertions still to make.
        let search = Task { try await library.trails(in: [Self.valley]) }

        await #expect(throws: CancellationError.self) {
            try await search.value
        }
    }

    // MARK: - What is kept

    @Test("the same search a second time asks nothing")
    func aSecondSearchAsksNothing() async throws {
        let database = StubTrailCellDatabase(cells: [
            Self.westSquare: TrailCellFixture.found([Self.nearLoop]),
            Self.eastSquare: TrailCellFixture.found([Self.farPath]),
        ])
        let library = Self.makeLibrary(database, directory: Self.scratchDirectory())

        _ = try await library.trails(in: [Self.valley])
        let again = try await library.trails(in: [Self.valley])

        #expect(Self.offered(again) == [11])
        #expect(database.requests.count == 1)
    }

    /// Without this a search beside a lake would send a request every time,
    /// to be told the lake is still a lake.
    @Test("a square known to hold nothing is kept as that, and not asked about again")
    func anEmptySquareIsKept() async throws {
        let database = StubTrailCellDatabase(manifest: .complete)
        let library = Self.makeLibrary(database, directory: Self.scratchDirectory())

        _ = try await library.trails(in: [Self.valley])
        let again = try await library.trails(in: [Self.valley])

        #expect(again == .trails([]))
        #expect(database.requests.count == 1)
    }

    @Test("only the squares not already kept are asked for")
    func onlyTheMissingSquaresAreAskedFor() async throws {
        let database = StubTrailCellDatabase(cells: [
            Self.westSquare: TrailCellFixture.found([Self.nearLoop]),
            Self.eastSquare: .failed,
        ])
        let directory = Self.scratchDirectory()
        // The western square alone: a search a little to the west, whose
        // reach stops short of the eastern one.
        let westward = CuratedTrailQuery.BoundingBox(south: 47.598, west: 12.8, north: 47.642, east: 12.84)
        let library = Self.makeLibrary(database, directory: directory)

        _ = try await library.trails(in: [westward])
        database.hold(TrailCellFixture.found([Self.farPath]), as: Self.eastSquare)
        _ = try await library.trails(in: [Self.valley])

        #expect(database.requests.last == [Self.eastSquare])
    }

    @Test("a kept square is trusted for thirty days, and asked for again after")
    func aKeptSquareExpires() async throws {
        let day: TimeInterval = 24 * 60 * 60
        let clock = TestClock()
        let database = StubTrailCellDatabase(cells: [
            Self.westSquare: TrailCellFixture.found([Self.nearLoop]),
            Self.eastSquare: TrailCellFixture.found([Self.farPath]),
        ])
        let library = Self.makeLibrary(database, directory: Self.scratchDirectory(), clock: clock)

        _ = try await library.trails(in: [Self.valley])
        clock.advance(by: 29 * day)
        _ = try await library.trails(in: [Self.valley])
        #expect(database.requests.count == 1)

        clock.advance(by: 31 * day)
        _ = try await library.trails(in: [Self.valley])
        #expect(database.requests.count == 2)
    }

    // MARK: - Areas the squares are not asked about

    @Test("no area is no answer, and no request")
    func noArea() async throws {
        let database = StubTrailCellDatabase()

        let answer = try await Self.makeLibrary(database).trails(in: [])

        #expect(answer == .uncovered)
        #expect(database.requests.isEmpty)
    }

    /// Near a pole a square is a sliver and the reach is degrees of
    /// longitude, so the count of squares runs away. Overpass is asked there,
    /// as it always was.
    @Test("an area that would need more squares than a search may read is no answer, and no request")
    func tooManySquares() async throws {
        let database = StubTrailCellDatabase()
        let polar = CuratedTrailQuery.BoundingBox(south: 88.9, west: 0, north: 89, east: 1)

        let answer = try await Self.makeLibrary(database).trails(in: [polar])

        #expect(answer == .uncovered)
        #expect(database.requests.isEmpty)
    }
}
