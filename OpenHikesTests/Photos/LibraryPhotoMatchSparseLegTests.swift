//
//  LibraryPhotoMatchSparseLegTests.swift
//  OpenHikesTests
//
//  Whether a camera's own position is on a route whose fixes are far apart.
//
//  A recording is sampled every few metres, but a timestamped GPX can be a
//  point every twenty minutes, and the line between two of them is still the
//  line that was walked. The timeline rightly refuses to interpolate a photo
//  ten minutes into such a leg; what is left is the camera's own fix, and that
//  has to be tested against the leg itself rather than against its two ends a
//  kilometre and a half apart (#965).
//
//  The other half is what is *not* a leg. A paused stretch was never walked,
//  and a bridged one was never measured, so neither may turn a picture taken
//  somewhere along its straight line into a match — only its two real fixes
//  count, as they always have.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

@Suite("Library photo match on sparse legs")
struct LibraryPhotoMatchSparseLegTests {
    private static let epoch = Date(timeIntervalSince1970: 1_750_000_000)
    /// Twenty minutes: four times the timeline's grace, so a photo at the
    /// middle of the leg is ten minutes from either fix and the clock cannot
    /// place it.
    private static let legSeconds: TimeInterval = 1200
    private static let start = CLLocationCoordinate2D(latitude: 47, longitude: 12)
    /// About 1.5 km east, the leg #965 reproduced with.
    private static let end = CLLocationCoordinate2D(latitude: 47, longitude: 12.02)
    private static let midpoint = CLLocationCoordinate2D(latitude: 47, longitude: 12.01)
    private static let metersPerDegreeLatitude = 111_320.0
    private static let toleranceMeters = 1.0

    /// Two fixes `legSeconds` apart, the second arriving over `boundary` or
    /// `provenance` when given.
    private static func route(
        boundary: RouteBoundary? = nil,
        provenance: RouteProvenance? = nil
    ) -> [RouteCoordinate] {
        [
            RouteCoordinate(latitude: start.latitude, longitude: start.longitude, timestamp: epoch),
            RouteCoordinate(
                latitude: end.latitude,
                longitude: end.longitude,
                timestamp: epoch.addingTimeInterval(legSeconds),
                provenance: provenance,
                boundary: boundary
            ),
        ]
    }

    /// What a search finds for a photo taken at `coordinate` halfway through
    /// the leg, ten minutes from either fix.
    private static func matches(
        on route: [RouteCoordinate],
        at coordinate: CLLocationCoordinate2D
    ) throws -> [LibraryPhotoMatch] {
        let timeline = try #require(HikePhotoTimeline(route: route))
        return HikePhotoSearchPlan(timeline: timeline, walks: [], route: route).matches(
            assets: [
                PhotoLibraryAsset(
                    localIdentifier: "photo",
                    createdAt: epoch.addingTimeInterval(legSeconds / 2),
                    coordinate: coordinate
                ),
            ]
        )
    }

    /// `meters` north of the leg's midpoint, which the leg runs due east
    /// through, so `meters` is also how far off it the point lies.
    private static func besideMidpoint(byMeters meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: midpoint.latitude + meters / metersPerDegreeLatitude,
            longitude: midpoint.longitude
        )
    }

    @Test("the timeline itself declines the middle of the leg")
    func timelineDeclinesTheMiddle() throws {
        let timeline = try #require(HikePhotoTimeline(route: Self.route()))

        #expect(timeline.position(at: Self.epoch.addingTimeInterval(Self.legSeconds / 2)) == nil)
    }

    @Test("a geotagged photo on the line between two sparse fixes is placed on it")
    func photoOnASparseLegIsPlaced() throws {
        let match = try #require(try Self.matches(on: Self.route(), at: Self.midpoint).first)

        #expect(match.evidence == .place)
        #expect(match.secondsFromFix == 0)
        let snappedOff = RouteGeometry.distanceMeters(from: match.coordinate, to: Self.midpoint)
        #expect(snappedOff.isApproximatelyEqual(to: 0, absoluteTolerance: Self.toleranceMeters))
    }

    @Test("a photo near a sparse leg is snapped onto the line, not onto a fix")
    func photoBesideASparseLegIsSnappedOntoIt() throws {
        let beside = Self.besideMidpoint(byMeters: LibraryPhotoMatcher.maximumOffRouteMeters / 2)

        let match = try #require(try Self.matches(on: Self.route(), at: beside).first)

        #expect(match.evidence == .place)
        let snappedOff = RouteGeometry.distanceMeters(from: match.coordinate, to: Self.midpoint)
        #expect(snappedOff.isApproximatelyEqual(to: 0, absoluteTolerance: Self.toleranceMeters))
    }

    @Test("a photo off a sparse leg by more than the limit is still refused")
    func photoOffASparseLegIsRefused() throws {
        let away = Self.besideMidpoint(byMeters: LibraryPhotoMatcher.maximumOffRouteMeters + 20)

        #expect(try Self.matches(on: Self.route(), at: away).isEmpty)
    }

    /// The cable car between two trailheads: the line between the fix before
    /// the pause and the one that resumed it was never walked.
    @Test("a photo on a paused leg is refused")
    func photoOnAPausedLegIsRefused() throws {
        #expect(try Self.matches(on: Self.route(boundary: .paused), at: Self.midpoint).isEmpty)
    }

    /// A straight bridge across a GPS gap is the app's guess at where the
    /// hiker went, so a camera somewhere along it is not on the measured route.
    @Test("a photo on a bridged leg is refused")
    func photoOnAnInferredLegIsRefused() throws {
        #expect(try Self.matches(on: Self.route(provenance: .inferred), at: Self.midpoint).isEmpty)
    }

    /// The fixes either side of a pause are still real, so a camera standing
    /// at one of them is on the route, as it always was.
    @Test("a photo at the fix that ended a pause is still on the route")
    func photoAtAPausedLegsFixIsPlaced() throws {
        let match = try #require(try Self.matches(on: Self.route(boundary: .paused), at: Self.end).first)

        #expect(match.evidence == .place)
        let snappedOff = RouteGeometry.distanceMeters(from: match.coordinate, to: Self.end)
        #expect(snappedOff.isApproximatelyEqual(to: 0, absoluteTolerance: Self.toleranceMeters))
    }
}
