//
//  TrailWalkSessionTests+EndQuestion.swift
//  OpenHikesTests
//
//  The question End asks, from the walked trail's bar or from the map's
//  capsule, read off a real walk: it asks only while there is a walk, a walk
//  it keeps goes out to open its summary, and the capsule's Pause and Resume
//  move the walk as the bar's do. See ``WalkEndQuestion``.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

extension TrailWalkSessionTests {
    @Test("End asks nothing when there is no walk to end")
    func endQuestionNeedsAWalk() {
        let question = WalkEndQuestion(session: session(), endings: EventFeed())

        question.ask()

        #expect(!question.isAsking)
    }

    @Test("a walk End keeps goes out with its trail and its record")
    func endQuestionSendsTheKeptWalk() async throws {
        let session = session()
        let endings = EventFeed<ActivityEnding>()
        let sent = FeedReader(endings.events())
        let question = WalkEndQuestion(session: session, endings: endings)
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 5)

        question.ask()
        #expect(question.isAsking)
        question.end()

        await settleDelegateHop(until: "the kept walk to be sent") { !sent.received.isEmpty }
        let kept = try #require(try walks(of: hike).first)
        #expect(sent.received == [.walkKept(hikeID: hike.id, walkID: kept.id)])
        #expect(session.walkedHikeID == nil)
        #expect(!question.isRefused)
    }

    /// Too short to keep is an end all the same, with nothing to open and
    /// nothing to apologise for.
    @Test("a walk too short to keep ends without a summary or a refusal")
    func endQuestionDropsAShortWalk() async {
        let session = session()
        let endings = EventFeed<ActivityEnding>()
        let sent = FeedReader(endings.events())
        let question = WalkEndQuestion(session: session, endings: endings)
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.start(hike: hike, profile: profile)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])

        question.end()
        // Nothing is sent for a dropped walk, so the reader is given the
        // turns it would have needed to drain one.
        await settleDelegateHop()

        #expect(session.walkedHikeID == nil)
        #expect(sent.received.isEmpty)
        #expect(!question.isRefused)
    }

    @Test("the capsule's Pause and Resume move the walk")
    func endQuestionTogglesThePhase() {
        let session = session()
        let question = WalkEndQuestion(session: session, endings: EventFeed())
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 3)

        question.togglePhase()
        #expect(session.phase == .paused)
        question.togglePhase()
        #expect(session.phase == .following)
        #expect(question.refusedPhase == nil)
    }
}
