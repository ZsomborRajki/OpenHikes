//
//  TrailWalkSessionTests+StartNotice.swift
//  OpenHikesTests
//
//  The news that a walk has started, for the pill on the map.
//
//  A walk begins without a tap, so something has to say it did. These pin
//  when that is said and when it stops being said: on a start and not on
//  every fix after it, not for a walk a relaunch adopts, and not a moment
//  past the walk it was about.
//

import Foundation
@testable import OpenHikes
import Testing

extension TrailWalkSessionTests {
    @Test("the first matched fix starts a walk and says so, naming the trail")
    func startIsAnnounced() {
        let session = session()
        let hike = hike(title: "Königssee Loop")
        let profile = RouteProfile(route: hike.route)
        #expect(session.startNotice == nil)

        walk(session, hike: hike, profile: profile, from: 0, through: 0)

        #expect(session.startNotice == TrailWalkStartNotice(hikeID: hike.id, title: "Königssee Loop"))
    }

    @Test("dismissing the notice leaves the walk under way and the next fix does not bring it back")
    func dismissKeepsTheWalk() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 1)

        session.dismissStartNotice()
        walk(session, hike: hike, profile: profile, from: 2, through: 3)

        #expect(session.startNotice == nil)
        #expect(session.walkedHikeID == hike.id)
        #expect(session.phase == .following)
    }

    /// A pill still up after End would announce a walk that is over — and
    /// the next start has to be able to say so again.
    @Test("ending the walk takes the notice down, and the next walk puts it back")
    func endClearsTheNotice() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 5)

        session.end()
        #expect(session.startNotice == nil)

        session.recordOffRoute(hikeID: hike.id)
        walk(session, hike: hike, profile: profile, from: 6, through: 6)
        #expect(session.startNotice?.hikeID == hike.id)
    }

    /// The walk was announced by the launch that started it. A relaunch that
    /// finds it open is not news.
    @Test("a walk adopted at launch is not announced again")
    func adoptedWalkIsNotAnnounced() {
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session(), hike: hike, profile: profile, from: 0, through: 3)

        clock.advance(by: 60)
        let relaunched = session()
        relaunched.restoreAtLaunch()

        #expect(relaunched.walkedHikeID == hike.id)
        #expect(relaunched.startNotice == nil)
    }
}
