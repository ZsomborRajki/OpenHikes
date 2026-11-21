//
//  OfflineRouteLegCoverageTests.swift
//  OpenHikesTests
//
//  How a saved line is tested against the countries on offer (#1531): every
//  walked leg from end to end, never its points alone, so a sparse line whose
//  points are all inside a country still leaves it where a leg crosses a bay
//  of its outline, and still names a country a leg passes through between
//  two others. A paused leg is not trail and is not tested, and a leg over
//  the antimeridian goes the short way round. What the tile makes of the
//  answer is `OfflineRouteCoverageTests`'.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

// swiftlint:disable no_magic_numbers

@Suite("Offline countries: a trail's legs")
struct OfflineRouteLegCoverageTests {
    private let concave = OfflineCountryFixture.concaveCountry(bytes: Data())
    private let west = OfflineCountryFixture.westernArm
    private let east = OfflineCountryFixture.easternArm

    /// An area `id` whose outline is each of `rings`, given as longitude and
    /// latitude pairs, and whose bounds hold them all.
    private static func area(_ id: String, _ rings: [[(Double, Double)]]) -> OfflineCountryManifest.Country {
        var country = OfflineCountryFixture.country(bytes: Data(), id: id)
        let points = rings.joined()
        country.bounds = OfflineCountryManifest.Bounds(
            west: points.map(\.0).min() ?? 0,
            south: points.map(\.1).min() ?? 0,
            east: points.map(\.0).max() ?? 0,
            north: points.map(\.1).max() ?? 0
        )
        country.outline = rings.map { ring in ring.map { [$0.0, $0.1] } }
        return country
    }

    /// A box from `west`, `south` to `east`, `north`, as one closed ring.
    private static func box(_ west: Double, _ south: Double, _ east: Double, _ north: Double) -> [(Double, Double)] {
        [(west, south), (east, south), (east, north), (west, north), (west, south)]
    }

    private static func point(_ latitude: Double, _ longitude: Double) -> RouteCoordinate {
        RouteCoordinate(latitude: latitude, longitude: longitude)
    }

