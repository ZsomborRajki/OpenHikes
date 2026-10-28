//
//  LibraryPhotoMatchCoveredLegTests.swift
//  OpenHikesTests
//
//  A geotagged photograph placed within a walk, on a route that passes the
//  same ground twice (#1114).
//
//  An out-and-back's return leg lies on its outbound one, and a junction a
//  route crosses twice is two distances along it. Projected onto the route
//  alone, such a place is the *first* of them — and a walk that covered only
//  the later one had its photographs refused for being on ground it never
//  covered, when the very same point was on the stretch it had. The walk is
//  what decides between two equally good answers; the last test is the
//  control that it decides nothing else.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Library photo match on a covered leg")
struct LibraryPhotoMatchCoveredLegTests {
    private static let start = Date(timeIntervalSince1970: 1_750_000_000)
    private static let hour: TimeInterval = 3600

    private static func point(_ latitude: Double, _ longitude: Double) -> RouteCoordinate {
        RouteCoordinate(latitude: latitude, longitude: longitude, elevation: nil, timestamp: nil)
    }

    /// An imported route with no clock: out along a parallel and straight
    /// back, about 1.5 km each way.
    private static let outAndBack = RouteProfile(route: [
        point(47, 19), point(47, 19.02), point(47, 19),
    ])

    /// East through a junction at (47, 19.01), round a square to the north,
    /// and back south through the same junction, crossing the first pass at
    /// right angles.
    private static let crossing = RouteProfile(route: [
        point(47, 19), point(47, 19.01), point(47, 19.02),
        point(47.01, 19.02), point(47.01, 19.01), point(46.99, 19.01),
    ])

    /// A walk over `covered`, metres along the route, between 10:00 and
    /// 11:00.
    private static func walk(covering covered: ClosedRange<Double>) throws -> HikeWalkPhotoTimeline {
        try #require(HikeWalkPhotoTimeline(
            startedAt: start,
            endedAt: start.addingTimeInterval(hour),
            coverage: TrailWalkCoverage(
                intervals: [covered.lowerBound, covered.upperBound],
                furthestDistanceMeters: covered.upperBound
            )
        ))
    }

    /// A photograph taken half way through the walk, where the camera says.
    private static func photo(at latitude: Double, _ longitude: Double) -> PhotoLibraryAsset {
        PhotoLibraryAsset(
            localIdentifier: "photo",
            createdAt: start.addingTimeInterval(hour / 2),
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
    }

    private static func isAt(
        _ match: LibraryPhotoMatch,
        _ latitude: Double,
        _ longitude: Double
    ) -> Bool {
        match.latitude.isApproximatelyEqual(to: latitude, absoluteTolerance: 1e-6)
            && match.longitude.isApproximatelyEqual(to: longitude, absoluteTolerance: 1e-6)
    }

    /// The audit's own case: a walk that covered only the way home, and a
    /// photograph taken half way along that leg.
    @Test("a photo on the covered return leg of an out-and-back is kept")
    func returnLegOfAnOutAndBack() throws {
        let profile = Self.outAndBack
        let turn = profile.distances[1]
        let walk = try Self.walk(covering: turn...profile.totalDistanceMeters)

        let match = try #require(LibraryPhotoMatcher.match(
            Self.photo(at: 47, 19.01),
            walk: walk,
            profile: profile
        ))

        #expect(match.evidence == .place)
        #expect(Self.isAt(match, 47, 19.01))
    }

    /// A walk that took only the second pass through a junction, and a
    /// photograph of the junction itself.
    @Test("a photo at a junction the walk crossed on its second pass is kept")
    func secondPassThroughAJunction() throws {
        let profile = Self.crossing
        let walk = try Self.walk(covering: profile.distances[4]...profile.totalDistanceMeters)

        let match = try #require(LibraryPhotoMatcher.match(
            Self.photo(at: 47, 19.01),
            walk: walk,
            profile: profile
        ))

        #expect(Self.isAt(match, 47, 19.01))
    }

    /// The control. The same walk, and a photograph on the first pass only,
    /// where the route has no second leg for the walk to have covered.
    @Test("a photo on ground the walk never covered is still refused")
    func uncoveredGroundIsRefused() throws {
        let profile = Self.crossing
        let walk = try Self.walk(covering: profile.distances[4]...profile.totalDistanceMeters)

        #expect(LibraryPhotoMatcher.match(
            Self.photo(at: 47, 19.02),
            walk: walk,
            profile: profile
        ) == nil)
    }

    /// The control on the out-and-back: a hiker who turned back in its first
    /// half never reached the far end, along either leg.
    @Test("a photo past where an out-and-back was turned back is still refused")
    func pastTheTurnIsRefused() throws {
        let profile = Self.outAndBack
        let walk = try Self.walk(covering: 0...(profile.distances[1] / 2))

        #expect(LibraryPhotoMatcher.match(
            Self.photo(at: 47, 19.018),
            walk: walk,
            profile: profile
        ) == nil)
    }

    /// A stationary GPX piece after a pause shares its distance with the
    /// previous piece. Resolving that distance again can return the other
    /// end of the transfer, even though the chosen projection is on-camera.
    @Test("a duplicate-fix piece after a pause keeps its own projected position", arguments: [false, true])
    func duplicateFixesAfterPause(continuesAfterAnotherPause: Bool) throws {
        var route = [
            Self.point(47.00005, 19), Self.point(47.00005, 19.02),
            RouteCoordinate(latitude: 47, longitude: 19, boundary: .paused),
            Self.point(47, 19),
        ]
        if continuesAfterAnotherPause {
            route += [
                RouteCoordinate(latitude: 48, longitude: 20, boundary: .paused),
                Self.point(48, 20.02),
            ]
        }
        let profile = RouteProfile(route: route)
        let walk = try Self.walk(covering: 0...profile.totalDistanceMeters)
        let asset = Self.photo(at: 47, 19)

        let match = try #require(LibraryPhotoMatcher.match(asset, walk: walk, profile: profile))

        #expect(match.evidence == .place)
        #expect(Self.isAt(match, 47, 19))
        #expect(RouteGeometry.distanceMeters(
            from: try #require(asset.coordinate),
            to: match.coordinate
        ) <= LibraryPhotoMatcher.maximumOffRouteMeters)
    }
}
