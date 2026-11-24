//
//  HikeRecorderTests+CarriedWalk.swift
//  OpenHikesTests
//
//  A recording that takes over from a hike already under way begins with the
//  ground that hike covered — see ``RecordingSeed``.
//
//  The points are in the journal from the session's first write, and the
//  recorder's live state is rebuilt from them as recovery rebuilds it, so
//  what these hold is the seam between the two halves: that the recording
//  dates itself from the hike's start, that the first live fix joins the
//  carried line rather than starting a walk of its own, and that a seed
//  belongs to one start and to no other.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import RealModule
import SwiftData
import Synchronization
import Testing

extension HikeRecorderTests {
    /// The walk these recordings are handed: eight points north along the
    /// meridian this suite's fixes use, 33 m and half a minute apart, from a
    /// hike that set off ten minutes ago and was last on its trail six and a
    /// half minutes ago.
    private enum Carried {
        static let latitude = 47.63
        static let longitude = 12.86
        static let stepDegrees = 0.0003
        static let stepSeconds: TimeInterval = 30
        static let baseElevation = 600.0
        static let stepClimb = 4.0
        static let pointCount = 8
        static let startedSecondsAgo: TimeInterval = 600
        static let meters = Double(pointCount - 1) * stepDegrees * RouteGeometry.metersPerDegreeLatitude
    }

    private func carriedWalk() -> RecordingSeed {
        let startedAt = clock.now.addingTimeInterval(-Carried.startedSecondsAgo)
        let points = (0..<Carried.pointCount).map { step in
            RecordingPoint(
                latitude: Carried.latitude + Double(step) * Carried.stepDegrees,
                longitude: Carried.longitude,
                timestamp: startedAt.addingTimeInterval(Double(step) * Carried.stepSeconds),
                horizontalAccuracy: RecordingSeed.carriedAccuracyMeters,
                elevation: Carried.baseElevation + Double(step) * Carried.stepClimb
            )
        }
        return RecordingSeed(startedAt: startedAt, points: points)
    }

    private var carriedMeters: Double { Carried.meters }

