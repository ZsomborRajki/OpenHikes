//
//  HikeWalkPhotoRouteRevisionTests.swift
//  OpenHikesTests
//
//  A walk is read for photographs only along the line it was walked on.
//
//  A walk's covered stretches are distances along the route as it was when the
//  walk ended, and *Edit Route* keeps a drawn trail's walks as history. After
//  an edit the same distances name other ground — the far end of a reversed
//  line, a different bend of a rerouted one — so placing a photograph by them
//  pins it where the walker never was. A walk that names no line at all is
//  along none. These pin the rule the walk summary already follows, see
//  ``HikeWalk/isAlong(revision:)``: a walk along a different line contributes
//  nothing to the photo search, and one along the current line contributes
//  exactly as it did.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Hike walk photo route revision")
struct HikeWalkPhotoRouteRevisionTests {
    /// The ways a hike's line changes after it has been walked.
    nonisolated enum RouteEdit: CaseIterable, Sendable {
        case reversed
        case extended
        case rerouted

        /// How far a rerouted line's middle moves sideways, in degrees of
        /// longitude: about forty metres, a deliberate change of line and not
        /// the noise a re-saved coordinate could carry.
        private static let sidestep = 0.0005

        func apply(to route: [RouteCoordinate]) -> [RouteCoordinate] {
            switch self {
            case .reversed:
                Array(route.reversed())
            case .extended:
                route + [
                    RouteCoordinate(
                        latitude: PhotoDiscoveryFixture.latitude
                            + PhotoDiscoveryFixture.latitudeStep * Double(PhotoDiscoveryFixture.stepCount),
                        longitude: PhotoDiscoveryFixture.longitude
                    ),
                ]
            case .rerouted:
                route.enumerated().map { index, point in
                    var moved = point
                    if index == route.count / 2 { moved.longitude += Self.sidestep }
                    return moved
                }
            }
        }
    }

    /// The afternoon a hike is walked again, long after the first.
    private static let laterAfternoon: ClosedRange<Double> = 100...104

    private static var routeMeters: Double {
        RouteProfile(route: PhotoDiscoveryFixture.unstampedRoute).totalDistanceMeters
    }

    /// A finished walk over the first half of the fixture route, between two
    /// moments in route steps, along the line `revision` names — the fixture
    /// route's own unless a test says otherwise.
    @discardableResult private static func addWalk(
        to hike: Hike,
        in context: ModelContext,
        steps: ClosedRange<Double> = 0...9,
        along revision: String? = PhotoDiscoveryFixture.routeRevision
    ) -> HikeWalk {
        let walk = PhotoDiscoveryFixture.walk(
            hikeID: hike.id,
            fromStep: steps.lowerBound,
            toStep: steps.upperBound,
            covering: 0...(routeMeters / 2),
            routeDistanceMeters: routeMeters,
            routeRevision: revision
        )
        context.insert(walk)
        walk.hike = hike
        return walk
    }

    /// The control, and the half of the rule that must not over-reach: a walk
    /// along the line the hike has is read, and a height filled in on a route
    /// that had none moves no position, so the walks stay readable through it.
    @Test("a walk along the hike's current route still counts")
    func walkAlongTheCurrentRouteCounts() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        Self.addWalk(to: hike, in: context)

        #expect(hike.walkPhotoTimelines.count == 1)
        #expect(hike.canMatchLibraryPhotos)
        #expect(!hike.photoSearchPlan.isEmpty)

        hike.route = hike.route.map { point in
            var filled = point
            filled.elevation = 100
            return filled
        }

        #expect(hike.walkPhotoTimelines.count == 1)
    }

    /// The bug: the hike's only walk was along a line it no longer has, and
    /// the photo search went on using it — advertising a scan of the library
    /// and placing what it found by stretches that mean something else now.
    @Test("a walk along a line the hike no longer has is not read", arguments: RouteEdit.allCases)
    func walkAlongAnEditedRouteIsIgnored(edit: RouteEdit) throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        Self.addWalk(to: hike, in: context)

        hike.route = edit.apply(to: hike.route)

        #expect(hike.walkPhotoTimelines.isEmpty)
        #expect(!hike.canMatchLibraryPhotos)
        #expect(hike.photoSearchPlan.isEmpty)
    }

    /// Strict, as the walk summary's test is: a walk that records no line is
    /// along none, rather than along whichever line the hike happens to have.
    @Test("a walk that names no line is not read")
    func walkWithNoRevisionIsIgnored() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        Self.addWalk(to: hike, in: context, along: nil)

        #expect(hike.walkPhotoTimelines.isEmpty)
        #expect(hike.photoSearchPlan.isEmpty)
    }

    /// *Edit Route*, then walked again: the ordinary way a drawn trail comes to
    /// hold both. The afternoon before the edit goes, the one after stays.
    @Test("only the walks along the edited line are kept")
    func walkAlongTheNewLineSurvivesTheEdit() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        Self.addWalk(to: hike, in: context)

        hike.route = RouteEdit.rerouted.apply(to: hike.route)
        Self.addWalk(
            to: hike,
            in: context,
            steps: Self.laterAfternoon,
            along: TrailWalkRecord.routeRevision(of: hike.route)
        )

        let kept = hike.walkPhotoTimelines.map(\.startedAt)
        #expect(kept == [PhotoDiscoveryFixture.date(atStep: Self.laterAfternoon.lowerBound)])
    }

    /// What the rule is for. The walk covered the first half of the line it
    /// was walked on; on the reversed line those distances are the other end
    /// of the trail, so a photograph taken during the walk would be pinned to
    /// ground the walker never reached — by clock when it has no position of
    /// its own, and past the coverage test when it has.
    @Test("a walk along another line pins no photograph")
    func staleWalkPlacesNothing() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: PhotoDiscoveryFixture.unstampedRoute)
        Self.addWalk(to: hike, in: context)

        hike.route = RouteEdit.reversed.apply(to: hike.route)

        let located = PhotoDiscoveryFixture.asset(
            "located",
            atStep: 7,
            coordinate: PhotoDiscoveryFixture.coordinate(atStep: 7)
        )
        let unlocated = PhotoDiscoveryFixture.asset("unlocated", atStep: 5)

        #expect(hike.photoSearchPlan.matches(assets: [located, unlocated]).isEmpty)
    }
}
