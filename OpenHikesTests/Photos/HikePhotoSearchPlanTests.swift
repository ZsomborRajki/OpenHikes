//
//  HikePhotoSearchPlanTests.swift
//  OpenHikesTests
//
//  Which of a hike's two clocks answers for a photograph, and what happens on
//  the trails that only have the weaker one.
//
//  The case that brought this file into existence is the ordinary one: a GPX
//  imported from somewhere, walked this afternoon, photographed with the
//  system camera. Its route carries the original recorder's timestamps or
//  none, so the scan used to open a window on somebody else's day and report
//  that the walk had no photographs. The walk itself is what closes that, and
//  the tests below pin both halves of it — that a walk can place a photograph
//  at all, and that it is never allowed to overrule the route where the route
//  has an answer, including where that answer is a refusal.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Hike photo search plan")
struct HikePhotoSearchPlanTests {
    private static let profile = RouteProfile(route: PhotoDiscoveryFixture.route)
    private static var routeMeters: Double { profile.totalDistanceMeters }

    /// A walk of the whole trail, taking exactly as long as the fixture's ten
    /// points span.
    private static func wholeWalk() -> HikeWalkPhotoTimeline? {
        walk(covering: 0...routeMeters)
    }

    private static func walk(
        covering stretch: ClosedRange<Double>,
        fromStep: Double = 0,
        toStep: Double = 9
    ) -> HikeWalkPhotoTimeline? {
        HikeWalkPhotoTimeline(
            startedAt: PhotoDiscoveryFixture.date(atStep: fromStep),
            endedAt: PhotoDiscoveryFixture.date(atStep: toStep),
            coverage: TrailWalkCoverage(
                intervals: [stretch.lowerBound, stretch.upperBound],
                furthestDistanceMeters: stretch.upperBound
            )
        )
    }

    private static func plan(
        walks: [HikeWalkPhotoTimeline],
        timeline: HikePhotoTimeline? = nil,
        route: [RouteCoordinate] = PhotoDiscoveryFixture.unstampedRoute
    ) -> HikePhotoSearchPlan {
        HikePhotoSearchPlan(timeline: timeline, walks: walks, route: route)
    }

    private static func metres(
        from match: LibraryPhotoMatch,
        to coordinate: CLLocationCoordinate2D
    ) -> Double {
        RouteGeometry.distanceMeters(from: match.coordinate, to: coordinate)
    }

    /// Nothing to ask with. The one case the offer on the hike screen cannot
    /// be honoured on, and the reason the sheet has a state that says so.
    @Test("a trail with no clock and no walk has nothing to search")
    func nothingToSearch() {
        let plan = Self.plan(walks: [])

        #expect(plan.isEmpty)
        #expect(plan.searchWindows.isEmpty)
        #expect(plan.matches(assets: [PhotoDiscoveryFixture.asset("a", atStep: 2)]).isEmpty)
    }

    /// The whole point of the change: an imported route, a walk along it, and
    /// a photograph the system camera recorded no position for. The route
    /// cannot say a thing about it; the walk puts it where the walk had got.
    @Test("a walk places a photo an imported route cannot")
    func walkPlacesAPhotoOnAnImportedRoute() throws {
        let walk = try #require(Self.wholeWalk())
        let plan = Self.plan(walks: [walk])
        let halfWay = try #require(
            Self.profile.coordinate(atDistance: Self.routeMeters / 2)
        )

        let found = plan.matches(assets: [PhotoDiscoveryFixture.asset("a", atStep: 4.5)])

