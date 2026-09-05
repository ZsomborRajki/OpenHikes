//
//  TrailWalkSessionTests.swift
//  OpenHikesTests
//
//  The walk's lifecycle: when one starts, what pauses it, what ends it, and
//  what it leaves behind. Driven with a clock the test moves by hand, against
//  the in-memory store, with no tracker — the Lock Screen and widget halves
//  are `TrailFollowActivityTests`' subject.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Trail walk session")
struct TrailWalkSessionTests {
    private let container: ModelContainer
    let context: ModelContext
    let clock = TestClock()
    private var recordingHikeID: UUID?

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
    }

    func session(recordingHikeID: UUID? = nil) -> TrailWalkSession {
        TrailWalkSession(context: context, clock: clock.read) { recordingHikeID }
    }

    func hike(title: String = "Ridge Loop", configure: (Hike) -> Void = { _ in /* no-op */ }) -> Hike {
        Fixture.hike(in: context, title: title, route: Fixture.outAndBackRoute, configure: configure)
    }

    /// Feeds the session one match per route point from `start` to `end`,
    /// a minute apart — a walker, not a teleport.
    func walk(
        _ session: TrailWalkSession,
        hike: Hike,
        profile: RouteProfile,
        from start: Int,
        through end: Int
    ) {
        for index in start...end {
            clock.advance(by: 60)
            session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[index])
        }
    }

    func walks(of hike: Hike) throws -> [HikeWalk] {
        let id = hike.id
        return try context.fetch(FetchDescriptor<HikeWalk>(predicate: #Predicate { $0.hikeID == id }))
    }

    // MARK: Start

    /// Selection alone starts nothing; the first matched fix does.
    @Test("a walk starts on the first matched fix with following on")
    func startsOnTheFirstMatch() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        #expect(session.walkedHikeID == nil, "nothing has matched yet")

        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])

        #expect(session.walkedHikeID == hike.id)
        #expect(session.phase == .following)
        #expect(session.walkedHikeTitle == hike.displayTitle)
        #expect(hike.walkInProgress?.hikeID == hike.id, "and the sidecar has it from the start")
    }

    @Test("following off means no walk starts")
    func followingOffStartsNothing() {
        let session = session()
        let hike = hike { $0.autoFollowEnabled = false }
        let profile = RouteProfile(route: hike.route)

        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])

        #expect(session.walkedHikeID == nil)
        #expect(hike.walkInProgress == nil)
    }

    /// A recording's own draft never gets a walk — by the persisted flag, and
    /// by the recorder's bridge across the save window.
    @Test("a recording's draft cannot host a walk, a saved recording can")
    func recordingDraftCannotHostAWalk() {
        let draft = hike(title: "Draft") { $0.isRecording = true }
        let profile = RouteProfile(route: draft.route)
        let session = session()
        session.recordForegroundMatch(hike: draft, profile: profile, distance: profile.distances[0])
        #expect(session.walkedHikeID == nil)

        let bridged = hike(title: "Just saved")
        let bridgedSession = self.session(recordingHikeID: bridged.id)
        bridgedSession.recordForegroundMatch(hike: bridged, profile: profile, distance: profile.distances[0])
        #expect(bridgedSession.walkedHikeID == nil, "the recorder still owns it")

        // Once released, it is a trail like any other.
        let saved = hike(title: "Saved recording")
        let savedSession = self.session()
        savedSession.recordForegroundMatch(hike: saved, profile: profile, distance: profile.distances[0])
        #expect(savedSession.walkedHikeID == saved.id)
    }

    @Test("a second trail cannot start a walk while one is under way")
    func oneWalkAtATime() {
        let session = session()
        let first = hike(title: "First")
        let second = hike(title: "Second")
        let profile = RouteProfile(route: first.route)
        session.recordForegroundMatch(hike: first, profile: profile, distance: profile.distances[0])

        session.recordForegroundMatch(hike: second, profile: profile, distance: profile.distances[0])

        #expect(session.walkedHikeID == first.id)
        #expect(!session.canStart(second))
        #expect(second.walkInProgress == nil)
    }

    // MARK: Phases

    @Test("following, paused, following, ended — and the clock skips the pause")
    func phasesAndTheClock() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 4)
        #expect(session.phase == .following)
        let beforePause = session.activeSeconds()

        session.pause()
        #expect(session.phase == .paused)
        #expect(hike.walkInProgress?.phase == .paused, "a milestone is written at once")
        clock.advance(by: 1800)
        #expect(session.activeSeconds() == beforePause, "a paused clock does not move")
        // Fixes still arrive while paused and neither extend the union…
        let covered = session.coveredFraction
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[10])
        #expect(session.coveredFraction == covered)
        // …nor publish.
        #expect(!session.publishes(hikeID: hike.id))

        session.resume()
        #expect(session.phase == .following)
        #expect(session.publishes(hikeID: hike.id))
        walk(session, hike: hike, profile: profile, from: 5, through: 8)
        #expect(session.activeSeconds() > beforePause)
        #expect(abs(session.activeSeconds() - (beforePause + 4 * 60)) < 1)

        let ended = try #require(session.end().walk)
        #expect(ended.endReason == .ended)
        #expect(abs(ended.activeSeconds - (beforePause + 4 * 60)) < 1)
        #expect(session.walkedHikeID == nil)
        #expect(session.phase == nil)
        #expect(hike.walkInProgress == nil, "the column is cleared in the same save")
        #expect(try walks(of: hike).count == 1)
        #expect(session.lastEndedWalk?.id == ended.id)
    }

    @Test("End on a paused walk keeps the record")
    func endWhilePaused() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 5)
        session.pause()

        let ended = try #require(session.end().walk)

        #expect(ended.coveredFraction > 0)
        #expect(ended.endReason == .ended)
        #expect(try walks(of: hike).count == 1)
    }

    /// Turning Auto-Follow Trail off for the walked hike is the one
    /// non-button gesture that pauses. For any other hike it is nothing.
    @Test("turning following off pauses the walked hike's walk")
    func followingOffPauses() {
        let session = session()
        let hike = hike()
        let other = self.hike(title: "Other")
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 3)

        #expect(!session.autoFollowDidChange(hikeID: other.id, enabled: false))
        #expect(session.phase == .following)

        #expect(session.autoFollowDidChange(hikeID: hike.id, enabled: false))
        #expect(session.phase == .paused)

        // Resuming turns following back on: a resumed walk with following
        // off would accrue nothing, silently.
        hike.autoFollowEnabled = false
        session.resume()
        #expect(hike.autoFollowEnabled)
    }

    // MARK: Ends the walker did not tap

    @Test("reaching the end closes the walk as completed and pushes it")
    func reachedEnd() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: profile.coordinates.count - 2)
        #expect(session.walkedHikeID == hike.id, "one step short of the end is still walking")

        let last = profile.coordinates.count - 1
        walk(session, hike: hike, profile: profile, from: last, through: last)

        #expect(session.walkedHikeID == nil)
        let ended = try #require(session.lastEndedWalk)
        #expect(ended.endReason == .reachedEnd)
        #expect(ended.coveredFraction > 0.99)
        #expect(try walks(of: hike).count == 1)
    }

    /// A pause says the walk continues, and a paused walker produces nothing
    /// that could advance the clock abandonment is measured from: they are not
    /// moving, so no significant change wakes the background feed either.
    /// Measured against the six-hour rule, a hut evening closes the walk with
    /// the walker looking at it.
    @Test("a pause outlasts the abandonment bound")
    func pauseOutlastsTheAbandonmentBound() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 5)
        session.pause()

        clock.advance(by: TrailWalkPolicy.abandonAfter + 3600)
        session.endIfAbandoned()

        #expect(session.walkedHikeID == hike.id)
        #expect(session.phase == .paused)
        session.resume()
        #expect(session.phase == .following, "and it is still the walk that resumes")
    }

    /// The gap bound bridges a lost signal, on the reasoning that the walker
    /// probably did walk the stretch in between. A pause is the opposite
    /// statement, and the one case where the bridge is known to be wrong.
    @Test("the stretch walked while paused is not counted on resume")
    func resumeDoesNotBridgeThePause() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 3)
        let covered = try #require(session.record).coverage.coveredMeters
        session.pause()

        // 400 m of ridge, walked with the walk explicitly paused — inside the
        // gap bound, so it is a stretch that would have been bridged.
        let resumedAt = profile.distances[3] + 400
        #expect(resumedAt - profile.distances[3] <= TrailWalkPolicy.gapBoundMeters, "precondition: bridgeable")
        session.resume()
        clock.advance(by: 60)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: resumedAt)

        #expect(try #require(session.record).coverage.coveredMeters == covered)
        #expect(
            try #require(session.record).coverage.furthestDistanceMeters == resumedAt,
            "the walker did get there, they just did not walk it as part of this walk"
        )
    }

    @Test("six hours without a match closes the walk as abandoned, and keeps it")
    func abandonedAfterSixHours() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 6)

        clock.advance(by: TrailWalkPolicy.abandonAfter - 60)
        session.endIfAbandoned()
        #expect(session.walkedHikeID == hike.id, "not yet")
        // What the walk came to while it was still a walk, read before the
        // hours that end it are on the clock.
        let lastKnown = try #require(session.record).lastActivityAt
        let walked = try #require(session.record).activeSeconds(at: lastKnown)

        clock.advance(by: 120)
        session.endIfAbandoned()
        #expect(session.walkedHikeID == nil)
        let kept = try #require(try walks(of: hike).first)
        #expect(kept.endReason == .abandoned)
        // The six idle hours are not walking. The row closes where the walk
        // did — at its last match — rather than where the sweep noticed.
        #expect(kept.endedAt == lastKnown)
        #expect(kept.activeSeconds == walked)
        #expect(kept.activeSeconds < TrailWalkPolicy.abandonAfter, "the bound is not the walk")
        #expect(session.lastEndedWalk == nil, "nothing to push and nothing to linger")
    }

    /// A paused walk that is still being matched — a lunch stop with the app
    /// open — is not abandoned, however long the lunch.
    @Test("a paused walk still being matched is not abandoned")
    func pausedButSeenIsNotAbandoned() {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 3)
        session.pause()

        for _ in 0..<8 {
            clock.advance(by: 3600)
            session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[3])
        }
        session.endIfAbandoned()

        #expect(session.walkedHikeID == hike.id)
        #expect(session.phase == .paused)
    }

    @Test("a walk under the minimum is cleared rather than kept")
    func underTheMinimumIsDropped() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0] + 30)

        #expect(session.end().walk == nil)

        #expect(session.walkedHikeID == nil)
        #expect(hike.walkInProgress == nil)
        #expect(try walks(of: hike).isEmpty)
        #expect(session.lastEndedWalk == nil)
    }

    // MARK: Persistence cadence

    /// The sidecar is written at milestones and at the feed's cadence, never
    /// per fix — a `@Query` over the sidecar must not tick at fix rate.
    @Test("coverage reaches the sidecar at the publish cadence, not per fix")
    func persistsAtTheCadence() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[0])
        let written = try #require(hike.walkInProgress)

        clock.advance(by: 10)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[1])
        clock.advance(by: 10)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[2])
        #expect(hike.walkInProgress == written, "two fixes inside the window wrote nothing")

        clock.advance(by: TrailWalkPolicy.persistInterval)
        session.recordForegroundMatch(hike: hike, profile: profile, distance: profile.distances[3])
        let later = try #require(hike.walkInProgress)
        #expect(later.coverage.coveredMeters > written.coverage.coveredMeters)
    }

    // MARK: Deletion

    @Test("deleting the walked hike forgets the walk without a row")
    func deletedHikeDiscardsTheWalk() throws {
        let session = session()
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        walk(session, hike: hike, profile: profile, from: 0, through: 5)

        session.discardWalk(forDeletedHike: hike.id)

        #expect(session.walkedHikeID == nil)
        #expect(try walks(of: hike).isEmpty)
    }

    // MARK: Launch

    @Test("a walk left open by the last launch is adopted")
    func restoresAnOpenWalk() throws {
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        let first = session()
        walk(first, hike: hike, profile: profile, from: 0, through: 5)
        first.pause()
        let openRecord = try #require(hike.walkInProgress)

        clock.advance(by: 3600)
        let relaunched = session()
        relaunched.restoreAtLaunch()

        #expect(relaunched.walkedHikeID == hike.id)
        #expect(relaunched.phase == .paused)
        #expect(relaunched.coveredFraction == openRecord.coveredFraction)
        #expect(relaunched.record == openRecord)
    }

    @Test("a walk open for more than a day is closed as abandoned at launch")
    func staleWalkIsClosedAtLaunch() throws {
        let hike = hike()
        let profile = RouteProfile(route: hike.route)
        let first = session()
        walk(first, hike: hike, profile: profile, from: 0, through: 5)
        let lastKnown = try #require(first.record).lastActivityAt
        let walked = try #require(first.record).activeSeconds(at: lastKnown)

        clock.advance(by: TrailWalkPolicy.staleAtLaunchAfter + 60)
        let relaunched = session()
        relaunched.restoreAtLaunch()

        #expect(relaunched.walkedHikeID == nil)
        #expect(hike.walkInProgress == nil)
        let closed = try #require(try walks(of: hike).first)
        #expect(closed.endReason == .abandoned)
        // A launch a day later is when the walk was found, not when it ended.
        #expect(closed.endedAt == lastKnown)
        #expect(closed.activeSeconds == walked)
        #expect(closed.activeSeconds < TrailWalkPolicy.staleAtLaunchAfter, "the sweep is not the walk")
        #expect(relaunched.lastEndedWalk == nil)
    }
}
