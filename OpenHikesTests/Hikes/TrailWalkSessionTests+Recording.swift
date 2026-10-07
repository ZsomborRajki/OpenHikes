//
//  TrailWalkSessionTests+Recording.swift
//  OpenHikesTests
//
//  A hiker walks a trail or records one, never both. While a recording is
//  under way nothing starts a walk; and the holds an End and a saved
//  recording each leave on auto-start are kept side by side rather than one
//  replacing the other.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

extension TrailWalkSessionTests {
    @Test("no walk starts, automatically or by hand, while a recording is under way")
    func noWalkBesideARecording() {
        let session = session(recordingHikeID: UUID())
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        #expect(session.isRecording)

        walk(session, hike: hike, profile: profile, from: 0, through: 6)
        #expect(session.walkedHikeID == nil, "moving along a trail while recording is the recording")
        #expect(session.startNotice == nil)

        #expect(!session.canStartByHand(hike))
        #expect(!session.start(hike: hike, profile: profile))
        #expect(session.walkedHikeID == nil)
        #expect(hike.walkInProgress == nil)
    }

    @Test("the walk under way is named for the recording that would end it")
    func walkUnderWayIsNamed() {
        let session = session()
        let hike = hike(title: "Ridge Loop")
        #expect(session.walkUnderWayTitle == nil)

        session.start(hike: hike, profile: RouteProfile(route: hike.route))
        #expect(session.walkUnderWayTitle == "Ridge Loop")

        session.end()
        #expect(session.walkUnderWayTitle == nil)
    }

    /// The order exclusivity allows: a walk ended, then a recording made and
    /// saved. The hiker has just finished both trails, and saving the second
    /// must not let a walk start on the first.
    @Test("an ended walk and a saved recording are both held")
    func endAndSaveAreBothHeld() {
        let session = session()
        let walked = hike(title: "Walked")
        let recorded = hike(title: "Recorded")
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 5)
        session.end()

        session.recordingDidSave(hikeID: recorded.id)

        #expect(session.hasEndedWalk(hikeID: walked.id), "the save did not replace the End")
        #expect(session.hasEndedWalk(hikeID: recorded.id))
        #expect(!session.canStart(walked))
        #expect(!session.canStart(recorded))

        // Each is released by its own boundary, and only that one.
        session.recordOffRoute(hikeID: walked.id)
        #expect(session.canStart(walked))
        #expect(!session.canStart(recorded))
    }

    @Test("starting a walk on a third trail keeps the other holds")
    func thirdTrailKeepsTheHolds() {
        let session = session()
        let ended = hike(title: "Ended")
        let saved = hike(title: "Saved")
        let third = hike(title: "Third")
        let profile = RouteProfile(route: ended.route)
        walk(session, hike: ended, profile: profile, from: 0, through: 5)
        session.end()
        session.recordingDidSave(hikeID: saved.id)

        #expect(session.start(hike: third, profile: profile))
        session.end()

        #expect(session.hasEndedWalk(hikeID: ended.id))
        #expect(session.hasEndedWalk(hikeID: saved.id))
        #expect(session.hasEndedWalk(hikeID: third.id))
    }
}
