//
//  RouteArchiveTests.swift
//  OpenHikesTests
//
//  The one property the whole sync feature rests on: a route that goes to
//  iCloud comes back the same route.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Route archive")
struct RouteArchiveTests {
    private enum Constants {
        static let longRoutePoints = 5000
        static let latitudeStep = 0.00002
        static let longitudeStep = 0.00003
        static let elevationStep = 0.15
        static let baseLatitude = 47.63
        static let baseLongitude = 12.86
        static let baseElevation = 600.0
        static let secondsPerFix = 2.0
        /// A recorded route has to survive the trip smaller than it started,
        /// or the compression step is paying for itself in nothing.
        static let worthwhileCompressionRatio = 0.5
    }

    private static func longRoute() -> [RouteCoordinate] {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        return (0..<Constants.longRoutePoints).map { index in
            RouteCoordinate(
                latitude: Constants.baseLatitude + Double(index) * Constants.latitudeStep,
                longitude: Constants.baseLongitude + Double(index) * Constants.longitudeStep,
                elevation: Constants.baseElevation + Double(index) * Constants.elevationStep,
                timestamp: start.addingTimeInterval(Double(index) * Constants.secondsPerFix)
            )
        }
    }

    @Test("A route survives the round trip unchanged")
    func roundTripPreservesEveryPoint() throws {
        let route = Fixture.ridgeRoute
        let encoded = try RouteArchive.encode(route)
        let decoded = try RouteArchive.decode(encoded)

        #expect(decoded.count == route.count)
        for (original, restored) in zip(route, decoded) {
            #expect(original.latitude == restored.latitude)
            #expect(original.longitude == restored.longitude)
            #expect(original.elevation == restored.elevation)
            #expect(original.timestamp == restored.timestamp)
        }
    }

    /// An empty route is what every imported hike's `rawRoute` is, so it has
    /// to be an ordinary value rather than an edge case that throws.
    @Test("An empty route round-trips to an empty route")
    func emptyRouteRoundTrips() throws {
        let encoded = try RouteArchive.encode([])
        #expect(try RouteArchive.decode(encoded).isEmpty)
    }

    /// The reason the encoding is compressed at all: a day's recording has to
    /// fit through a trailhead's signal.
    @Test("A recorded route compresses to a fraction of its JSON")
    func longRouteCompresses() throws {
        let route = Self.longRoute()
        let encoded = try RouteArchive.encode(route)
        let plain = try JSONEncoder().encode(route)

        #expect(encoded.count < Int(Double(plain.count) * Constants.worthwhileCompressionRatio))
        #expect(try RouteArchive.decode(encoded).count == route.count)
    }

    /// A record written by a future build has to be refused rather than
    /// guessed at — the difference between showing nothing and showing a
    /// mangled trail.
    @Test("A route written by an unknown version is refused")
    func unknownVersionThrows() throws {
        let encoded = try RouteArchive.encode(Fixture.ridgeRoute)
        #expect(throws: RouteArchive.Failure.unsupportedVersion(RouteArchive.version + 1)) {
            try RouteArchive.decode(encoded, version: RouteArchive.version + 1)
        }
    }

    @Test("Bytes that aren't an archive are refused")
    func corruptDataThrows() {
        #expect(throws: RouteArchive.Failure.decodingFailed) {
            try RouteArchive.decode(Data("not a route".utf8))
        }
    }
}
