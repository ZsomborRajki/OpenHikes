//
//  TrailGraphSquareLibraryTests.swift
//  OpenHikesTests
//
//  What the trail graph's squares answer a region with — and, as much, when
//  they decline to answer — and that what they answer is the graph Overpass
//  gives for the same trails. The second is the case everything else rests
//  on: a region read from a square sits in the provider's cache beside
//  regions read from Overpass, merged at the nodes they share.
//
//  The database is the day hikes' stub and the directory is the case's own,
//  for the reason the repository's *Deliberate test seams* section gives.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail graph square library")
struct TrailGraphSquareLibraryTests {
    // MARK: - Fixtures

    /// The region over `OverpassGraphFixture.alpineRoute`, and its square.
    static let region = TrailGraphRegion(zoom: 12, x: 2194, y: 1430)
    static let squareName = "graph1_z10_548_357"

    /// `OverpassGraphFixture.alpineRoute` as a square holds it: way 10 with
    /// the hiking route it is part of, and not way 11, which is private.
    static let localPath = TrailGraphSquareFile.Way(
        id: 10,
        highway: "path",
        tags: [.name: "Local Path", .hikingRoute: "Alpine Route", .surface: "gravel", .tracktype: "grade2"],
        nodes: [node(1, 47.63, 12.86), node(2, 47.631, 12.86)]
    )

    static func node(_ id: Int64, _ latitude: Double, _ longitude: Double) -> TrailGraphSquareFile.Node {
        let scale = Double(TrailGraphSquareFile.standardCoordinateScale)
        return TrailGraphSquareFile.Node(
            id: id,
            latitude: Int32((latitude * scale).rounded()),
            longitude: Int32((longitude * scale).rounded())
        )
    }

    static func found(_ ways: [TrailGraphSquareFile.Way]) -> TrailCellFetch.Cell {
        .found(TrailGraphSquareFile(ways: ways).encoded())
    }

