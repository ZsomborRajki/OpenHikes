//
//  TrailWalkSessionTests+HandOff.swift
//  OpenHikesTests
//
//  *Record Instead* while the walk's line is being read — see *Recording
//  instead* in `TrailWalkSession+OffTrail.swift`. A walk adopted at launch
//  has no profile until its hike's screen feeds it one, so the hand-off reads
//  the line first, and the walk goes on while it does: a fix matches, the
//  walk ends, another begins, or the read fails. Each read here is held open
//  by the stub until the test has done what it is about.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import Testing

extension WalkHandOff {
    /// What a hand-off that ended the walk came to, or `nil` for one that
    /// ended nothing.
    var ended: (end: TrailWalkEnd, seed: RecordingSeed?)? {
        guard case let .ended(end, seed) = self else { return nil }
        return (end, seed)
    }
}

extension TrailWalkSessionTests {
    /// A walk along seven points of `walked`, as the next launch adopts it:
    /// with no profile in hand, and with the look at its line that the
    /// launch takes already landed, so that the next read is the hand-off's.
    private func adoptedWalk(along walked: Hike, fetch: FailingLineFetch) async -> TrailWalkSession {
        let profile = RouteProfile(route: walked.route)
        let opening = session()
        #expect(opening.start(hike: walked, profile: profile))
        walk(opening, hike: walked, profile: profile, from: 0, through: 6)
        let relaunched = session()
        relaunched.restoreAtLaunch()
        await relaunched.lineCheck?.value
        #expect(relaunched.walkedHikeID == walked.id)
        #expect(relaunched.walkedProfile == nil, "precondition: nothing has handed it one")
        relaunched.lineLooks.fetch = fetch.fetch
        return relaunched
    }

    /// The hand-off, under way with its read of the line held open.
    private func handOffWaitingOnTheLine(
        of session: TrailWalkSession,
        fetch: FailingLineFetch
    ) async -> Task<WalkHandOff, Never> {
        let handOff = Task { await session.handOffToRecording() }
        await settleDelegateHop(until: "the hand-off to read the walk's line") { fetch.count == 1 }
        return handOff
    }

    /// The points and the row have to describe one walk, to the instant at
    /// both ends, or the library counts part of it twice.
    @Test("a fix matched while the walk's line is read is in what is handed over, and in the row alike")
    func aFixDuringTheReadIsInBoth() async throws {
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        let fetch = FailingLineFetch(failing: [], holding: 1)
        defer { fetch.open() }
        let session = await adoptedWalk(along: walked, fetch: fetch)
        let handOff = await handOffWaitingOnTheLine(of: session, fetch: fetch)

        clock.advance(by: 60)
        let matchedAt = clock.now
        session.recordBackgroundMatch(hikeID: walked.id, distance: profile.distances[7], at: matchedAt)
        fetch.open()
        let ended = try #require(await handOff.value.ended)

        let row = try #require(ended.end.walk)
        let seed = try #require(ended.seed)
        #expect(row.endedAt == matchedAt)
        #expect(row.furthestDistanceMeters.isApproximatelyEqual(to: profile.distances[7], absoluteTolerance: 0.001))
        #expect(seed.points.first?.timestamp == row.startedAt)
        #expect(seed.points.last?.timestamp == row.endedAt)
        let last = try #require(seed.points.last)
        #expect(RouteGeometry.distanceMeters(from: last.coordinate, to: walked.route[7].clCoordinate) < 0.5)
    }

    /// The walk went into its trail's History by its own end, and the hiker
    /// still asked to record.
    @Test("a walk that ended while its line was read hands nothing over")
    func aWalkThatEndedMeanwhileHandsNothingOver() async throws {
        let walked = hike()
        let fetch = FailingLineFetch(failing: [], holding: 1)
        defer { fetch.open() }
        let session = await adoptedWalk(along: walked, fetch: fetch)
        let handOff = await handOffWaitingOnTheLine(of: session, fetch: fetch)

        #expect(session.end().walk != nil)
        fetch.open()

        guard case .noWalk = await handOff.value else {
            Issue.record("a walk already over has nothing to end or carry")
            return
        }
        #expect(try walks(of: walked).count == 1, "the one row its own end left")
    }

    /// A walk and a recording never run together: the next walk, started in
    /// the moment the line took to read, is not the walk the hiker answered
    /// about, and is neither ended nor recorded beside.
    @Test("a walk another took the place of while its line was read starts nothing, and the other goes on")
    func aReplacedWalkStartsNothing() async throws {
        let walked = hike()
        let other = hike(title: "Valley Path")
        let fetch = FailingLineFetch(failing: [], holding: 1)
        defer { fetch.open() }
        let session = await adoptedWalk(along: walked, fetch: fetch)
        let handOff = await handOffWaitingOnTheLine(of: session, fetch: fetch)

        session.end()
        clock.advance(by: 1)
        #expect(session.start(hike: other, profile: RouteProfile(route: other.route)))
        fetch.open()

        guard case .overtaken = await handOff.value else {
            Issue.record("the walk under way is not the one the hiker answered about")
            return
        }
        #expect(session.walkedHikeID == other.id)
        #expect(try walks(of: other).isEmpty)
    }

    /// A read that fails says nothing about the line, and a walk ended for it
    /// would have its ground in the recording only — or, under the History's
    /// minimum, nowhere.
    @Test("a line that cannot be read ends nothing, and the walk can be handed over again")
    func anUnreadableLineEndsNothing() async throws {
        let walked = hike()
        let fetch = FailingLineFetch(failing: [1])
        let session = await adoptedWalk(along: walked, fetch: fetch)

        guard case .lineUnreadable = await session.handOffToRecording() else {
            Issue.record("a failed read must not end the walk")
            return
        }
        #expect(session.walkedHikeID == walked.id)
        #expect(walked.walkInProgress != nil, "still under way on disk too")
        #expect(try walks(of: walked).isEmpty)

        let retried = try #require(await session.handOffToRecording().ended)
        #expect(retried.end.walk != nil)
        #expect(retried.seed?.points.isEmpty == false)
        #expect(fetch.count == 2)
    }
}
