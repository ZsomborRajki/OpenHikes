//
//  TrailWalkSessionTests+AutoStart.swift
//  OpenHikesTests
//
//  The automatic start as the session holds it: a matched fix proposes a
//  walk and moving along the route starts it — see `PendingWalkStart`. What
//  a proposal must not do is show: no walk, no pill, nothing written, and
//  nothing standing in another trail's way.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

extension TrailWalkSessionTests {
    /// The trail that passes the front door. Opening it at home used to
    /// start a walk there and then — controls, pill, Lock Screen panel — and
    /// one that held every other trail's start back until it was abandoned.
    @Test("an hour of fixes on one spot of the route starts nothing")
    func standingOnTheRouteStartsNothing() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)

        for _ in 0..<60 {
            clock.advance(by: 60)
            session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[4])
        }

        #expect(session.walkedHikeID == nil)
        #expect(session.startNotice == nil)
        #expect(hike.walkInProgress == nil, "a proposal writes nothing")
        #expect(session.canStart(hike), "and holds nothing back")
    }

    @Test("a walk started after standing about is dated from when the hiker set off")
    func walkIsDatedFromSettingOff() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])
        clock.advance(by: 20 * 60)
        let setOff = clock.now
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])

        walk(session, hike: hike, profile: profile, from: 1, through: 2)

        #expect(session.walkedHikeID == hike.id)
        #expect(try #require(session.record).startedAt == setOff)
        #expect(session.activeSeconds() == 2 * 60, "the twenty minutes before are not walking")
        #expect(session.coveredFraction > 0, "the stretch that confirmed it is covered")
    }

    @Test("leaving the route forgets a proposed walk")
    func offRouteForgetsTheProposal() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 1)

        session.recordOffRoute(hikeID: hike.id)
        walk(session, hike: hike, profile: profile, from: 2, through: 2)
        #expect(session.walkedHikeID == nil, "the fix back on the route proposes afresh")

        walk(session, hike: hike, profile: profile, from: 3, through: 4)
        #expect(session.walkedHikeID == hike.id)
    }

    @Test("a proposal gone quiet is replaced rather than confirmed")
    func quietProposalExpires() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 1)

        clock.advance(by: PendingWalkStart.expiresAfter + 60)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[2])

        #expect(session.walkedHikeID == nil, "112 m from a spot left half an hour ago is a fresh start")
    }

    /// The trailhead and the pocket: the trail is opened, one fix proposes,
    /// the phone goes away, and the significant-change feed is the one that
    /// sees the hiker walk off.
    @Test("a background match confirms a walk the foreground proposed")
    func backgroundConfirmsAProposal() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        let proposedAt = clock.now
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])

        clock.advance(by: 5 * 60)
        session.recordBackgroundMatch(hikeID: hike.id, distance: profile.distances[4], at: clock.now)

        #expect(session.walkedHikeID == hike.id)
        #expect(session.record?.startedAt == proposedAt)
        #expect(session.startNotice?.hikeID == hike.id, "said when the app is next opened")
        #expect(hike.walkInProgress?.hikeID == hike.id)
    }

    @Test("the background feed alone never proposes a walk")
    func backgroundAloneStartsNothing() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)

        for index in 0...6 {
            clock.advance(by: 60)
            session.recordBackgroundMatch(hikeID: hike.id, distance: profile.distances[index], at: clock.now)
        }

        #expect(session.walkedHikeID == nil)
    }

    /// Asked again at the confirmation, because the background feed confirms
    /// with no hike in hand and following can be switched off in between.
    @Test("a proposal confirmed after following was switched off starts nothing")
    func confirmationAsksAgain() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])

        hike.autoFollowEnabled = false
        clock.advance(by: 5 * 60)
        session.recordBackgroundMatch(hikeID: hike.id, distance: profile.distances[4], at: clock.now)

        #expect(session.walkedHikeID == nil)
    }
}
