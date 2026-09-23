//
//  TrailWalkSessionTests+ManualStart.swift
//  OpenHikesTests
//
//  The detail's Start: a walk begun by a tap rather than by a matched fix.
//
//  It is looser than the automatic start where a tap says what a fix cannot —
//  following off, an End just taken — and exactly as strict where nothing a
//  hiker says changes the answer: one walk at a time, and never on a
//  recording's own draft.
//

import Foundation
@testable import OpenHikes
import Testing

extension TrailWalkSessionTests {
    @Test("Start begins a walk with following off, before any fix, and announces nothing")
    func startByHandWithFollowingOff() {
        let session = session()
        let hike = hike { $0.autoFollowEnabled = false }
        let profile = RouteProfile(route: hike.route)
        #expect(!session.canStart(hike), "the automatic start is held back")

        #expect(session.start(hike: hike, profile: profile))

        #expect(session.walkedHikeID == hike.id)
        #expect(session.phase == .following)
        #expect(session.coveredFraction == 0, "nothing is covered until a fix matches")
        #expect(session.startNotice == nil, "the pill is for a start nobody asked for")
        #expect(hike.walkInProgress?.hikeID == hike.id, "and the sidecar has it from the tap")
    }

    @Test("a walk started by hand is extended by the fixes that follow")
    func startByHandAccruesFromTheNextMatch() {
        let session = session()
        let hike = hike { $0.autoFollowEnabled = false }
        let profile = RouteProfile(route: hike.route)
        session.start(hike: hike, profile: profile)

        walk(session, hike: hike, profile: profile, from: 0, through: 3)

        #expect(session.coveredFraction > 0)
        #expect(session.activeSeconds() == 4 * 60)
    }

    @Test("Start works straight after an End, where the automatic start waits for the hiker to leave")
    func startByHandAfterAnEnd() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 1)
        session.end()
        #expect(!session.canStart(hike))

        #expect(session.canStartByHand(hike))
        #expect(session.start(hike: hike, profile: profile))
        #expect(session.walkedHikeID == hike.id)
    }

    @Test("Start is refused while another walk is under way, and on a recording's draft")
    func startByHandRefusals() {
        let session = session()
        let walked = hike(title: "Walked")
        let other = hike(title: "Other")
        let profile = RouteProfile(route: walked.route)
        session.start(hike: walked, profile: profile)

        #expect(!session.start(hike: other, profile: profile))
        #expect(!session.start(hike: walked, profile: profile), "a second tap does not restart the walk")
        #expect(session.walkedHikeID == walked.id)
        #expect(other.walkInProgress == nil)

        let draft = hike(title: "Draft") { $0.isRecording = true }
        let fresh = self.session()
        #expect(!fresh.canStartByHand(draft))
        #expect(!fresh.start(hike: draft, profile: profile))
        #expect(fresh.walkedHikeID == nil)
    }
}
