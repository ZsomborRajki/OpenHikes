//
//  LibraryPhotoMatchTests.swift
//  OpenHikesTests
//
//  Which pictures in a photo library are pictures of a given walk.
//
//  Three of these are the point of the file. A photograph whose camera
//  recorded a position that agrees with the walk is the strongest match this
//  app can make, and has to be reported as such rather than quietly treated
//  like the rest. A photograph taken during the walk but nowhere near it —
//  a receipt, a screenshot, somebody's kitchen — has to be refused, or the
//  scan offers everything anyone did that afternoon. And a photograph inside a
//  GPS gap, which the walk itself cannot place, is exactly the case where the
//  camera's own reading is worth having.
//
//  The rest pin the smaller promises: the window is enforced here as well as
//  in the fetch, photos already taken are not offered twice, and the results
//  come back in the order they were taken.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Library photo match")
struct LibraryPhotoMatchTests {
    private static let latitude: Double = 47.6300
    private static let longitude: Double = 12.8600
    private static let latitudeStep = 0.001
    private static let stepSeconds: TimeInterval = 60
    private static let epoch = Date(timeIntervalSince1970: 1_750_000_000)
    private static let stepCount = 10
    /// Roughly one metre of latitude, for nudging a coordinate by a known,
    /// small amount.
    private static let metersPerDegreeLatitude = 111_320.0

    private static let route: [RouteCoordinate] = (0..<stepCount).map { index in
        RouteCoordinate(
            latitude: latitude + latitudeStep * Double(index),
            longitude: longitude,
            elevation: nil,
            timestamp: epoch.addingTimeInterval(stepSeconds * Double(index))
        )
    }

    private static func timeline() throws -> HikePhotoTimeline {
        try #require(HikePhotoTimeline(route: route))
    }

    private static func date(atStep step: Double) -> Date {
        epoch.addingTimeInterval(stepSeconds * step)
    }

