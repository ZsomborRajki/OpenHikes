//
//  HikeRecorderTests+GPS.swift
//  OpenHikesTests
//
//  `source.deliver(…)` needs no settle: the recorder's `nonisolated` delegate
//  callback reaches main-actor state through `onMainActor`, which runs its
//  body synchronously when the caller is already on the main actor — and a
//  main-actor-isolated test always is. Whatever the callback then schedules
//  for later — a journal flush, an authorization branch that has to suspend —
//  is waited for by name, at the call site that depends on it.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension HikeRecorderTests {
    @Test("Start creates one draft and Stop finalizes that same hike")
    func startCreatesDraftAndStopFinalizesIt() async throws {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        #expect(source.startCount == 1)
        let draft = try #require(hikeRecorder.currentHike)
        #expect(draft.isRecording)
        #expect(draft.route.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)

        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))

        #expect(
            draft.route.isEmpty,
            "the durable row exists, but the live trace must not rewrite SwiftData per fix"
        )
        #expect(hikeRecorder.stats.pointCount == 2)

        let hike = try savedHike(from: await hikeRecorder.stop())

        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)
        #expect(hike.id == draft.id)
        #expect(!hike.isRecording)
        #expect(hike.route.count == 2)
        #expect(
            hike.rawRoute.isEmpty,
            "with no matcher yet the route is the raw trace; a second copy is pure cost"
        )
        #expect(hike.distanceMeters > 20)
        #expect(hikeRecorder.phase == .idle)
    }

    @Test("the finalized hike stays recorder-owned until cleanup finishes")
    func finalizedHikeRemainsOwnedDuringCleanup() async throws {
        let sharedStore = BlockingClearRecordingSharedStateStore()
        let hikeRecorder = makeRecorder(sharedStateStore: sharedStore)
        await hikeRecorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 10)
        source.deliver(fix(latitude: 47.6302))

        let stop = Task { try await hikeRecorder.stop() }
        await sharedStore.waitForClearToStart()

        let hike = try #require(hikeRecorder.currentHike)
        #expect(hikeRecorder.phase == .saving)
        #expect(!hike.isRecording)
        #expect(
            hike.belongsToActiveRecording(
                currentHikeID: hikeRecorder.currentHike?.id
            )
        )

        await sharedStore.releaseClear()
        _ = try savedHike(from: try await stop.value)

        #expect(hikeRecorder.currentHike == nil)
        #expect(!hike.belongsToActiveRecording(currentHikeID: nil))
    }

    @Test("discard removes the active recording entry")
    func discardRemovesDraft() async throws {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        let draftID = try #require(hikeRecorder.currentHike?.id)

        #expect(try context.fetch(FetchDescriptor<Hike>()).count == 1)

        await hikeRecorder.discard()

        #expect(hikeRecorder.phase == .idle)
        #expect(hikeRecorder.currentHike == nil)
        #expect(
            try context.fetch(
                FetchDescriptor<Hike>(
                    predicate: #Predicate { $0.id == draftID }
                )
            ).isEmpty
        )
    }

    @Test("Start replaces an orphaned recording draft")
    func startRemovesOrphanedDraft() async throws {
        let orphan = Hike(
            title: "Interrupted Hike",
            distanceMeters: 0,
            isRecording: true
        )
        context.insert(orphan)
        try context.save()

        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()

        let current = try #require(hikeRecorder.currentHike)
        let hikes = try context.fetch(FetchDescriptor<Hike>())
        #expect(hikes.count == 1)
        #expect(current.id != orphan.id)
        #expect(hikes.first?.id == current.id)
    }

    @Test("recovery removes a recording draft that has no journal")
    func recoveryRemovesOrphanedDraft() async throws {
        context.insert(
            Hike(
                title: "Interrupted Hike",
                distanceMeters: 0,
                isRecording: true
            )
        )
        try context.save()

        let hikeRecorder = makeRecorder()
        await hikeRecorder.recoverOpenSession()

        #expect(hikeRecorder.phase == .idle)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    @Test("the bundled Thumsee simulator route records and saves end to end")
    func bundledDemoRouteRecordsHike() async throws {
        let routeURL = try #require(
            Bundle.main.url(
                forResource: "ThumseeLoopFast",
                withExtension: "gpx"
            )
        )
        let track = try GPXImport.load(from: routeURL)
        let locations = acceleratedLocations(
            from: track,
            endingAt: clock.now
        )
        let hikeRecorder = makeRecorder()

        await hikeRecorder.start()
        source.deliver(locations)

        let acceptedPointCount = hikeRecorder.stats.pointCount
        let hike = try savedHike(from: await hikeRecorder.stop())
        let first = try #require(hike.route.first)
        let last = try #require(hike.route.last)
        let sourceFirst = try #require(track.points.first)
        let sourceLast = try #require(track.points.last)

        #expect(track.points.count > 300)
        #expect(acceptedPointCount > 250)
        #expect(hike.route.count == acceptedPointCount)
        #expect(
            RouteGeometry.distanceMeters(
                from: first.clCoordinate,
                to: sourceFirst.coordinate
            ) < 1
        )
        #expect(
            RouteGeometry.distanceMeters(
                from: last.clCoordinate,
                to: sourceLast.coordinate
            ) < 1
        )
        #expect(
            abs(hike.distanceMeters - track.distanceMeters)
                < track.distanceMeters * 0.15
        )
        #expect(hike.rawRoute.isEmpty)
    }

    @Test("the journal falls back to Application Support without an App Group")
    func journalFallsBackOutsideTheAppGroup() {
        let appGroup = URL(filePath: "/tmp/group.example")
        let support = URL(filePath: "/tmp/support.example")

        #expect(
            HikeRecorder.journalDirectory(
                appGroupContainer: appGroup,
                applicationSupport: support
            ) == appGroup.appendingPathComponent("Recording", isDirectory: true),
            "the shared container is still preferred, for the widget payload to come"
        )
        #expect(
            HikeRecorder.journalDirectory(
                appGroupContainer: nil,
                applicationSupport: support
            ) == support.appendingPathComponent("Recording", isDirectory: true),
            "an unprovisioned App Group must not be the difference between recording and refusing"
        )
        #expect(
            HikeRecorder.journalDirectory(
                appGroupContainer: nil,
                applicationSupport: nil
            ) == nil
        )
    }

    @Test("a paused session is not described as recording")
    func pausedSessionIsNotCapturingFixes() async {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        source.deliver(fix(latitude: 47.63))
        #expect(hikeRecorder.isCapturingFixes)

        hikeRecorder.pause()

        #expect(hikeRecorder.isActive, "still reachable from the hikes list")
        #expect(!hikeRecorder.isCapturingFixes, "but no longer taking fixes")
    }

    @Test("elapsed time comes from a monotonic source, not the wall clock")
    func elapsedTimeSurvivesAClockChange() async {
        let uptime = TestClock(Date(timeIntervalSince1970: 1000))
        let hikeRecorder = HikeRecorder(
            container: container,
            source: source,
            journalDirectory: directory,
            clock: clock.read,
            uptime: { uptime.now.timeIntervalSince1970 },
            journalFlushDelay: .zero,
            automaticallyRecovers: false
        )
        await hikeRecorder.start()

        uptime.advance(by: 90)
        // Someone's phone picks up an NTP correction an hour into the walk.
        clock.advance(by: -3600)

        #expect(hikeRecorder.elapsedSeconds() == 90)
    }

    @Test("batched Core Location delivery keeps every accepted fix")
    func batchedDeliveryIsRecordedInTimestampOrder() async {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        let first = fix(latitude: 47.63)
        clock.advance(by: 10)
        let second = fix(latitude: 47.6302)

        source.deliver([second, first])

        #expect(hikeRecorder.stats.pointCount == 2)
    }

    @Test("a rejected weak fix still reports weak GPS signal")
    func rejectedWeakFixUpdatesAccuracyOnly() async {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()

        source.deliver(
            fix(
                latitude: 47.63,
                accuracy:
                    RecordingFixPolicy.maximumHorizontalAccuracy + 450
            )
        )

        #expect(
            hikeRecorder.stats.horizontalAccuracy
                == RecordingFixPolicy.maximumHorizontalAccuracy + 450
        )
        #expect(hikeRecorder.stats.pointCount == 0)
        #expect(hikeRecorder.phase == .waitingForFix)
    }

    @Test("a lone accepted fix is flushed without waiting for ten points")
    func sparseFixesAreFlushedOnDeadline() async throws {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        source.deliver(fix(latitude: 47.63))

        // The append and the flush behind it are the recorder's own queued
        // work, and seeing either takes an `await` — which a settle condition,
        // being synchronous, cannot make. So poll the file against a real
        // deadline rather than against a number of scheduler turns: sixteen
        // yields bought whatever progress the machine happened to be idle
        // enough to give.
        let journal = TrackJournal(directory: directory)
        var session = try await journal.loadSession()
        let deadline = ContinuousClock.now + .seconds(5)
        while session?.points.isEmpty ?? true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            session = try await journal.loadSession()
        }

        let flushed = try #require(
            session,
            "the accepted fix never reached the journal file"
        )
        #expect(flushed.points.count == 1)
    }

    @Test("pause and resume do not add the distance crossed while paused")
    func pauseDoesNotBridgeGap() async throws {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        source.deliver(fix(latitude: 47.63))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.631))

        hikeRecorder.pause()
        clock.advance(by: 300)
        await hikeRecorder.resume()
        source.deliver(fix(latitude: 47.64))
        clock.advance(by: 60)
        source.deliver(fix(latitude: 47.641))

        let hike = try savedHike(from: await hikeRecorder.stop())
        #expect(abs(hike.distanceMeters - 222) < 5)
        #expect(hike.route.count == 4, "the drawn route remains continuous in v1")
    }

    @Test("reduced accuracy refuses to start a meaningless trace")
    func reducedAccuracyIsRefused() async {
        source.hasFullAccuracy = false
        let hikeRecorder = makeRecorder()

        await hikeRecorder.start()

        #expect(source.fullAccuracyRequests == 1)
        #expect(hikeRecorder.phase == .failed(.preciseLocationRequired))
        #expect(source.startCount == 0)
    }

    @Test("losing precise location pauses an active recording with an error")
    func preciseLocationRevokedMidRecording() async {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        source.hasFullAccuracy = false

        hikeRecorder.locationManagerDidChangeAuthorization(CLLocationManager())
        // Still a hop, unlike a delivered fix: the authorization callback's
        // authorized branch awaits, so it stayed a `Task { @MainActor in … }`.
        await settleDelegateHop(until: "the revoked precision to fail the recording") {
            hikeRecorder.phase == .failed(.preciseLocationRequired)
        }

        #expect(hikeRecorder.phase == .failed(.preciseLocationRequired))
        #expect(source.stopCount == 1)
    }

    @Test("revoking location stops every active recording sensor")
    func locationRevokedMidRecording() async {
        let elevation = StubRecordingElevationSource()
        let hikeRecorder = makeRecorder(elevationSource: elevation)
        await hikeRecorder.start()
        source.authorization = .denied

        hikeRecorder.locationManagerDidChangeAuthorization(CLLocationManager())
        // `fail(_:endLocationUpdates:)` stops the sensors before it publishes
        // the phase, so the two counts below are settled once this holds.
        await settleDelegateHop(until: "the denied authorization to fail the recording") {
            hikeRecorder.phase == .failed(.locationDenied)
        }

        #expect(hikeRecorder.phase == .failed(.locationDenied))
        #expect(source.stopCount == 1)
        // Twice, exactly: `startElevationUpdates()` stops the source before it
        // starts it, and `fail(_:endLocationUpdates:)` stops it again. A third
        // would mean something restarted the barometer after the failure.
        #expect(elevation.stopCount == 2)
    }

    @Test("a completed journal is saved on the next launch")
    func completedJournalIsRecovered() async throws {
        let sessionID = UUID()
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: sessionID, startedAt: clock.now)
        try await journal.append(
            RecordingPoint(
                latitude: 47.63,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        clock.advance(by: 10)
        try await journal.append(
            RecordingPoint(
                latitude: 47.6302,
                longitude: 12.86,
                timestamp: clock.now,
                horizontalAccuracy: 8
            )
        )
        try await journal.finish(at: clock.now)

        let hikeRecorder = makeRecorder()
        await hikeRecorder.recoverOpenSession()

        let hikes = try context.fetch(FetchDescriptor<Hike>())
        #expect(hikes.count == 1)
        #expect(hikes.first?.id == sessionID)
        #expect(hikes.first?.isRecording == false)
        #expect(hikeRecorder.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: journal.journalURL.path))
    }

    /// Whether the walker is standing still is derived state: a function of
    /// the points before this one, which the accumulator answers live and
    /// nothing persists. This says so from both ends — the recorder writes no
    /// verdict of its own onto the fixes it journals, and a replay of exactly
    /// those fixes reaches the verdict anyway, which is what every reader of
    /// it does after a recovery or a save.
    @Test("a stationary window is recomputed from the journal, not stored in it")
    func stationaryVerdictIsRecomputedFromTheJournal() async throws {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()

        // Ten seconds apart, so `maximumInterval` accepts every one of them,
        // and never more than eight metres from the first, so the
        // thirty-second window closes on less ground than
        // `stationaryNetDisplacement`.
        let fixCount = 6
        for step in 0..<fixCount {
            clock.advance(by: 10)
            source.deliver(
                fix(latitude: 47.63 + Double((step % 2) * 8) / 111_000)
            )
        }

        #expect(
            hikeRecorder.accumulator.isStationary,
            "precondition: the jitter has to have closed a stationary window"
        )

        let journal = TrackJournal(directory: directory)
        var session = try await journal.loadSession()
        let deadline = ContinuousClock.now + .seconds(5)
        while (session?.points.count ?? 0) < fixCount, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            session = try await journal.loadSession()
        }

        let flushed = try #require(session, "the fixes never reached the journal")
        #expect(flushed.points.count == fixCount)
        let carriesAFlag = flushed.points.contains { !$0.flags.isEmpty }
        #expect(
            !carriesAFlag,
            "the recorder wrote its own stationary verdict back onto the fixes"
        )

        var replay = RecordingDistanceAccumulator()
        for point in flushed.points { replay.append(point) }
        #expect(replay.isStationary)
        #expect(replay.distanceMeters == hikeRecorder.stats.distanceMeters)
    }
}
