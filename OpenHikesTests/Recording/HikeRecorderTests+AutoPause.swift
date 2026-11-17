//
//  HikeRecorderTests+AutoPause.swift
//  OpenHikesTests
//
//  What the recorder does with Auto-Pause's answers (#1470).
//
//  ``AutoPauseWatchTests`` pins when a stop is called and when it ends; these
//  pin what calling one does to a recording. A pause counted from a moment
//  minutes behind it has to take those minutes back out of the journal, the
//  figures and the saved hike, and a pause that ends by itself has to hand
//  the walk away to the track in order, as the next segment. The rest is whose
//  pause it is: the app's keeps its feed and ends by itself, and a hiker's
//  does neither.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import RealModule
import Synchronization
import Testing

extension HikeRecorderTests {
    private static let trailheadLatitude = 47.63
    private static let metersPerDegree = 111_195.0
    /// The gap between two fixes of a walk, and the metres walked in it.
    private static let stride: TimeInterval = 10
    private static let strideMeters = 10.0
    /// The gap between two fixes at a stop: the heartbeat a recording keeps
    /// while nothing moves.
    private static let heartbeat: TimeInterval = 30
    /// Where the scripted walk stops, and when its clock says it did: five
    /// fixes up the path, the fifth 40 m on.
    private static let stopMeters = 40.0
    private static let stopFixCount = 5
    private static let stoppedAfter: TimeInterval = 50
    /// Long enough for the watch to call a stop of it.
    private static let stopLength = AutoPausePolicy.standard.minimumStopSeconds

    private func north(_ meters: Double) -> Double {
        Self.trailheadLatitude + meters / Self.metersPerDegree
    }

    /// A fix every ten metres and ten seconds, the first `meters` up the path.
    private func walk(from meters: Double, fixes count: Int, speed: CLLocationSpeed = 1) {
        for step in 0..<count {
            clock.advance(by: Self.stride)
            source.deliver(fix(latitude: north(meters + Double(step) * Self.strideMeters), speed: speed))
        }
    }

    /// A fix every thirty seconds, a couple of metres past `meters`.
    private func stay(at meters: Double, for seconds: TimeInterval) {
        for _ in 0..<Int(seconds / Self.heartbeat) {
            clock.advance(by: Self.heartbeat)
            source.deliver(fix(latitude: north(meters + 2), speed: 0))
        }
    }

    /// A recorder that has walked to a place and stayed there long enough to
    /// be paused, with the journal and the figures settled behind the pause.
    private func autoPausedRecorder(
        movementReminders: MovementReminderController? = nil,
        sharedStateStore: (any RecordingSharedStateStoring)? = nil
    ) async -> HikeRecorder {
        let hikeRecorder = makeRecorder(
            sharedStateStore: sharedStateStore,
            movementReminders: movementReminders,
            autoPause: true
        )
        await hikeRecorder.start()
        walk(from: 0, fixes: Self.stopFixCount)
        stay(at: Self.stopMeters, for: Self.stopLength)
        await settleAutoPause(hikeRecorder)
        return hikeRecorder
    }

    private func settleAutoPause(_ hikeRecorder: HikeRecorder) async {
        await hikeRecorder.autoPause.refresh?.value
        await hikeRecorder.journalQueue.drain()
    }

    // MARK: - The pause

    @Test("a stop pauses the recording from where the stop began")
    func aStopPausesFromWhereItBegan() async throws {
        let began = clock.now
        let hikeRecorder = await autoPausedRecorder()

        #expect(hikeRecorder.phase == .paused)
        #expect(hikeRecorder.isAutoPaused)
        let session = try #require(try await hikeRecorder.journal?.loadSession())
        let stoppedAt = began.addingTimeInterval(Self.stoppedAfter)
        #expect(session.metadata.pausedIntervals == [RecordingPauseInterval(startedAt: stoppedAt, endedAt: nil)])
        #expect(session.points.count == Self.stopFixCount, "the fixes kept inside the stop are taken back")
        #expect(session.points.last?.timestamp == stoppedAt)
    }

    @Test("the figures and the trace give the stop's first minutes back")
    func theFiguresGiveTheStopBack() async {
        let hikeRecorder = await autoPausedRecorder()

        #expect(hikeRecorder.stats.pointCount == Self.stopFixCount)
        #expect(hikeRecorder.stats.distanceMeters.isApproximatelyEqual(to: Self.stopMeters, absoluteTolerance: 0.5))
        #expect(hikeRecorder.accumulator.recordedDuration == Self.stoppedAfter - Self.stride)
        #expect(hikeRecorder.trace.recordedCoordinates.count == Self.stopFixCount)
    }

