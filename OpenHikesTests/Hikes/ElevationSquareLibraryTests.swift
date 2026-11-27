//
//  ElevationSquareLibraryTests.swift
//  OpenHikesTests
//
//  What the elevation squares answer a line's points with — and, as much,
//  when they decline to answer.
//
//  The contract is ``CuratedElevationSourcing``'s: a height for every point,
//  in order, or no answer at all, because heights for some points and not
//  others would pair up wrongly. So the cases worth having are on that line:
//  sea, ground with no heights, a square that would not come, no archive to
//  read, and what is kept on the device either side of them.
//
//  The database is the trail squares' stub and the directory is the case's
//  own, for the reason the repository's *Deliberate test seams* section
//  gives.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Elevation square library")
struct ElevationSquareLibraryTests {
    // MARK: - Fixtures

    /// A square in the Berchtesgaden Alps, 1° band, 450 × 450 posts.
    static let alps = ElevationSquare(row: 339, column: 1543)
    static var alpsName: String { ElevationSquareGrid.recordName(for: alps) }
    /// Its first post's row and column, counted over the whole Earth.
    static let firstRow = 339 * 450
    static let firstColumn = 1543 * 450

    /// The square, its heights a plane: a metre a row southward and two a
    /// column eastward from a thousand, so any point inside it reads back
    /// exactly as the plane says.
    static func plane(unknownAt unknown: Set<Int> = []) -> ElevationSquareFile {
        let heights = (0..<450 * 450).map { index -> Int16 in
            unknown.contains(index) ? ElevationSquareFile.unknown : Int16(1000 + index / 450 + 2 * (index % 450))
        }
        return ElevationSquareFile(rows: 450, columns: 450, heights: heights)
    }

