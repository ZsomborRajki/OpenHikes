//
//  TrailCellLibraryDownloadTests.swift
//  OpenHikesTests
//
//  A search over ground the hiker downloaded: the squares the download
//  brought answer it before anything kept or fetched, square by square, so a
//  search inside the download asks nothing of the network and is answered
//  with no signal, and one that reaches past it asks only for the rest.
//
//  The downloads, the database and the directory are the case's own, for the
//  reason the repository's *Deliberate test seams* section gives.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

/// Squares a suite says a download holds, in place of
/// ``OfflineCountryArchives``.
nonisolated final class StubDownloadedTrailCells: DownloadedTrailCells {
    private let held: Mutex<[String: Data]>

    init(_ cells: [String: Data] = [:]) {
        held = Mutex(cells)
    }

    /// Changes what the download holds under `name`: a download landing, or
    /// one deleted when `bytes` is `nil`.
    func hold(_ bytes: Data?, as name: String) {
        held.withLock { $0[name] = bytes }
    }

    func trailCells(named names: [String]) -> [String: Data] {
        held.withLock { held in
            names.reduce(into: [:]) { found, name in found[name] = held[name] }
        }
    }
}

@Suite("Trail cell library: downloaded squares")
struct TrailCellLibraryDownloadTests {
    /// The valley, its two squares and its routes.
    private typealias Valley = TrailCellLibraryTests

    /// No signal: every request fails as a whole.
    private struct NoSignal: Error {}

    private static func makeLibrary(
        _ database: StubTrailCellDatabase,
        downloads: StubDownloadedTrailCells,
        directory: URL? = nil
    ) -> TrailCellLibrary {
        TrailCellLibrary(database: database, downloads: downloads, directory: directory, clock: TestClock().read)
    }

    private static func bytes(_ relations: [TrailCellFile.Relation]) -> Data {
        TrailCellFile(relations: relations).encoded()
    }

    private static func search(_ library: TrailCellLibrary) async throws -> TrailCellAnswer {
        try await library.trails(
            in: [Valley.valley],
            nearest: Valley.valleyCenter,
            limit: CommunityQueryPolicy.resultLimit
        )
    }

    @Test("a search the download covers asks the server nothing, and is answered with no signal")
    func coveredWithNoSignal() async throws {
        let database = StubTrailCellDatabase()
        database.fail(with: NoSignal())
        let downloads = StubDownloadedTrailCells([
            Valley.westSquare: Self.bytes([Valley.nearLoop]),
            // A square of the download with no routes in it is one of its
            // squares all the same.
            Valley.eastSquare: Self.bytes([]),
        ])

        let answer = try await Self.search(Self.makeLibrary(database, downloads: downloads))

        #expect(Valley.offered(answer) == [11])
        #expect(database.requests.isEmpty)
    }

    @Test("a search that reaches past the download asks only for the squares it does not hold")
    func reachingPast() async throws {
        let nearPeak = TrailCellFixture.relation(
            55,
            name: "Near Peak",
            from: TrailCellFixture.point(47.63, 13.0005),
            to: TrailCellFixture.point(47.635, 13.002)
        )
        let database = StubTrailCellDatabase(cells: [Valley.eastSquare: TrailCellFixture.found([nearPeak])])
        let downloads = StubDownloadedTrailCells([Valley.westSquare: Self.bytes([Valley.nearLoop])])

        let answer = try await Self.search(Self.makeLibrary(database, downloads: downloads))

        #expect(database.requests == [[Valley.eastSquare]])
        #expect(Set(Valley.offered(answer)) == [11, 55])
    }

    /// Past the download, a search is what it was before there were
    /// downloads: no answer, so the source draws what the device already
    /// holds and says the search failed.
    @Test("with no signal, a search that reaches past the download is no answer")
    func pastWithNoSignal() async throws {
        let database = StubTrailCellDatabase()
        database.fail(with: NoSignal())
        let downloads = StubDownloadedTrailCells([Valley.westSquare: Self.bytes([Valley.nearLoop])])

        let answer = try await Self.search(Self.makeLibrary(database, downloads: downloads))

        #expect(answer == .unreachable)
        #expect(database.requests == [[Valley.eastSquare]])
    }

    @Test("a downloaded square answers ahead of a copy kept from an earlier search")
    func aheadOfKeptCopy() async throws {
        let renamed = TrailCellFixture.relation(
            66,
            name: "Valley Loop",
            from: TrailCellFixture.point(47.62, 12.97),
            to: TrailCellFixture.point(47.628, 12.98)
        )
        let database = StubTrailCellDatabase(cells: [
            Valley.westSquare: TrailCellFixture.found([Valley.nearLoop]),
        ])
        let downloads = StubDownloadedTrailCells()
        let library = Self.makeLibrary(database, downloads: downloads, directory: Valley.scratchDirectory())
        #expect(Valley.offered(try await Self.search(library)) == [11])

        downloads.hold(Self.bytes([renamed]), as: Valley.westSquare)
        downloads.hold(Self.bytes([]), as: Valley.eastSquare)
        let answer = try await Self.search(library)

        #expect(Valley.offered(answer) == [66])
        #expect(database.requests.count == 1, "the second search asked nothing")
    }

    @Test("a downloaded square this build cannot read is fetched instead")
    func unreadableDownload() async throws {
        let database = StubTrailCellDatabase(cells: [
            Valley.westSquare: TrailCellFixture.found([Valley.nearLoop]),
        ])
        let downloads = StubDownloadedTrailCells([
            Valley.westSquare: Data("not a square".utf8),
            Valley.eastSquare: Self.bytes([]),
        ])

        let answer = try await Self.search(Self.makeLibrary(database, downloads: downloads))

        #expect(database.requests == [[Valley.westSquare]])
        #expect(Valley.offered(answer) == [11])
    }
}