    @Test("a recording handed a walk begins with it: its start, its points and its distance")
    func beginsWithTheCarriedWalk() async throws {
        let hikeRecorder = makeRecorder()
        let seed = carriedWalk()

        await hikeRecorder.start(carrying: seed)

        #expect(hikeRecorder.phase == .recording, "it has points already, so it is not waiting for one")
        #expect(hikeRecorder.sessionStartedAt == seed.startedAt)
        #expect(hikeRecorder.currentHike?.date == seed.startedAt)
        #expect(hikeRecorder.stats.pointCount == seed.points.count)
        #expect(hikeRecorder.stats.distanceMeters.isApproximatelyEqual(to: carriedMeters, absoluteTolerance: 2))
        #expect(
            hikeRecorder.elapsedSeconds().isApproximatelyEqual(to: 600, absoluteTolerance: 5),
            "the clock counts from when the hike began"
        )
        #expect(hikeRecorder.carriedSeed == nil, "taken by the session it began")
        let journal = try #require(hikeRecorder.journal)
        #expect(try await journal.loadSession()?.points == seed.points, "and on disk before any fix arrives")
    }

    @Test("the first fix joins the carried line, and the saved hike holds both")
    func theFirstFixJoinsTheCarriedLine() async throws {
        let hikeRecorder = makeRecorder()
        let seed = carriedWalk()
        await hikeRecorder.start(carrying: seed)

        // Off the trail, to one side of where the carried line ends.
        source.deliver(fix(latitude: 47.6330, longitude: 12.8610))
        #expect(hikeRecorder.stats.pointCount == seed.points.count + 1)
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6332, longitude: 12.8610))

        let hike = try await hikeRecorder.stop()
        #expect(hike.route.count == seed.points.count + 2)
        #expect(hike.date == seed.startedAt)
        #expect(hike.route.first?.timestamp == seed.startedAt)
        #expect(hike.route.allSatisfy { $0.boundary == nil }, "one line: the fix carried on from the trail")
        #expect(hike.distanceMeters > carriedMeters + 100, "the carried ground and the way off it")
        let walk = try #require(hike.walks?.first)
        #expect(walk.startedAt == seed.startedAt, "its own History dates the hike from its start too")
    }

    /// The carried heights are the trail's own, and a fix's is the receiver's:
    /// 28 m apart here, which is no climb and no descent. The barometer
    /// measures on from the carried line's end, as it does from a resume's.
    @Test("the heights after the carried line carry on from its end, not from the receiver's")
    func heightsCarryOnFromTheCarriedLine() async throws {
        let elevation = StubRecordingElevationSource()
        let hikeRecorder = makeRecorder(elevationSource: elevation)
        let seed = carriedWalk()
        let carriedEnd = try #require(seed.points.last?.elevation)
        await hikeRecorder.start(carrying: seed)

        elevation.deliver(0)
        source.deliver(fix(latitude: 47.6330, longitude: 12.8610))
        clock.advance(by: 10)
        elevation.deliver(2)
        source.deliver(fix(latitude: 47.6332, longitude: 12.8610))

        let hike = try await hikeRecorder.stop()
        let joined = try #require(hike.route[seed.points.count].elevation)
        let next = try #require(hike.route[seed.points.count + 1].elevation)
        #expect(abs(joined - carriedEnd) < 1, "the receiver's 600 m is let in slowly, not stepped to")
        #expect((next - joined).isApproximatelyEqual(to: 2, absoluteTolerance: 1), "and the barometer's climb on top")
    }

    /// The carried points already say where the hiker was up to the last of
    /// them. A fix from before that is the walk's own past, however fresh.
    @Test("a fix taken before the last carried point adds nothing")
    func aFixFromBeforeTheCarriedLineEndsIsRefused() async {
        let hikeRecorder = makeRecorder()
        let seed = carriedWalk()
        await hikeRecorder.start(carrying: seed)
        let lastCarried = seed.points[seed.points.count - 1].timestamp

        source.deliver(
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 47.6310, longitude: 12.86),
                altitude: 600,
                horizontalAccuracy: 8,
                verticalAccuracy: 5,
                course: 0,
                speed: 1,
                timestamp: lastCarried.addingTimeInterval(-20)
            )
        )

        #expect(hikeRecorder.stats.pointCount == seed.points.count)
    }

    @Test("a walk waits for the permission prompt with the start it was handed to")
    func theSeedWaitsForPermission() async {
        let hikeRecorder = makeRecorder()
        let seed = carriedWalk()
        source.authorization = .notDetermined

        await hikeRecorder.start(carrying: seed)
        #expect(hikeRecorder.sessionID == nil)
        #expect(hikeRecorder.carriedSeed == seed)

        source.authorization = .authorized
        hikeRecorder.locationManagerDidChangeAuthorization(CLLocationManager())
        await settleDelegateHop(until: "the session the answer allows") { hikeRecorder.sessionID != nil }

        #expect(hikeRecorder.stats.pointCount == seed.points.count)
        #expect(hikeRecorder.sessionStartedAt == seed.startedAt)
    }

    /// The points are in the journal from the session's first write, so a
    /// launch that finds the journal finds a recording that began with them.
    @Test("a recording killed before its first fix comes back with the walk it began with")
    func theCarriedWalkSurvivesARelaunch() async throws {
        let seed = carriedWalk()
        let killed = makeRecorder()
        await killed.start(carrying: seed)
        // What the process ending does to the journal's handle.
        try await killed.journal?.close()

        let relaunched = makeRecorder()
        await relaunched.recoverOpenSession(automaticallyResume: false)

        #expect(relaunched.sessionStartedAt == seed.startedAt)
        #expect(relaunched.stats.pointCount == seed.points.count)
        #expect(relaunched.stats.distanceMeters.isApproximatelyEqual(to: carriedMeters, absoluteTolerance: 2))
        #expect(relaunched.currentHike?.date == seed.startedAt)
    }

    /// A start refused for want of location is over. One made later by
    /// anything but the recording screen's Start — Siri here — is a
    /// recording of its own, begins where the hiker stands then, and lets the
    /// walk go.
    @Test("a refused start's walk is not carried by a recording of its own")
    func aRefusedStartCarriesNothingForward() async {
        let hikeRecorder = makeRecorder()
        source.authorization = .denied
        await hikeRecorder.start(carrying: carriedWalk())
        #expect(hikeRecorder.phase == .failed(.locationDenied))

        source.authorization = .authorized
        await hikeRecorder.start()

        #expect(hikeRecorder.carriedSeed == nil)
        #expect(hikeRecorder.unclaimedSeed == nil, "the session that started let it go")
        #expect(hikeRecorder.phase == .waitingForFix)
        #expect(hikeRecorder.stats.pointCount == 0)
        #expect(hikeRecorder.sessionStartedAt == clock.now)
    }

    /// The walk was ended before the recording was asked for, so a start
    /// that fails before a session takes its points would leave them nowhere.
    @Test("a handoff refused precise location keeps its walk, and the retry begins with it")
    func aHandoffRefusedPrecisionKeepsItsWalk() async {
        let hikeRecorder = makeRecorder()
        let seed = carriedWalk()
        source.hasFullAccuracy = false
        await hikeRecorder.start(carrying: seed)
        #expect(hikeRecorder.phase == .failed(.preciseLocationRequired))
        #expect(hikeRecorder.unclaimedSeed == seed)

        // The alert answered, as its OK does.
        hikeRecorder.dismissFailure()
        #expect(hikeRecorder.phase == .idle)
        #expect(hikeRecorder.unclaimedSeed == seed, "still there for the retry")

        source.hasFullAccuracy = true
        await hikeRecorder.start(carrying: hikeRecorder.unclaimedSeed)

        #expect(hikeRecorder.phase == .recording)
        #expect(hikeRecorder.sessionStartedAt == seed.startedAt)
        #expect(hikeRecorder.stats.pointCount == seed.points.count)
        #expect(hikeRecorder.unclaimedSeed == nil)
    }

    @Test("a handoff whose journal will not open keeps its walk, and the retry begins with it")
    func aHandoffWithNoJournalKeepsItsWalk() async throws {
        struct Refused: Error {}
        let refuses = Mutex(true)
        let hikeRecorder = makeRecorder(openJournalHandle: { url in
            if refuses.withLock({ $0 }) { throw Refused() }
            return try FileHandle(forWritingTo: url)
        })
        let seed = carriedWalk()
        await hikeRecorder.start(carrying: seed)
        guard case .failed = hikeRecorder.phase else {
            Issue.record("precondition: the start failed, as \(hikeRecorder.phase)")
            return
        }
        #expect(hikeRecorder.sessionID == nil)
        #expect(hikeRecorder.unclaimedSeed == seed)

        hikeRecorder.dismissFailure()
        refuses.withLock { $0 = false }
        await hikeRecorder.start(carrying: hikeRecorder.unclaimedSeed)

        #expect(hikeRecorder.stats.pointCount == seed.points.count)
        let journal = try #require(hikeRecorder.journal)
        #expect(try await journal.loadSession()?.points == seed.points)
    }

    /// The map's button is a recording of its own, whatever failed before it.
    @Test("a start asked for afresh lets an unclaimed walk go")
    func aFreshStartLetsTheWalkGo() async {
        let hikeRecorder = makeRecorder()
        source.hasFullAccuracy = false
        await hikeRecorder.start(carrying: carriedWalk())
        hikeRecorder.dismissFailure()

        source.hasFullAccuracy = true
        await hikeRecorder.start(carrying: nil)

        #expect(hikeRecorder.unclaimedSeed == nil)
        #expect(hikeRecorder.stats.pointCount == 0)
        #expect(hikeRecorder.sessionStartedAt == clock.now)
    }

    @Test("with nothing to carry it is an ordinary start")
    func nothingToCarryIsAnOrdinaryStart() async {
        let hikeRecorder = makeRecorder()

        await hikeRecorder.start(carrying: RecordingSeed(startedAt: clock.now.addingTimeInterval(-600), points: []))

        #expect(hikeRecorder.phase == .waitingForFix)
        #expect(hikeRecorder.sessionStartedAt == clock.now)
        #expect(hikeRecorder.stats.pointCount == 0)
    }
}
