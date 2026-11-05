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
        hike.replaceRoute(with: Self.straightRoute(through: 20))
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
        hike.replaceRoute(with: Self.straightRoute(through: 20))
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
        hike.replaceRoute(with: moved)
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

        let raised = hike.route.map { point in
            var filled = point
            filled.elevation = (point.elevation ?? 0) + 12
            return filled
        }
        hike.replaceRoute(with: raised)
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

        hike.replaceRoute(with: Array(hike.route.dropLast()))
        session.endIfRouteChanged()

        #expect(session.walkedHikeID == nil)
        #expect(try walks(of: hike).first?.endReason == .routeChanged)
    }

    /// An edit mirrored from the hiker's other device while this one was not
    /// running is already in the store when the walk is found open.
    @Test("a walk found open along an edited route is ended at launch")
    func editedRouteEndsTheWalkAtLaunch() async throws {
        let hike = hike()
        walk(session(), hike: hike, profile: RouteProfile(route: hike.route), from: 0, through: 5)
        #expect(hike.walkInProgress != nil)
        hike.replaceRoute(with: Array(hike.route.dropLast()))
        try context.save()

        let relaunched = session()
        relaunched.restoreAtLaunch()
        await relaunched.lineCheck?.value

        #expect(relaunched.walkedHikeID == nil)
        #expect(hike.walkInProgress == nil, "the column is cleared with the row")
        #expect(try walks(of: hike).first?.endReason == .routeChanged)
    }

    /// The hike's screen hands each match the line it read off the main
    /// actor, as a walk names it, so nothing reads the hike's own line on the
    /// main actor for it (#1252). Handed one, the session answers from it,
    /// not from the hike: here the hike's line has moved and the screen's has
    /// not yet, so the walk goes on until the screen hands the new one.
    @Test("a match handed the screen's line checks the walk against that line, not the hike's")
    func aMatchWithTheScreensLineReadsNothingOfTheHikes() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        let shown = TrailWalkRecord.routeRevision(of: hike.route)
        startWalk(session, hike: hike, profile: profile)
        var moved = hike.route
        moved[3].longitude += 0.0005
        hike.replaceRoute(with: moved)

        clock.advance(by: 60)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[4], revision: shown)
        #expect(session.walkedHikeID == hike.id, "the line the screen holds is still the walk's")

        session.endIfRouteChanged(knowing: (hike.id, TrailWalkRecord.routeRevision(of: moved)))
        #expect(session.walkedHikeID == nil, "and the screen's new line ends it")
        #expect(try walks(of: hike).first?.endReason == .routeChanged)
    }

    /// The background feed reads the line to match the fix, off the main
    /// actor, and hands it on the way the screen hands its own. Handed one,
    /// the session answers from it, not from the hike.
    @Test("a background match checks the walk against the line the feed read")
    func aBackgroundMatchChecksTheFeedsLine() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        let matched = TrailWalkRecord.routeRevision(of: hike.route)
        startWalk(session, hike: hike, profile: profile)
        var moved = hike.route
        moved[3].longitude += 0.0005
        hike.replaceRoute(with: moved)

        clock.advance(by: 60)
        session.recordBackgroundMatch(hikeID: hike.id, distance: profile.distances[4], at: clock.now, revision: matched)
        #expect(session.walkedHikeID == hike.id, "the line the feed read is still the walk's")

        clock.advance(by: 60)
        session.recordBackgroundMatch(
            hikeID: hike.id,
            distance: profile.distances[5],
            at: clock.now,
            revision: TrailWalkRecord.routeRevision(of: moved)
        )
        #expect(session.walkedHikeID == nil, "and the feed's next read of the new line ends it")
        #expect(try walks(of: hike).first?.endReason == .routeChanged)
    }

    /// A proposal the background feed confirms is checked against the line
    /// the feed read, as a walk under way is, and starts along it.
    @Test("a background match confirms a proposed walk only along the line the feed read", arguments: [true, false])
    func aBackgroundMatchConfirmsAlongTheFeedsLine(sameLine: Bool) {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        let revision = TrailWalkRecord.routeRevision(of: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0], revision: revision)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[1], revision: revision)

        session.recordBackgroundMatch(
            hikeID: hike.id,
            distance: profile.distances[2],
            at: clock.now,
            revision: sameLine ? revision : "another line"
        )

        #expect((session.walkedHikeID == hike.id) == sameLine)
    }

    /// The moments with no line in hand: a return to the foreground, a
    /// launch, a fix matched on another hike's screen. Each reads the walked
    /// line off the main actor, and the walk ends once that lands.
    @Test("a look at the walked line ends a walk along a line that has changed")
    func aLookEndsAWalkAlongAnEditedLine() async throws {
        let session = session()
        let hike = hike()
        walk(session, hike: hike, profile: RouteProfile(route: hike.route), from: 0, through: 5)
        try context.save()
        hike.replaceRoute(with: Array(hike.route.dropLast()))
        try context.save()

        session.checkWalkedLine()
        #expect(session.walkedHikeID == hike.id, "nothing is read on the spot")
        await session.lineCheck?.value

        #expect(session.walkedHikeID == nil)
        #expect(try walks(of: hike).first?.endReason == .routeChanged)
    }

    @Test("a look at a line that has not changed ends nothing")
    func aLookAtTheSameLineEndsNothing() async throws {
        let session = session()
        let hike = hike()
        walk(session, hike: hike, profile: RouteProfile(route: hike.route), from: 0, through: 5)
        try context.save()

        session.checkWalkedLine()
        await session.lineCheck?.value

        #expect(session.walkedHikeID == hike.id)
        #expect(session.lastEndedWalk == nil)
    }

    /// The store's line is what is read, so one saved by another context,
    /// which is what an edit mirrored in from another device comes to, is
    /// found though the hike's own copy has not been told of it.
    @Test("a look finds a line saved elsewhere that the hike's own copy has not heard of")
    func aLookFindsALineSavedElsewhere() async throws {
        let session = session()
        let hike = hike()
        walk(session, hike: hike, profile: RouteProfile(route: hike.route), from: 0, through: 5)
        try context.save()
        let original = hike.route

        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: context.container) { stored in
            stored.replaceRoute(with: Array(stored.route.dropLast()))
        }
        try #require(hike.route == original, "the premise: this context was not told")
        session.checkWalkedLine()
        await session.lineCheck?.value

        #expect(session.walkedHikeID == nil)
    }

    /// A fix matched on another hike's screen comes with that hike's line,
    /// which says nothing about the walked one, so it is looked at instead
    /// of being read on the main actor.
    @Test("a match on another hike's screen looks at the walked line, and reads none of it on the spot")
    func aMatchOnAnotherHikesScreenLooksAtTheWalkedLine() async throws {
        let session = session()
        let walked = hike()
        let shown = hike(title: "Shown")
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 5)
        try context.save()
        walked.replaceRoute(with: Array(walked.route.dropLast()))
        try context.save()

        session.recordForegroundMatch(hike: shown, profile: profile, distance: profile.distances[1], revision: "shown")
        #expect(session.walkedHikeID == walked.id, "nothing is read on the spot")
        await session.lineCheck?.value

        #expect(session.walkedHikeID == nil)
        #expect(try walks(of: walked).first?.endReason == .routeChanged)
    }

    /// A fix on another hike's screen can come every second, and each look
    /// reads the whole walked line in a context of its own and leaves a watch
    /// on it that only its next write releases. So the line that look read
    /// stands until the interval has passed, or a write has replaced it.
    @Test("fixes on another hike's screen share one look at the walked line until it is due or edited")
    func fixesOnAnotherHikesScreenShareALook() async throws {
        let session = session()
        let reads = WidgetFeedSuites.SelectedLineImportTests.FetchCount()
        session.lineLooks.fetch = reads.fetch
        let walked = hike()
        let shown = hike(title: "Shown")
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 5)
        try context.save()
        let matchOnShown: () -> Void = {
            session.recordForegroundMatch(
                hike: shown,
                profile: profile,
                distance: profile.distances[1],
                revision: "shown"
            )
        }

        for _ in 0..<5 {
            matchOnShown()
            await session.lineCheck?.value
        }
        #expect(reads.count == 1, "one read of the line, and so one watch on it, for five fixes")

        clock.advance(by: TrailWalkSession.walkedLineLookInterval)
        matchOnShown()
        await session.lineCheck?.value
        #expect(reads.count == 2, "looked at again once the interval has passed")
        #expect(session.walkedHikeID == walked.id)

        walked.replaceRoute(with: Array(walked.route.dropLast()))
        try context.save()
        matchOnShown()
        await session.lineCheck?.value
        #expect(session.walkedHikeID == nil, "an edit through the hike's context is looked at by the next fix")
        #expect(try walks(of: walked).first?.endReason == .routeChanged)
    }

    /// Everything here runs on the main actor, so the look cannot land until
    /// the test awaits it: by then the walk it was about has gone, and the
    /// line it read is not the one the next walk is along.
    @Test("a look that lands after its walk has ended says nothing about the next")
    func aLateLookLeavesTheNextWalkAlone() async throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 5)
        try context.save()

        session.checkWalkedLine()
        let look = session.lineCheck
        session.end()
        clock.advance(by: 60)
        #expect(session.start(hike: hike, profile: profile, revision: "the next walk's line"))
        await look?.value

        #expect(session.walkedHikeID == hike.id, "the next walk goes on")
    }

    /// A write while the read is out is a line that read does not hold, and
    /// a walk that stood still would hear of it from nothing else.
    @Test("a write that overtakes a look has the line looked at again")
    func aWriteOvertakingALookLooksAgain() async throws {
        let session = session()
        let hike = hike()
        walk(session, hike: hike, profile: RouteProfile(route: hike.route), from: 0, through: 5)
        try context.save()

        session.checkWalkedLine()
        hike.replaceRoute(with: Array(hike.route.dropLast()))
        try context.save()

        await settleDelegateHop(until: "the second look has ended the walk") { session.walkedHikeID == nil }
        #expect(try walks(of: hike).first?.endReason == .routeChanged)
    }

    /// The same for the two ways a walk begins: the line it is named for is
    /// the one the screen handed in.
    @Test("a walk begun from the screen is named for the screen's line")
    func aWalkBegunFromTheScreenIsAlongItsLine() {
        let tapped = hike()
        let profile = RouteProfile(route: tapped.route)
        let shown = "the screen's line"

        let started = session()
        #expect(started.start(hike: tapped, profile: profile, revision: shown))
        #expect(started.record?.routeRevision == shown, "Start")

        let matched = hike(title: "Other")
        let proposed = session()
        for distance in profile.distances.prefix(3) {
            proposed.recordForegroundMatch(hike: matched, profile: profile, distance: distance, revision: shown)
        }
        #expect(proposed.record?.routeRevision == shown, "a start the matches confirmed")
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

        hike.replaceRoute(with: Array(hike.route.dropLast()))
        relaunched.endIfRouteChanged()
        #expect(relaunched.walkedHikeID == nil, "the stamped revision catches the next edit")
    }
}
