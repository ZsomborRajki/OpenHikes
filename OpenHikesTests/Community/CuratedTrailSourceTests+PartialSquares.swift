//
//  CuratedTrailSourceTests+PartialSquares.swift
//  OpenHikesTests
//
//  A search the pre-built squares could answer for only part of: some of
//  the squares it needs were read, and one was not. Overpass is still asked
//  where it may be, because its answer is whole; where it may not be, or does
//  not answer, the part is the answer, with its gap beside it.
//
//  The case this is for is a search over ground the hiker downloaded, with no
//  signal, framed wide enough to reach past the download: the download's day
//  hikes are the part, and nothing else on the device may hold them.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

// The wide map's span is the fixture, and has no better name than its digits.
// swiftlint:disable no_magic_numbers

extension CuratedTrailSourceTests {
    /// The valley's two squares and their routes, from the library's suite.
    private typealias Valley = TrailCellLibraryTests

    /// A map 120 km across around the valley: wider than Overpass is asked
    /// about, and inside the app's own ceiling.
    private static var widerThanOverpass: CommunitySearchArea {
        CommunitySearchArea(
            coordinate: Valley.valleyCenter,
            radiusMeters: 60_000,
            visibleSpan: CommunitySearchArea.Span(latitudeDelta: 1.08, longitudeDelta: 1.6)
        )
    }

    /// The western square read, and the eastern one failing.
    private static var halfTheValley: TrailCellLibrary {
        TrailCellLibrary(
            database: StubTrailCellDatabase(cells: [
                Valley.westSquare: TrailCellFixture.found([Valley.nearLoop]),
                Valley.eastSquare: .failed,
            ]),
            directory: nil
        )
    }

    @Test("a search the squares answered in part is put to Overpass, whose whole answer is the answer")
    func aPartIsPutToOverpass() async throws {
        let (source, overpass) = Self.makeSource(
            [Self.ok(Self.areaWithLinesBody)],
            cells: Self.halfTheValley
        )

        let listing = try await source.listings(near: Self.visibleArea, limit: 25)

        #expect(listing.trails.map(\.relationID) == [11, 22])
        #expect(listing.gap == nil)
        #expect(await overpass.requestCount == 1)
    }

    @Test("with Overpass refusing as well, the part is the answer, and its gap is the refusal")
    func aPartWithOverpassRefusing() async throws {
        let (source, _) = Self.makeSource(
            [OverpassHTTPResponse(data: Data(), statusCode: Self.httpRateLimited, headers: [:])],
            cells: Self.halfTheValley
        )

        let listing = try await source.listings(near: Self.visibleArea, limit: 25)

        #expect(listing.trails.map(\.relationID) == [11])
        #expect(listing.trails.allSatisfy { $0.route.count > 1 }, "the part comes with its lines")
        guard case .rateLimited = listing.gap else {
            Issue.record("the gap is not Overpass's refusal: \(String(describing: listing.gap))")
            return
        }
    }

    @Test("a wide search the squares answered in part offers the part, and asks Overpass nothing")
    func aWidePart() async throws {
        let (source, overpass) = Self.makeSource([], cells: Self.halfTheValley)

        let listing = try await source.listings(near: Self.widerThanOverpass, limit: 50)

        #expect(listing.trails.map(\.relationID) == [11])
        #expect(listing.gap == .unavailable)
        #expect(await overpass.requestCount == 0)
    }

    /// The case the partial answer is for. With no signal the tile server
    /// and Overpass both fail before they are reached, and the route the
    /// hiker downloaded is still offered, with the gap said beside it.
    @Test("with no signal, a search reaching past a download offers the download's routes, with the gap")
    func pastADownloadWithNoSignal() async throws {
        let database = StubTrailCellDatabase()
        database.fail(with: URLError(.notConnectedToInternet))
        let downloads = StubDownloadedTrailCells([
            Valley.westSquare: TrailCellFile(relations: [Valley.nearLoop]).encoded(),
        ])
        let source = CuratedTrailSource(
            endpoint: URL(string: "https://overpass.invalid/api/interpreter")!,
            directory: nil,
            cells: TrailCellLibrary(database: database, downloads: downloads, directory: nil),
            clock: TestClock().read,
            pause: { _ in /* no signal is not busy, so nothing waits */ },
            transport: { _ in throw URLError(.notConnectedToInternet) }
        )

        let listing = try await source.listings(near: Self.visibleArea, limit: 25)

        #expect(listing.trails.map(\.relationID) == [11])
        #expect(listing.gap == .unavailable)
    }

    @Test("a search superseded while Overpass is asked about a part leaves as a cancellation")
    func aSupersededPart() async throws {
        let source = CuratedTrailSource(
            endpoint: URL(string: "https://overpass.invalid/api/interpreter")!,
            directory: nil,
            cells: Self.halfTheValley,
            clock: TestClock().read,
            pause: { _ in /* nothing waits */ },
            transport: { _ in throw URLError(.cancelled) }
        )

        await #expect(throws: URLError.self) {
            try await source.listings(near: Self.visibleArea, limit: 25)
        }
    }
}

// swiftlint:enable no_magic_numbers
