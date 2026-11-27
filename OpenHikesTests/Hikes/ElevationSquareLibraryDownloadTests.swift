//
//  ElevationSquareLibraryDownloadTests.swift
//  OpenHikesTests
//
//  A line over ground the hiker downloaded: the squares the download brought
//  answer it before anything kept or fetched, square by square, so a line
//  inside the download asks nothing of the network and is given its heights
//  with no signal, and one that reaches past it asks only for the rest.
//
//  The downloads, the database and the directory are the case's own, for the
//  reason the repository's *Deliberate test seams* section gives.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Synchronization
import Testing

/// Squares a suite says a download holds, in place of
/// ``OfflineCountryArchives``.
nonisolated final class StubDownloadedElevationSquares: DownloadedElevationSquares {
    private let held: Mutex<[ElevationSquare: Data]>

    init(_ squares: [ElevationSquare: Data] = [:]) {
        held = Mutex(squares)
    }

    /// Changes what the download holds for `square`: a download landing, or
    /// one deleted when `bytes` is `nil`.
    func hold(_ bytes: Data?, as square: ElevationSquare) {
        held.withLock { $0[square] = bytes }
    }

    func elevationSquares(_ squares: [ElevationSquare]) -> [ElevationSquare: Data] {
        held.withLock { held in
            squares.reduce(into: [:]) { found, square in found[square] = held[square] }
        }
    }
}

@Suite("Elevation square library: downloaded squares")
struct ElevationSquareLibraryDownloadTests {
    /// The Alps' square, its plane of heights and its points.
    private typealias Alps = ElevationSquareLibraryTests

    /// No signal: every request fails as a whole.
    private struct NoSignal: Error {}

    /// The square south of the Alps' one.
    private static let south = ElevationSquare(row: 340, column: 1543)
    private static var southName: String { ElevationSquareGrid.recordName(for: south) }

    /// A point on the Alps' square's last row of posts but a half, whose
    /// height reads the first row of the square south of it too.
    private static let acrossTheEdge = Alps.point(row: 449.5, column: 0.5)

    nonisolated private static func level(_ height: Int16, columns: Int = 450) -> ElevationSquareFile {
        ElevationSquareFile(rows: 450, columns: columns, heights: Array(repeating: height, count: 450 * columns))
    }

    private static func library(
        _ database: StubTrailCellDatabase,
        downloads: StubDownloadedElevationSquares,
        directory: URL? = nil
    ) -> ElevationSquareLibrary {
        ElevationSquareLibrary(database: database, downloads: downloads, directory: directory, clock: TestClock().read)
    }

    @Test("a line the download covers asks the server nothing, and is given its heights with no signal")
    func coveredWithNoSignal() async throws {
        let database = StubTrailCellDatabase()
        database.fail(with: NoSignal())
        let downloads = StubDownloadedElevationSquares([Alps.alps: Alps.plane().encoded()])

        let heights = try await Self.library(database, downloads: downloads)
            .heights(at: [Alps.point(row: 10.5, column: 20.75), Alps.point(row: 90.5, column: 90.25)])

        #expect(Alps.agree(heights, [1000 + 10.5 + 2 * 20.75, 1000 + 90.5 + 2 * 90.25]))
        #expect(database.requests.isEmpty)
    }

    @Test("a line that reaches past the download asks only for the squares it does not hold")
    func reachingPast() async throws {
        let database = StubTrailCellDatabase(cells: [Self.southName: .found(Self.level(2000).encoded())])
        let downloads = StubDownloadedElevationSquares([Alps.alps: Alps.plane().encoded()])

        let heights = try await Self.library(database, downloads: downloads).heights(at: [Self.acrossTheEdge])

        // Halfway between the posts of the row above, then halfway down to
        // the next square's first row.
        let expected: Double = ((1000 + 449 + 1) + 2000) / 2
        #expect(Alps.agree(heights, [expected]))
        #expect(database.requests == [[Self.southName]])
    }

    /// Heights for some points and not others would pair up wrongly, so a
    /// line the download covers only in part has none until the rest comes.
    @Test("with no signal, a line that reaches past the download has no heights")
    func pastWithNoSignal() async {
        let database = StubTrailCellDatabase()
        database.fail(with: NoSignal())
        let downloads = StubDownloadedElevationSquares([Alps.alps: Alps.plane().encoded()])

        await #expect(throws: CuratedElevationFailure.unreachable) {
            try await Self.library(database, downloads: downloads).heights(at: [Self.acrossTheEdge])
        }
        #expect(database.requests == [[Self.southName]])
    }

    /// The download holds sea as a square of posts at 0 m, where the server
    /// has no tile at all.
    @Test("a downloaded square of sea reads sea level, with no signal")
    func downloadedSea() async throws {
        let database = StubTrailCellDatabase()
        database.fail(with: NoSignal())
        let downloads = StubDownloadedElevationSquares([Alps.alps: Self.level(0).encoded()])

        let heights = try await Self.library(database, downloads: downloads)
            .heights(at: [Alps.point(row: 100.5, column: 100.5)])

        #expect(heights == [0])
        #expect(database.requests.isEmpty)
    }

    /// A file of another size would put every height on the wrong post.
    @Test("a downloaded square this build cannot read, or of the wrong size, is fetched instead", arguments: [
        Data("not a square".utf8), Self.level(700, columns: 300).encoded(),
    ])
    func unreadableDownload(bytes: Data) async throws {
        let database = StubTrailCellDatabase(cells: [Alps.alpsName: .found(Alps.plane().encoded())])
        let downloads = StubDownloadedElevationSquares([Alps.alps: bytes])

        let heights = try await Self.library(database, downloads: downloads)
            .heights(at: [Alps.point(row: 1.5, column: 1.5)])

        #expect(Alps.agree(heights, [1000 + 1.5 + 3]))
        #expect(database.requests == [[Alps.alpsName]])
    }

    @Test("a downloaded square answers ahead of a copy kept from an earlier answer")
    func aheadOfKeptCopy() async throws {
        let directory = Alps.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = StubTrailCellDatabase(cells: [Alps.alpsName: .found(Alps.plane().encoded())])
        let downloads = StubDownloadedElevationSquares()
        let library = Self.library(database, downloads: downloads, directory: directory)
        let point = Alps.point(row: 5.5, column: 5.5)
        #expect(Alps.agree(try await library.heights(at: [point]), [1000 + 5.5 + 11]))

        downloads.hold(Self.level(1500).encoded(), as: Alps.alps)
        let heights = try await library.heights(at: [point])

        #expect(heights == [1500])
        #expect(database.requests.count == 1, "the second answer asked nothing")
    }
}
