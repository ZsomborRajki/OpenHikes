//
//  TrailWalkSessionTests+RouteEdit.swift
//  OpenHikesTests
//
//  What happens to a walk when its hike's route is edited under it — issue
//  #722.
//
//  A walk's coverage is intervals along the line it started on, and its
//  completion rule measures new matches against that line's length. Feeding
//  it matches measured along an edited line mixes two routes: extend a trail
//  to twice its length mid-walk and the walk "completes" at the old end,
//  halfway along the new one. So a walk is bound to its line, and a route
//  that is no longer that line ends it — on the next fix from either feed,
//  at launch for an edit mirrored while the app was not running, and on the
//  maker's own save. Split from `TrailWalkSessionTests` like `+Deletion`,
//  because it asks the same kind of question about a different edit.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension TrailWalkSessionTests {
    /// A straight line north, a hundred-odd metres a point: long enough that
    /// the edited version's midpoint is nowhere near either of its ends.
    private enum StraightLine {
        static let latitude = 47.0
        static let longitude = 12.0
        static let step = 0.001
    }

    private static func straightRoute(through last: Int) -> [RouteCoordinate] {
        (0...last).map { index in
            RouteCoordinate(
                latitude: StraightLine.latitude + Double(index) * StraightLine.step,
                longitude: StraightLine.longitude
            )
        }
    }

    /// The issue's reproduction: walk half a trail, extend it to twice its
    /// length, and keep walking to where the old end was.
    @Test("an extended route does not complete the walk at the old end")
    func extendedRouteDoesNotCompleteAtTheOldEnd() throws {
        let session = session()
        let hike = Fixture.hike(in: context, route: Self.straightRoute(through: 10))
        walk(session, hike: hike, profile: RouteProfile(route: hike.route), from: 0, through: 4)
        #expect(session.phase == .following)

        // What `TrailDraftSave.update` and a mirrored edit both come to: the
        // same hike, a new line.
        hike.route = Self.straightRoute(through: 20)
        let extended = RouteProfile(route: hike.route)
        hike.distanceMeters = extended.totalDistanceMeters
        try context.save()
        walk(session, hike: hike, profile: extended, from: 5, through: 10)

        let ended = try #require(session.lastEndedWalk)
        #expect(ended.endReason == .routeChanged, "the edit ended the walk, not the old end")
        #expect(ended.coveredFraction < TrailWalkPolicy.reachedEndFraction)
        #expect(try walks(of: hike).count == 1, "the walk along the old line is kept")
        #expect(hike.walkInProgress == nil)
        #expect(session.walkedHikeID == nil, "and no walk carries on mixing the two lines")
        #expect(session.hasEndedWalk(hikeID: hike.id), "the next one waits for what an End waits for")
    }

    /// The hiker still on the trail who wants the new line walked taps Start,
    /// and that walk is measured along the new line from the beginning.
    @Test("Start after an edit walks the new line")
    func startAfterAnEditWalksTheNewLine() throws {
        let session = session()
        let hike = Fixture.hike(in: context, route: Self.straightRoute(through: 10))
        walk(session, hike: hike, profile: RouteProfile(route: hike.route), from: 0, through: 4)
        hike.route = Self.straightRoute(through: 20)
        let extended = RouteProfile(route: hike.route)

        #expect(session.start(hike: hike, profile: extended), "Start ends the old walk and begins the new one")
        walk(session, hike: hike, profile: extended, from: 5, through: 10)

        #expect(session.phase == .following, "halfway along the new line is halfway")
        let record = try #require(session.record)
        #expect(record.routeDistanceMeters == extended.totalDistanceMeters)
        #expect(record.isAlong(hike.route))
        #expect(try walks(of: hike).first?.endReason == .routeChanged)
    }

    /// Moving a stop can leave the length exactly where it was and still move
    /// every metre after it, so the length is not what is compared.
    @Test("a moved point ends the walk even at the same length")
    func movedPointEndsTheWalk() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 5)

        var moved = hike.route
        moved[3].longitude += 0.0005
        hike.route = moved
        let distance = hike.distanceMeters
        session.recordBackgroundMatch(hikeID: hike.id, distance: profile.distances[6], at: clock.now)

        #expect(hike.distanceMeters == distance, "nothing but the line changed")
        #expect(session.walkedHikeID == nil, "the background feed notices as well")
        #expect(try walks(of: hike).first?.endReason == .routeChanged)
    }

    /// A height filled in, or any other change that leaves every position
    /// where it was, moves no distance along the route and ends nothing.
    @Test("a change that leaves the line where it was keeps the walk")
    func unchangedLineKeepsTheWalk() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 5)

        hike.route = hike.route.map { point in
            var filled = point
            filled.elevation = (point.elevation ?? 0) + 12
            return filled
        }
        hike.title = "Renamed"
        session.endIfRouteChanged()
        walk(session, hike: hike, profile: profile, from: 6, through: 7)

        #expect(session.phase == .following)
        #expect(session.lastEndedWalk == nil)
    }

    /// A paused walk has no fix to notice the edit by if the hiker is not
    /// moving; the maker's save and the return to the foreground ask anyway.
    @Test("a paused walk is ended by the explicit check")
    func pausedWalkEndsOnTheExplicitCheck() throws {
        let session = session()
        let hike = hike()
        walk(session, hike: hike, profile: RouteProfile(route: hike.route), from: 0, through: 5)
        #expect(session.pause())

        hike.route = Array(hike.route.dropLast())
        session.endIfRouteChanged()

        #expect(session.walkedHikeID == nil)
        #expect(try walks(of: hike).first?.endReason == .routeChanged)
    }

    /// An edit mirrored from the hiker's other device while this one was not
    /// running is already in the store when the walk is found open.
    @Test("a walk found open along an edited route is ended at launch")
    func editedRouteEndsTheWalkAtLaunch() throws {
        let hike = hike()
        walk(session(), hike: hike, profile: RouteProfile(route: hike.route), from: 0, through: 5)
        #expect(hike.walkInProgress != nil)
        hike.route = Array(hike.route.dropLast())
        try context.save()

        let relaunched = session()
        relaunched.restoreAtLaunch()

        #expect(relaunched.walkedHikeID == nil)
        #expect(hike.walkInProgress == nil, "the column is cleared with the row")
        #expect(try walks(of: hike).first?.endReason == .routeChanged)
    }

    /// A record written before revisions were kept has nothing to compare, so
    /// it is taken to be along the line it is found with — and an edit after
    /// that is noticed like any other.
    @Test("a walk from before revisions is adopted along the route it finds")
    func legacyWalkIsStampedAtLaunch() throws {
        let hike = hike()
        walk(session(), hike: hike, profile: RouteProfile(route: hike.route), from: 0, through: 5)
        var legacy = try #require(hike.walkInProgress)
        legacy.routeRevision = nil
        hike.walkInProgress = legacy
        try context.save()

        let relaunched = session()
        relaunched.restoreAtLaunch()
        #expect(relaunched.walkedHikeID == hike.id, "nothing to tell an edit from")
        #expect(relaunched.record?.isAlong(hike.route) == true)

        hike.route = Array(hike.route.dropLast())
        relaunched.endIfRouteChanged()
        #expect(relaunched.walkedHikeID == nil, "the stamped revision catches the next edit")
    }
}