    /// The point `row` and `column` posts into the square, in degrees.
    static func point(row: Double, column: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: 90 - (Double(firstRow) + row) / 3600,
            longitude: (Double(firstColumn) + column) / 3600 - 180
        )
    }

    static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("elevation-squares-\(UUID().uuidString)")
    }

    static func library(_ database: StubTrailCellDatabase, directory: URL? = nil) -> ElevationSquareLibrary {
        ElevationSquareLibrary(database: database, directory: directory, clock: TestClock().read)
    }

    /// Whether two answers agree to a millionth of a metre: a point's
    /// degrees, turned back into posts, are never quite whole.
    static func agree(_ heights: [Double], _ expected: [Double]) -> Bool {
        heights.count == expected.count
            && zip(heights, expected).allSatisfy { $0.isApproximatelyEqual(to: $1, absoluteTolerance: 1e-6) }
    }

    // MARK: - Heights

    @Test("each point reads the plane through the four posts around it, in the order asked")
    func heightsAreRead() async throws {
        let database = StubTrailCellDatabase(cells: [Self.alpsName: .found(Self.plane().encoded())])
        let points = [
            Self.point(row: 90.5, column: 90.25),
            Self.point(row: 10.5, column: 20.75),
            Self.point(row: 0.5, column: 0.25),
        ]

        let heights = try await Self.library(database).heights(at: points)

        #expect(Self.agree(heights, [1000 + 90.5 + 2 * 90.25, 1000 + 10.5 + 2 * 20.75, 1000 + 0.5 + 2 * 0.25]))
        #expect(database.requests == [[Self.alpsName]], "one request for the one square the points need")
    }

    /// A square the archive has no tile for, in an archive that is the whole
    /// world, is sea: Copernicus has no tile there either.
    @Test("a square the server has no tile for is sea, at sea level")
    func seaIsSeaLevel() async throws {
        let database = StubTrailCellDatabase()

        let heights = try await Self.library(database).heights(at: [Self.point(row: 100, column: 100)])

        #expect(heights == [0])
    }

    /// Ground whose heights Copernicus does not give away is filed as posts
    /// with no height, and a point among them is `nan` — never a height of
    /// 0 m on a mountain. A line with one has no profile at all
    /// (`CuratedElevationTests`).
    @Test("a point beside a post with no height has none")
    func withheldGround() async throws {
        let unknown = 100 * 450 + 101
        let database = StubTrailCellDatabase(cells: [Self.alpsName: .found(Self.plane(unknownAt: [unknown]).encoded())])

        let heights = try await Self.library(database).heights(at: [
            Self.point(row: 100.5, column: 100.5),
            Self.point(row: 200.5, column: 200.5),
        ])

        #expect(heights[0].isNaN)
        #expect(heights[1].isApproximatelyEqual(to: 1000 + 200.5 + 401, absoluteTolerance: 1e-6))
    }

    /// A point on a square's last row reads the next square's first: both
    /// are asked for, in one request.
    @Test("a point between two squares reads both")
    func acrossSquares() async throws {
        let south = ElevationSquare(row: 340, column: 1543)
        let southName = ElevationSquareGrid.recordName(for: south)
        let database = StubTrailCellDatabase(cells: [
            Self.alpsName: .found(Self.plane().encoded()),
            southName: .found(ElevationSquareFile(
                rows: 450, columns: 450, heights: Array(repeating: 2000, count: 450 * 450)
            ).encoded()),
        ])

        let heights = try await Self.library(database).heights(at: [Self.point(row: 449.5, column: 0.5)])
        let height = try #require(heights.first)

        #expect(height.isApproximatelyEqual(to: ((1000 + 449 + 1) + 2000) / 2, absoluteTolerance: 1e-6))
        #expect(database.requests.count == 1)
        #expect(Set(database.requests.first ?? []) == [Self.alpsName, southName])
    }

    @Test("no points ask nothing")
    func noPoints() async throws {
        let database = StubTrailCellDatabase()
        #expect(try await Self.library(database).heights(at: []).isEmpty)
        #expect(database.requests.isEmpty)
    }

    // MARK: - No answer

    @Test("no archive this build reads is no answer", arguments: [
        TrailCellFetch.Manifest.absent, .partial,
    ])
    func uncovered(_ manifest: TrailCellFetch.Manifest) async {
        let database = StubTrailCellDatabase(manifest: manifest, cells: [Self.alpsName: .found(Self.plane().encoded())])

        await #expect(throws: CuratedElevationFailure.uncovered) {
            try await Self.library(database).heights(at: [Self.point(row: 1, column: 1)])
        }
    }

    @Test("a list that could not be read is a square that would not come")
    func unreadList() async {
        let database = StubTrailCellDatabase(manifest: .unread)

        await #expect(throws: CuratedElevationFailure.unreachable) {
            try await Self.library(database).heights(at: [Self.point(row: 1, column: 1)])
        }
    }

    @Test("a square that would not come is no answer for any point")
    func failedSquare() async {
        let database = StubTrailCellDatabase(cells: [Self.alpsName: .failed])

        await #expect(throws: CuratedElevationFailure.unreachable) {
            try await Self.library(database).heights(at: [Self.point(row: 1, column: 1)])
        }
    }

    @Test("a request that fails as a whole is no answer")
    func failedRequest() async {
        let database = StubTrailCellDatabase()
        database.fail(with: URLError(.notConnectedToInternet))

        await #expect(throws: CuratedElevationFailure.unreachable) {
            try await Self.library(database).heights(at: [Self.point(row: 1, column: 1)])
        }
    }

    /// A file of another size would put every height on the wrong post: the
    /// square is refused, and not kept.
    @Test("a square of the wrong size is refused and not kept")
    func wrongSize() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let narrow = ElevationSquareFile(rows: 450, columns: 300, heights: Array(repeating: 700, count: 450 * 300))
        let database = StubTrailCellDatabase(cells: [Self.alpsName: .found(narrow.encoded())])
        let library = Self.library(database, directory: directory)

        await #expect(throws: CuratedElevationFailure.unreachable) {
            try await library.heights(at: [Self.point(row: 1, column: 1)])
        }

        database.hold(.found(Self.plane().encoded()), as: Self.alpsName)
        #expect(Self.agree(try await library.heights(at: [Self.point(row: 1.5, column: 1.5)]), [1000 + 1.5 + 3]))
        #expect(database.requests.count == 2, "the refused square was asked for again")
    }

    /// A line longer than a request reads gets no heights rather than a
    /// download of that size, and asks nothing to find that out.
    @Test("a line across too many squares asks nothing")
    func tooLong() async {
        let database = StubTrailCellDatabase()
        let points = (0...ElevationSquareLibrary.maximumSquaresPerRequest).map { step in
            CLLocationCoordinate2D(latitude: 47.06, longitude: 10 + Double(step) * 0.2)
        }

        await #expect(throws: CuratedElevationFailure.tooLong) {
            try await Self.library(database).heights(at: points)
        }
        #expect(database.requests.isEmpty)
    }

    // MARK: - What is kept

    /// The trail maker asks again each time a drawing settles, and a hiker
    /// looks at a valley more than once: what arrived is kept, sea included.
    @Test("squares that arrived, sea included, are read from the device next time")
    func keptSquares() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = StubTrailCellDatabase(cells: [Self.alpsName: .found(Self.plane().encoded())])
        let library = Self.library(database, directory: directory)
        let sea = CLLocationCoordinate2D(latitude: 47.06, longitude: 0.06)
        let points = [Self.point(row: 5.5, column: 5.5), sea]

        let first = try await library.heights(at: points)
        let second = try await library.heights(at: points)

        #expect(Self.agree(first, [1000 + 5.5 + 11, 0]))
        #expect(second == first)
        #expect(database.requests.count == 1, "the second answer sent nothing")
    }
}