    @Test("an auto-pause keeps its feed, at the filter of a recording standing still")
    func anAutoPauseKeepsItsFeed() async {
        let hikeRecorder = await autoPausedRecorder()

        #expect(source.stopCount == 0)
        #expect(source.movementWatchStarts == 0)
        #expect(source.currentProfile?.name == "auto-paused")
        #expect(source.currentProfile?.distanceFilter == RecordingEnergyPolicy.stationaryDistanceFilter)
        #expect(source.currentProfile?.desiredAccuracy == kCLLocationAccuracyBest)
        #expect(hikeRecorder.energyProfile.reason != nil, "the recording screen says the app made the pause")
    }

    @Test("the widget and the Lock Screen are told the recording is paused")
    func theSurfacesAreToldItIsPaused() async throws {
        let store = StubRecordingSharedStateStore()
        let hikeRecorder = await autoPausedRecorder(sharedStateStore: store)
        await hikeRecorder.sharedStateQueue.drain()

        let snapshot = try #require(await store.savedSnapshots().last)
        #expect(!snapshot.isCapturingFixes)
        #expect(snapshot.pointCount == Self.stopFixCount, "with the figures the pause left")
    }

    /// The recorder's distance filter widens once it calls the hiker
    /// stationary, and on a bench under open sky no fix arrives after that.
    @Test("a stop no fix arrives during is paused when its timer rings")
    func aSilentStopIsPausedByTheTimer() async {
        let hikeRecorder = makeRecorder(autoPause: true)
        await hikeRecorder.start()
        walk(from: 0, fixes: Self.stopFixCount)
        stay(at: Self.stopMeters, for: Self.heartbeat * 2)

        clock.advance(by: Self.stopLength)
        #expect(hikeRecorder.phase == .recording, "nothing has asked yet")
        hikeRecorder.checkAutoPause()

        #expect(hikeRecorder.isAutoPaused)
    }

    @Test("a hiker motion calls still from the last fix is paused with no fix to say so")
    func stillnessPausesWithoutAFix() async {
        let motion = StubRecordingMotionSource()
        let hikeRecorder = makeRecorder(motionSource: motion, autoPause: true)
        await hikeRecorder.start()
        walk(from: 0, fixes: Self.stopFixCount)

        clock.advance(by: Self.stride)
        motion.deliver(.stationary)
        clock.advance(by: Self.stopLength)
        hikeRecorder.checkAutoPause()

        #expect(hikeRecorder.isAutoPaused)
    }

    /// The tunnel walked on foot, and a halt inside it once the stop's
    /// minutes have run out.
    @Test("a silence motion heard walked is not paused when motion later calls it still")
    func aWalkedSilenceIsNotPaused() async {
        let motion = StubRecordingMotionSource()
        let hikeRecorder = makeRecorder(motionSource: motion, autoPause: true)
        await hikeRecorder.start()
        walk(from: 0, fixes: Self.stopFixCount)

        clock.advance(by: Self.stride)
        motion.deliver(.pedestrian)
        clock.advance(by: Self.stopLength)
        motion.deliver(.stationary)

        #expect(hikeRecorder.phase == .recording, "walking into silence is a lost signal, not a stop")
        #expect(hikeRecorder.stats.pointCount == Self.stopFixCount)
    }

    /// Eight fixes of a steady walk, the last four inside one stop's area
    /// for thirty seconds, and then a tunnel: four and a half minutes with
    /// no signal, out 400 m on. Nothing of it is a stop.
    @Test("a tunnel after a steady walk keeps the walk to it and the walk through it", arguments: [false, true])
    func aTunnelIsNotAStop(motionSaysOnFoot: Bool) async throws {
        let motion = StubRecordingMotionSource()
        let hikeRecorder = makeRecorder(motionSource: motionSaysOnFoot ? motion : nil, autoPause: true)
        await hikeRecorder.start()
        if motionSaysOnFoot { motion.deliver(.pedestrian) }
        walk(from: 0, fixes: 8)

        clock.advance(by: Self.stopLength - 3 * Self.stride)
        hikeRecorder.checkAutoPause()
        #expect(hikeRecorder.phase == .recording)

        clock.advance(by: 130)
        source.deliver(fix(latitude: north(470), speed: 1))
        walk(from: 480, fixes: 1)
        await hikeRecorder.journalQueue.drain()

        #expect(hikeRecorder.stats.pointCount == 10, "the fixes walked to the tunnel are kept")
        #expect(hikeRecorder.stats.distanceMeters > 400)
        #expect(hikeRecorder.accumulator.recordedDuration == 480)
        let session = try #require(try await hikeRecorder.journal?.loadSession())
        #expect(session.metadata.pausedIntervals.isEmpty, "the lost signal is not a pause")
    }