    /// A coordinate `meters` north of the route point at `step`.
    private static func offRoute(
        fromStep step: Int,
        byMeters meters: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: route[step].latitude + meters / metersPerDegreeLatitude,
            longitude: longitude
        )
    }

    private static func asset(
        _ identifier: String,
        atStep step: Double,
        coordinate: CLLocationCoordinate2D? = nil
    ) -> PhotoLibraryAsset {
        PhotoLibraryAsset(
            localIdentifier: identifier,
            createdAt: date(atStep: step),
            coordinate: coordinate
        )
    }

    @Test("a photo with no location of its own is placed by the clock alone")
    func photoWithoutLocationIsPlacedByTime() throws {
        let match = try #require(
            LibraryPhotoMatcher.match(
                Self.asset("a", atStep: 3),
                timeline: Self.timeline(),
                route: Self.route
            )
        )

        #expect(match.evidence == .time)
        #expect(match.secondsFromFix == 0)
        #expect(
            RouteGeometry.distanceMeters(
                from: match.coordinate,
                to: Self.route[3].clCoordinate
            ) < 1
        )
    }

    @Test("a photo whose own location agrees with the walk is matched by both")
    func agreeingLocationIsMatchedByBoth() throws {
        let match = try #require(
            LibraryPhotoMatcher.match(
                Self.asset(
                    "a",
                    atStep: 3,
                    coordinate: Self.offRoute(fromStep: 3, byMeters: 20)
                ),
                timeline: Self.timeline(),
                route: Self.route
            )
        )

        #expect(match.evidence == .timeAndPlace)
        // The walk's own point, not the camera's: a filtered series beats one
        // reading taken through whatever the sky was doing.
        #expect(
            RouteGeometry.distanceMeters(
                from: match.coordinate,
                to: Self.route[3].clCoordinate
            ) < 1
        )
    }

    /// The picture of a receipt taken in a cafe halfway round the walk. The
    /// clock says it belongs and the place says it plainly does not.
    @Test("a photo taken during the walk but far from it is refused")
    func photoTakenElsewhereIsRefused() throws {
        let farAway = CLLocationCoordinate2D(
            latitude: Self.latitude + 1,
            longitude: Self.longitude + 1
        )

        let match = LibraryPhotoMatcher.match(
            Self.asset("a", atStep: 3, coordinate: farAway),
            timeline: try Self.timeline(),
            route: Self.route
        )

        #expect(match == nil)
    }

    /// The one case where the camera's own reading is the better source: the
    /// walk produced no fix anywhere near this moment, so there is nothing to
    /// interpolate from — but the picture was taken standing on the route.
    @Test("a photo inside a GPS gap is placed by its own location")
    func photoInsideAGapIsPlacedByLocation() throws {
        let gap = HikePhotoTimeline.graceInterval * 8
        let gapped = [
            Self.route[0],
            RouteCoordinate(
                latitude: Self.latitude + Self.latitudeStep,
                longitude: Self.longitude,
                elevation: nil,
                timestamp: Self.epoch.addingTimeInterval(gap)
            ),
        ]
        let timeline = try #require(HikePhotoTimeline(route: gapped))
        let onRoute = CLLocationCoordinate2D(
            latitude: gapped[1].latitude,
            longitude: gapped[1].longitude
        )

        let match = try #require(
            LibraryPhotoMatcher.match(
                PhotoLibraryAsset(
                    localIdentifier: "a",
                    createdAt: Self.epoch.addingTimeInterval(gap / 2),
                    coordinate: onRoute
                ),
                timeline: timeline,
                route: gapped
            )
        )

        #expect(match.evidence == .place)
        #expect(
            RouteGeometry.distanceMeters(from: match.coordinate, to: onRoute) < 1
        )
    }

    @Test("a photo inside a GPS gap with no location of its own is refused")
    func photoInsideAGapWithoutLocationIsRefused() throws {
        let gap = HikePhotoTimeline.graceInterval * 8
        let gapped = [
            Self.route[0],
            RouteCoordinate(
                latitude: Self.latitude + Self.latitudeStep,
                longitude: Self.longitude,
                elevation: nil,
                timestamp: Self.epoch.addingTimeInterval(gap)
            ),
        ]
        let timeline = try #require(HikePhotoTimeline(route: gapped))

        let match = LibraryPhotoMatcher.match(
            PhotoLibraryAsset(
                localIdentifier: "a",
                createdAt: Self.epoch.addingTimeInterval(gap / 2)
            ),
            timeline: timeline,
            route: gapped
        )

        #expect(match == nil)
    }

    @Test("an asset outside the walk's window is refused by the matcher too")
    func assetOutsideTheWindowIsRefused() throws {
        let timeline = try Self.timeline()
        let late = timeline.end.addingTimeInterval(
            HikePhotoTimeline.graceInterval * 2
        )

        let matches = LibraryPhotoMatcher.matches(
            assets: [
                PhotoLibraryAsset(localIdentifier: "late", createdAt: late),
            ],
            timeline: timeline,
            route: Self.route
        )

        #expect(matches.isEmpty)
    }

    @Test("a photo already imported is not offered again")
    func alreadyImportedAssetsAreSkipped() throws {
        let matches = LibraryPhotoMatcher.matches(
            assets: [
                Self.asset("kept", atStep: 2),
                Self.asset("taken", atStep: 4),
            ],
            timeline: try Self.timeline(),
            route: Self.route,
            alreadyImported: ["taken"]
        )

        #expect(matches.map(\.id) == ["kept"])
    }

    @Test("matches come back in the order the photos were taken")
    func matchesAreOrderedByCaptureTime() throws {
        let matches = LibraryPhotoMatcher.matches(
            assets: [
                Self.asset("third", atStep: 7),
                Self.asset("first", atStep: 1),
                Self.asset("second", atStep: 4),
            ],
            timeline: try Self.timeline(),
            route: Self.route
        )

        #expect(matches.map(\.id) == ["first", "second", "third"])
    }

    /// The tolerance is deliberately generous, because two imperfect fixes of
    /// one place disagree by tens of metres routinely. This pins the number so
    /// that widening it is a decision rather than a drift.
    @Test("disagreement inside the tolerance is still a time-and-place match")
    func disagreementInsideToleranceStillCorroborates() throws {
        let nearly = LibraryPhotoMatcher.separationToleranceMeters - 10

        let match = try #require(
            LibraryPhotoMatcher.match(
                Self.asset(
                    "a",
                    atStep: 3,
                    coordinate: Self.offRoute(fromStep: 3, byMeters: nearly)
                ),
                timeline: Self.timeline(),
                route: Self.route
            )
        )

        #expect(match.evidence == .timeAndPlace)
    }

    /// Past the tolerance the two readings describe different places, and the
    /// camera's only wins if it is itself on the route — which, just off the
    /// end of the trail, it is not.
    @Test("disagreement past the tolerance and off the route is refused")
    func disagreementPastToleranceOffRouteIsRefused() throws {
        let far = LibraryPhotoMatcher.separationToleranceMeters
            + LibraryPhotoMatcher.maximumOffRouteMeters
            + Self.metersPerDegreeLatitude / 100

        let match = LibraryPhotoMatcher.match(
            Self.asset(
                "a",
                atStep: 0,
                coordinate: Self.offRoute(fromStep: 0, byMeters: -far)
            ),
            timeline: try Self.timeline(),
            route: Self.route
        )

        #expect(match == nil)
    }
}