        let match = try #require(found.first)
        #expect(found.count == 1)
        #expect(match.evidence == .walk)
        #expect(Self.metres(from: match, to: halfWay) < 1)
    }

    /// The camera outranks the guess where it has something to say, exactly as
    /// it does against a recorded route: a photograph taken at the second
    /// point is pinned there and not at the two-thirds mark the clock would
    /// have put it at.
    @Test("a photo the camera placed on the covered stretch is pinned there")
    func cameraPositionOutranksEvenProgress() throws {
        let walk = try #require(Self.wholeWalk())
        let plan = Self.plan(walks: [walk])
        let takenAt = PhotoDiscoveryFixture.coordinate(atStep: 2)

        let found = plan.matches(
            assets: [PhotoDiscoveryFixture.asset("a", atStep: 6, coordinate: takenAt)]
        )

        let match = try #require(found.first)
        #expect(match.evidence == .place)
        #expect(Self.metres(from: match, to: takenAt) < 1)
    }

    /// What a walk adds that a route cannot. The trail runs to the summit and
    /// this walk turned back half way; a photograph the camera places at the
    /// summit is a photograph of the trail and not of this walk.
    @Test("a photo taken beyond what the walk covered is refused")
    func photoOffTheCoveredStretchIsRefused() throws {
        let walk = try #require(Self.walk(covering: 0...(Self.routeMeters / 2)))
        let plan = Self.plan(walks: [walk])
        let summit = PhotoDiscoveryFixture.coordinate(atStep: 9)

        let found = plan.matches(
            assets: [PhotoDiscoveryFixture.asset("a", atStep: 3, coordinate: summit)]
        )

        #expect(found.isEmpty)
    }

    /// The precedence rule, tested where it bites: a photograph inside a GPS
    /// gap that the route deliberately refuses to place. A walk spanning the
    /// same afternoon could offer a plausible point, and must not — those
    /// refusals are the careful part of this feature, and a coarse second
    /// opinion overturning them would trade correct absences for confident
    /// mistakes.
    @Test("the route's refusals are not overruled by a walk across the same hours")
    func routeRefusalStandsAgainstAWalk() throws {
        // Three points, then half an hour with no fix, then two more.
        let gapped: [RouteCoordinate] = [0, 1, 2, 32, 33].map { step in
            RouteCoordinate(
                latitude: PhotoDiscoveryFixture.latitude
                    + PhotoDiscoveryFixture.latitudeStep * Double(step),
                longitude: PhotoDiscoveryFixture.longitude,
                elevation: nil,
                timestamp: PhotoDiscoveryFixture.date(atStep: Double(step))
            )
        }
        let timeline = try #require(HikePhotoTimeline(route: gapped))
        let walk = try #require(Self.walk(covering: 0...Self.routeMeters, toStep: 33))
        let plan = Self.plan(walks: [walk], timeline: timeline, route: gapped)

        // Mid-gap: fifteen minutes from a fix either side, and no position of
        // its own for the camera to settle it with.
        let found = plan.matches(assets: [PhotoDiscoveryFixture.asset("a", atStep: 17)])

        #expect(found.isEmpty)
    }

    /// A recorded hike writes a walk covering the recording itself, so its
    /// window and the route's are the same afternoon — one fetch, not two.
    /// A walk taken years later is a second window, and the span between them
    /// is a query for every photograph the user owns.
    @Test("windows are merged where they overlap and kept apart where they do not")
    func windowsAreMergedButNotSpanned() throws {
        let timeline = try #require(HikePhotoTimeline(route: PhotoDiscoveryFixture.route))
        let sameDay = try #require(Self.wholeWalk())
        let yearsLater = try #require(
            HikeWalkPhotoTimeline(
                startedAt: PhotoDiscoveryFixture.epoch.addingTimeInterval(86_400 * 900),
                endedAt: PhotoDiscoveryFixture.epoch.addingTimeInterval(86_400 * 900 + 3600),
                coverage: TrailWalkCoverage(
                    intervals: [0, Self.routeMeters],
                    furthestDistanceMeters: Self.routeMeters
                )
            )
        )

        #expect(Self.plan(walks: [sameDay], timeline: timeline).searchWindows.count == 1)

        let both = Self.plan(walks: [sameDay, yearsLater], timeline: timeline)
        #expect(both.searchWindows.count == 2)
        #expect(both.searchWindows[0].upperBound < both.searchWindows[1].lowerBound)
    }

    /// A second scan offers only what the first one did not take.
    @Test("a photo already attached to the hike is not offered again")
    func alreadyImportedIsNotOffered() throws {
        let walk = try #require(Self.wholeWalk())
        let plan = Self.plan(walks: [walk])

        let found = plan.matches(
            assets: [
                PhotoDiscoveryFixture.asset("a", atStep: 3),
                PhotoDiscoveryFixture.asset("b", atStep: 5),
            ],
            alreadyImported: ["a"]
        )

        #expect(found.map(\.id) == ["b"])
    }

    /// Nothing upstream is trusted to have filtered: a stub, a widened
    /// predicate or a library that rounds a creation date must not be able to
    /// smuggle a photograph from another day past the plan.
    @Test("an asset outside every window is refused here too")
    func assetOutsideEveryWindowIsRefused() throws {
        let walk = try #require(Self.wholeWalk())
        let plan = Self.plan(walks: [walk])

        let found = plan.matches(assets: [PhotoDiscoveryFixture.asset("a", atStep: 200)])

        #expect(found.isEmpty)
    }
}