    @Test("with the switch off a stop is recorded as it always was")
    func theSwitchOff() async {
        let hikeRecorder = makeRecorder(autoPause: false)
        await hikeRecorder.start()
        walk(from: 0, fixes: Self.stopFixCount)
        stay(at: Self.stopMeters, for: Self.stopLength * 2)
        hikeRecorder.checkAutoPause()

        #expect(hikeRecorder.phase == .recording)
        #expect(hikeRecorder.stats.pointCount > Self.stopFixCount)
    }

    // MARK: - The walk away

    @Test("walking away resumes the recording, from the first fix of the walk away")
    func walkingAwayResumes() async throws {
        let began = clock.now
        let hikeRecorder = await autoPausedRecorder()
        let leftAt = clock.now.addingTimeInterval(Self.stride)

        walk(from: Self.stopMeters + 20, fixes: 4)
        await settleAutoPause(hikeRecorder)

        #expect(hikeRecorder.phase == .recording)
        #expect(!hikeRecorder.isAutoPaused)
        let session = try #require(try await hikeRecorder.journal?.loadSession())
        #expect(session.metadata.pausedIntervals == [
            RecordingPauseInterval(startedAt: began.addingTimeInterval(Self.stoppedAfter), endedAt: leftAt),
        ])
        #expect(
            session.points.count == Self.stopFixCount + 4,
            "the fixes held while the walk away was uncertain are kept"
        )
        #expect(session.points[Self.stopFixCount].timestamp == leftAt)
        #expect(session.points.map { $0.flags.contains(.resumed) } == [
            false, false, false, false, false, true, false, false, false,
        ])
        #expect(source.currentProfile?.name == "precise")
    }

    @Test("the walk away is the next segment, after a stop of its own length")
    func theWalkAwayIsTheNextSegment() async throws {
        let hikeRecorder = await autoPausedRecorder()
        walk(from: Self.stopMeters + 20, fixes: 4)
        await settleAutoPause(hikeRecorder)

        let segments = hikeRecorder.stats.segments
        try #require(segments.count == 2)
        #expect(segments[0].distanceMeters.isApproximatelyEqual(to: Self.stopMeters, absoluteTolerance: 0.5))
        #expect(segments[0].seconds == Self.stoppedAfter - Self.stride)
        #expect(segments[0].stopSeconds == Self.stopLength + Self.stride)
        #expect(segments[1].distanceMeters.isApproximatelyEqual(to: 3 * Self.strideMeters, absoluteTolerance: 0.5))
        #expect(segments[1].stopSeconds == nil, "the segment in progress has no stop after it yet")
    }

    /// The hiker steps out of the area on the fix after the one that called
    /// the stop, before the journal has been cut back or the figures rebuilt.
    @Test("a walk away that begins before the pause has settled still leaves the stop out")
    func walkingAwayBeforeThePauseSettles() async throws {
        let hikeRecorder = makeRecorder(autoPause: true)
        await hikeRecorder.start()
        walk(from: 0, fixes: Self.stopFixCount)
        stay(at: Self.stopMeters, for: Self.stopLength)
        #expect(hikeRecorder.isAutoPaused)

        walk(from: Self.stopMeters + 20, fixes: 4)
        await settleAutoPause(hikeRecorder)

        let session = try #require(try await hikeRecorder.journal?.loadSession())
        #expect(session.points.count == Self.stopFixCount + 4)
        #expect(hikeRecorder.stats.pointCount == Self.stopFixCount + 4)
        #expect(hikeRecorder.stats.segments.count == 2)
        #expect(
            hikeRecorder.stats.distanceMeters.isApproximatelyEqual(
                to: Self.stopMeters + 3 * Self.strideMeters,
                absoluteTolerance: 0.5
            )
        )
    }

    /// The case #472 described: the recording forgotten, and the drive home.
    @Test("a drive away from a stop leaves the recording paused")
    func aDriveStaysPaused() async {
        let hikeRecorder = await autoPausedRecorder()

        for step in 1...10 {
            clock.advance(by: Self.stride)
            source.deliver(fix(latitude: north(Self.stopMeters + Double(step) * 150), speed: 15))
        }

        #expect(hikeRecorder.isAutoPaused)
        #expect(hikeRecorder.stats.pointCount == Self.stopFixCount)
    }

    // MARK: - Whose pause it is

    @Test("Resume during an auto-pause resumes at once, and the next fix opens a new leg")
    func resumeByHand() async throws {
        let hikeRecorder = await autoPausedRecorder()

        await hikeRecorder.resume()
        #expect(hikeRecorder.phase == .recording)
        #expect(!hikeRecorder.isAutoPaused)
        clock.advance(by: Self.stride)
        source.deliver(fix(latitude: north(Self.stopMeters + 5)))
        await hikeRecorder.journalQueue.drain()

        let session = try #require(try await hikeRecorder.journal?.loadSession())
        #expect(session.points.last?.flags.contains(.resumed) == true)
        #expect(session.metadata.pausedIntervals.last?.endedAt != nil)
    }

    @Test("Pause during an auto-pause makes it the hiker's: parked, reminded, and not ended for them")
    func pauseByHandTakesItOver() async {
        let harness = MovementReminderHarness.harness()
        let hikeRecorder = await autoPausedRecorder(movementReminders: harness.controller)
        #expect(source.movementWatchStarts == 0, "precondition: the app's own pause keeps the recording feed")

        hikeRecorder.pause()
        await hikeRecorder.journalQueue.drain()

        #expect(hikeRecorder.phase == .paused)
        #expect(!hikeRecorder.isAutoPaused)
        #expect(source.movementWatchStarts == 1, "parked as a pause by hand is")
        #expect(hikeRecorder.energyProfile.reason == nil, "nothing says the recording will resume by itself")

        walk(from: Self.stopMeters + 20, fixes: 4)
        #expect(hikeRecorder.phase == .paused, "a hiker's pause is the hiker's to end")
    }

    @Test("turning the switch off during an auto-pause hands the pause to the hiker")
    func switchingOffHandsThePauseOver() async {
        let hikeRecorder = await autoPausedRecorder()

        hikeRecorder.defaults.set(false, forKey: SettingsKey.autoPauseEnabled)
        walk(from: Self.stopMeters + 20, fixes: 4)

        #expect(hikeRecorder.phase == .paused)
        #expect(!hikeRecorder.isAutoPaused)
    }

    @Test("a relaunch finds an auto-pause as a pause, with the stop left out")
    func aRelaunchFindsAPause() async throws {
        let paused = await autoPausedRecorder()
        try await paused.journal?.close()
        recorder = nil

        let relaunched = makeRecorder(autoPause: true)
        await relaunched.recoverOpenSession()

        #expect(relaunched.phase == .paused)
        #expect(!relaunched.isAutoPaused, "only the launch that made the pause ends it")
        #expect(relaunched.stats.pointCount == Self.stopFixCount)
    }

    // MARK: - The saved hike

    @Test("a hike saved after a stop carries it as a pause, and its segments show it")
    func theSavedHikeCarriesTheStop() async throws {
        let hikeRecorder = await autoPausedRecorder()
        walk(from: Self.stopMeters + 20, fixes: 4)

        let hike = try savedHike(from: try await hikeRecorder.stop())

        #expect(hike.route.count == Self.stopFixCount + 4)
        #expect(hike.route.indices.filter { hike.route[$0].isPauseBoundary } == [Self.stopFixCount])
        let segments = RouteSegments.segments(of: hike.route, distanceMeters: hike.distanceMeters)
        try #require(segments.count == 2)
        #expect(segments[0].stopSeconds == Self.stopLength + Self.stride)
        let walk = try #require(hike.walks?.first)
        #expect(
            walk.activeSeconds == Self.stoppedAfter - Self.stride + 3 * Self.stride,
            "the stop is outside the clock Avg Speed divides by"
        )
    }

    @Test("a hike stopped during an auto-pause ends where the stop began")
    func stoppingDuringAnAutoPause() async throws {
        let began = clock.now
        let hikeRecorder = await autoPausedRecorder()

        let hike = try savedHike(from: try await hikeRecorder.stop())

        #expect(hike.route.count == Self.stopFixCount)
        #expect(hike.route.last?.timestamp == began.addingTimeInterval(Self.stoppedAfter))
        #expect(hike.route.allSatisfy { !$0.isPauseBoundary })
        #expect(!hikeRecorder.isAutoPaused)
    }

    // MARK: - The evidence

    @Test("every fix a running recording is delivered is written down, kept or not")
    func theEvidenceIsWrittenDown() async {
        let evidence = Mutex<[AutoPauseEvidence.Record]>([])
        let hikeRecorder = makeRecorder(autoPauseEvidence: { record in
            evidence.withLock { $0.append(record) }
        })
        await hikeRecorder.start()

        walk(from: 0, fixes: 2)
        // Too loose to keep, and still evidence of where the hiker is.
        clock.advance(by: Self.stride)
        source.deliver(fix(latitude: north(25), accuracy: 80))

        let kept = evidence.withLock { records in
            records.map { record in
                if case .fix(_, let kept) = record { kept } else { false }
            }
        }
        #expect(kept == [true, true, false])
        #expect(hikeRecorder.stats.pointCount == 2)
    }
}