    static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("trail-graph-squares-\(UUID().uuidString)")
    }

    static func graph(
        _ answer: TrailGraphSquareAnswer,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> TrailGraph? {
        guard case .graph(let graph, _) = answer else {
            Issue.record("the squares gave no answer: \(answer)", sourceLocation: sourceLocation)
            return nil
        }
        return graph
    }

    static func fetchedAt(_ answer: TrailGraphSquareAnswer) -> Date? {
        guard case .graph(_, let fetchedAt) = answer else { return nil }
        return fetchedAt
    }

    // MARK: - The same graph as Overpass's

    @Test("a region read from a square is the graph Overpass gives for the same trails")
    func aSquareReadsAsOverpassDoes() async throws {
        let fromOverpass = try OverpassTrailGraphProvider.decodeGraph(from: Data(OverpassGraphFixture.alpineRoute.utf8))
        let database = StubTrailCellDatabase(cells: [Self.squareName: Self.found([Self.localPath])])
        let library = TrailGraphSquareLibrary(database: database, directory: nil)

        let fromSquare = try #require(Self.graph(await library.graph(for: Self.region)))

        #expect(fromSquare == fromOverpass)
        #expect(database.requests == [[Self.squareName]])
    }

    /// What a zoomed-in region needs: a forest road can cross the whole tile
    /// without one of its vertices on it, and Overpass finds it by the
    /// segment.
    @Test("a way that crosses the region between two points outside it is in the region")
    func aWayThatOnlyCrosses() async throws {
        let bounds = TrailGraphSquareLibrary.bounds(of: Self.region)
        let middle = (bounds.south + bounds.north) / 2
        let crossing = TrailGraphSquareFile.Way(
            id: 20,
            highway: "track",
            tags: [:],
            nodes: [Self.node(3, middle, bounds.west - 0.01), Self.node(4, middle, bounds.east + 0.01)]
        )
        let passing = TrailGraphSquareFile.Way(
            id: 21,
            highway: "track",
            tags: [:],
            nodes: [Self.node(5, bounds.north + 0.01, bounds.west), Self.node(6, bounds.north + 0.02, bounds.east)]
        )
        let database = StubTrailCellDatabase(cells: [Self.squareName: Self.found([crossing, passing])])

        let graph = try #require(Self.graph(await TrailGraphSquareLibrary(database: database, directory: nil)
            .graph(for: Self.region)))

        #expect(graph.edges.map(\.id.wayID) == [20])
        #expect(graph.nodes.map(\.id) == [3, 4], "the whole way, as Overpass hands over every node of it")
    }

    /// Two of a way's nodes a centimetre apart are one point at a square's
    /// millionths of a degree, and the segment between them is all that
    /// joins the trail on either side.
    @Test("a segment whose two nodes round to one point keeps the trail joined")
    func nodesOnOnePointStayJoined() async throws {
        let approach = TrailGraphSquareFile.Way(
            id: 30,
            highway: "path",
            tags: [:],
            nodes: [Self.node(1, 47.629, 12.86), Self.node(2, 47.63, 12.86)]
        )
        let joint = TrailGraphSquareFile.Way(
            id: 31,
            highway: "path",
            tags: [:],
            nodes: [Self.node(2, 47.63, 12.86), Self.node(3, 47.6300001, 12.86)]
        )
        let onward = TrailGraphSquareFile.Way(
            id: 32,
            highway: "path",
            tags: [:],
            nodes: [Self.node(3, 47.6300001, 12.86), Self.node(4, 47.631, 12.86)]
        )
        let database = StubTrailCellDatabase(cells: [Self.squareName: Self.found([approach, joint, onward])])

        let graph = try #require(Self.graph(await TrailGraphSquareLibrary(database: database, directory: nil)
            .graph(for: Self.region)))

        #expect(joint.nodes[0].latitude == joint.nodes[1].latitude, "the fixture's two nodes are one point here")
        #expect(graph.edges.map(\.id.wayID) == [30, 31, 32])
        #expect(zip(graph.edges, graph.edges.dropFirst()).allSatisfy { $0.toNodeID == $1.fromNodeID }, "one trail")
    }

    // MARK: - One square, many regions

    @Test("the regions of one square share one request, and a kept square asks nothing")
    func oneSquareOneRequest() async {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = StubTrailCellDatabase(cells: [Self.squareName: Self.found([Self.localPath])])
        let library = TrailGraphSquareLibrary(database: database, directory: directory)
        let regionsOfOneSquare = (0..<4).map { offset in
            TrailGraphRegion(zoom: 12, x: 2192 + offset, y: 1430)
        }

        await withTaskGroup(of: Void.self) { group in
            for next in regionsOfOneSquare {
                group.addTask { _ = await library.graph(for: next) }
            }
        }
        let later = TrailGraphSquareLibrary(database: database, directory: directory)
        let again = Self.graph(await later.graph(for: Self.region))

        #expect(database.requests == [[Self.squareName]])
        #expect(again?.edges.count == 1)
    }

    /// No trails in the square is something the squares can say, and asking
    /// Overpass to confirm it would bring the wait back.
    @Test("a square with no record, in squares that are the whole world, is ground with no trails")
    func anAbsentSquareIsEmptyGround() async {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = StubTrailCellDatabase()

        let first = Self.graph(await TrailGraphSquareLibrary(database: database, directory: directory)
            .graph(for: Self.region))
        let second = Self.graph(await TrailGraphSquareLibrary(database: database, directory: directory)
            .graph(for: Self.region))

        #expect(first?.isEmpty == true)
        #expect(second?.isEmpty == true)
        #expect(database.requests.count == 1, "the empty square is kept as one")
    }

    // MARK: - As old as the square

    /// What the provider keeps a region as fetched at, so it expires with
    /// the square rather than thirty days after it was read out of it.
    @Test("an answer from a kept square says when the square was fetched")
    func anAnswerIsAsOldAsItsSquare() async {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let fetchedAt = clock.now
        let database = StubTrailCellDatabase(cells: [Self.squareName: Self.found([Self.localPath])])
        let library = TrailGraphSquareLibrary(database: database, directory: directory, clock: clock.read)
        let fetched = await library.graph(for: Self.region)

        clock.advance(by: OverpassCache.lifetime - 60)
        let fromDisk = await TrailGraphSquareLibrary(database: database, directory: directory, clock: clock.read)
            .graph(for: Self.region)
        let readLast = await library.graph(for: Self.region)

        #expect(Self.fetchedAt(fetched) == fetchedAt)
        #expect(Self.fetchedAt(fromDisk) == fetchedAt)
        #expect(Self.fetchedAt(readLast) == fetchedAt)
        #expect(database.requests.count == 1)
    }

    @Test("the square read last is not answered from once it has expired")
    func theSquareReadLastExpires() async {
        let clock = TestClock()
        let database = StubTrailCellDatabase(cells: [Self.squareName: Self.found([Self.localPath])])
        let library = TrailGraphSquareLibrary(database: database, directory: nil, clock: clock.read)
        _ = await library.graph(for: Self.region)

        clock.advance(by: OverpassCache.lifetime + 60)
        let again = await library.graph(for: Self.region)

        #expect(database.requests.count == 2)
        #expect(Self.fetchedAt(again) == clock.now)
    }

    // MARK: - No answer

    @Test("squares that are not the whole world give no answer, and none is kept", arguments: [
        TrailCellFetch.Manifest.absent, .partial,
    ])
    func partOfTheWorldIsNoAnswer(manifest: TrailCellFetch.Manifest) async {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = StubTrailCellDatabase(manifest: manifest, cells: [Self.squareName: Self.found([Self.localPath])])

        let first = await TrailGraphSquareLibrary(database: database, directory: directory).graph(for: Self.region)
        _ = await TrailGraphSquareLibrary(database: database, directory: directory).graph(for: Self.region)

        guard case .uncovered = first else {
            Issue.record("a set that is part of the world answered: \(first)")
            return
        }
        #expect(database.requests.count == 2)
    }

    @Test("a square that could not be read, or a request that failed, gives no answer")
    func unreadIsUnreachable() async {
        let unreadManifest = StubTrailCellDatabase(
            manifest: .unread,
            cells: [Self.squareName: Self.found([Self.localPath])]
        )
        let failedSquare = StubTrailCellDatabase(cells: [Self.squareName: .failed])
        let notASquare = StubTrailCellDatabase(cells: [Self.squareName: .found(Data("not a square".utf8))])
        let offline = StubTrailCellDatabase(cells: [Self.squareName: Self.found([Self.localPath])])
        offline.fail(with: URLError(.notConnectedToInternet))

        for database in [unreadManifest, failedSquare, notASquare, offline] {
            let answer = await TrailGraphSquareLibrary(database: database, directory: nil).graph(for: Self.region)
            guard case .unreachable = answer else {
                Issue.record("an unreadable square answered: \(answer)")
                continue
            }
        }
    }

    @Test("a region that is not one of the graph's asks nothing")
    func aRegionOfAnotherZoom() async {
        let database = StubTrailCellDatabase()

        let answer = await TrailGraphSquareLibrary(database: database, directory: nil)
            .graph(for: TrailGraphRegion(zoom: 11, x: 1, y: 1))

        guard case .uncovered = answer else {
            Issue.record("a region of another zoom answered: \(answer)")
            return
        }
        #expect(database.requests.isEmpty)
    }
}