    @Test("a leg from one arm of a concave outline to the other leaves it in the bay")
    func legAcrossTheBay() throws {
        let coverage = try OfflineRouteCoverage(walking: [west, east], through: [concave])

        #expect(coverage == OfflineRouteCoverage(crossed: [concave], leavesThem: true))
        #expect(
            try OfflineRouteCoverage(walking: [OfflineCountryFixture.bay], through: [concave]).leavesThem,
            "the bay is in no country"
        )
    }

    @Test("the same ends joined round the bend stay inside")
    func legsRoundTheBend() throws {
        let route = [west, Self.point(45.75, 13.65), Self.point(45.75, 14.25), east]

        let coverage = try OfflineRouteCoverage(walking: route, through: [concave])

        #expect(coverage == OfflineRouteCoverage(crossed: [concave], leavesThem: false))
    }

    /// A pause, or the break between two GPX `<trkseg>`s, is not trail: the
    /// leg across the bay here was driven, and each walked run either side of
    /// it stays in its arm.
    @Test("a paused leg across the bay is not tested")
    func pausedLegIsNotTrail() throws {
        var resumed = Self.point(46.2, 14.25)
        resumed.boundary = .paused
        let route = [west, Self.point(46.2, 13.65), resumed, east]

        let coverage = try OfflineRouteCoverage(walking: route, through: [concave])

        #expect(coverage == OfflineRouteCoverage(crossed: [concave], leavesThem: false))
    }

    /// A point with a pause either side of it is a fix the hiker stood at,
    /// though no leg was walked to or from it.
    @Test("a lone fix between two pauses is tested as the point it is")
    func loneFixIsTested() throws {
        var lone = OfflineCountryFixture.bay
        lone.boundary = .paused
        var resumed = east
        resumed.boundary = .paused

        let coverage = try OfflineRouteCoverage(walking: [west, lone, resumed], through: [concave])

        #expect(coverage == OfflineRouteCoverage(crossed: [concave], leavesThem: true))
    }

    /// Three strips, south to north. Both points of the line are in the outer
    /// two, and its one leg crosses the middle one.
    @Test("a leg over two borders names the country between them, in the order it reaches it")
    func legThroughAMiddleCountry() throws {
        let south = Self.area("SI", [Self.box(13, 45, 15, 46)])
        let middle = Self.area("AT", [Self.box(13, 46, 15, 47)])
        let north = Self.area("DE", [Self.box(13, 47, 15, 48)])

        let coverage = try OfflineRouteCoverage(
            walking: [Self.point(45.5, 14), Self.point(47.5, 14.2)],
            through: [north, south, middle]
        )

        #expect(coverage.crossed.map(\.id) == ["SI", "AT", "DE"])
        #expect(!coverage.leavesThem)
    }

    /// San Marino in Italy: the enclave's outline is inside its neighbour's,
    /// and a leg that crosses it, starting and ending in Italy, needs it.
    @Test("a leg through an enclave names the enclave")
    func legThroughAnEnclave() throws {
        let outer = Self.area("IT", [Self.box(12, 43, 13, 44)])
        let enclave = Self.area("SM", [Self.box(12.4, 43.4, 12.6, 43.6)])

        let coverage = try OfflineRouteCoverage(
            walking: [Self.point(43.5, 12.2), Self.point(43.5, 12.8)],
            through: [outer, enclave]
        )

        #expect(coverage.crossed.map(\.id) == ["IT", "SM"])
        #expect(!coverage.leavesThem)
    }

    /// A trail on Taveuni, over the 180th meridian, where the outline is cut
    /// in two. Read across the plane the long way, the leg would cross every
    /// country on the latitude.
    @Test("a leg over the antimeridian goes the short way round")
    func legOverTheAntimeridian() throws {
        let island = Self.area("FJ", [Self.box(179.5, -17, 180, -16.5), Self.box(-180, -17, -179.5, -16.5)])
        let longWayRound = Self.area("BO", [Self.box(-66, -18, -60, -15)])

        let eastward = try OfflineRouteCoverage(
            walking: [Self.point(-16.8, 179.8), Self.point(-16.7, -179.8)],
            through: [island, longWayRound]
        )
        let westward = try OfflineRouteCoverage(
            walking: [Self.point(-16.7, -179.8), Self.point(-16.8, 179.8)],
            through: [island, longWayRound]
        )

        #expect(eastward == OfflineRouteCoverage(crossed: [island], leavesThem: false))
        #expect(westward == OfflineRouteCoverage(crossed: [island], leavesThem: false))
    }

    /// Twenty thousand fixes, every one tested: one strays over the bay
    /// halfway along, which a sample of the line's points would pass over.
    @Test("every leg of a long line is tested")
    func everyLegOfALongLine() throws {
        let inArm = (0..<20_000).map { Self.point(45.95 + Double($0) * 0.00002, 13.6) }
        var strayed = inArm
        strayed[10_000] = Self.point(strayed[10_000].latitude, 14.25)

        let kept = try OfflineRouteCoverage(walking: inArm, through: [concave])
        let left = try OfflineRouteCoverage(walking: strayed, through: [concave])

        #expect(kept == OfflineRouteCoverage(crossed: [concave], leavesThem: false))
        #expect(left == OfflineRouteCoverage(crossed: [concave], leavesThem: true))
    }

    @Test("a leg along an edge of the outline, and one ending on it, are measured")
    func legsOnTheOutline() throws {
        let alongTheSouth = [Self.point(45.6, 13.7), Self.point(45.6, 14.2)]
        let ontoTheBay = [west, Self.point(46.3, 13.8)]

        #expect(try OfflineRouteCoverage(walking: alongTheSouth, through: [concave]).crossed == [concave])
        #expect(
            try OfflineRouteCoverage(walking: ontoTheBay, through: [concave])
                == OfflineRouteCoverage(crossed: [concave], leavesThem: false)
        )
    }

    /// A hiker who leaves the screen stops the work, rather than letting a
    /// long line finish for nobody.
    @Test("a cancelled measurement stops")
    @MainActor
    func cancelledMeasurementStops() async {
        let route = [west, east]
        let countries = [concave]
        let task = Task {
            try await OfflineCountries.coverage(alongRoute: route, offered: countries, installed: [:])
        }
        task.cancel()

        let result = await task.result

        #expect(throws: CancellationError.self) { try result.get() }
    }
}

// swiftlint:enable no_magic_numbers
