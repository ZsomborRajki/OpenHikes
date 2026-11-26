//
//  WalkOrRecordTests.swift
//  OpenHikesTests
//
//  A hiker walks a trail or records one, never both, held with a real
//  recorder and a real walk session rather than with closures standing in for
//  them: the gaps were where the two met.
//
//  The first was the recording screen's own Start (#1310). A row carrying
//  another device's draft opens that screen on this phone's idle recorder, and
//  its Start asked the recorder directly, beside a walk the hiker had paused.
//  It now goes through ``RecordingEntry``, which is what MapSheet hands it;
//  the card is SwiftUI, so this holds the path it takes rather than the tap.
//
//  The second was the walk session asking whether a draft exists, where the
//  reminder controller asks whether a recording is under way: a recording
//  waiting on its permission prompt is the second without the first.
//
//  And one place the two do meet, on purpose: a hiker who left the trail they
//  were walking and said to record instead. The walk still ends before the
//  recording begins, and what it covered goes with it — or, when that start
//  fails, waits on the recorder for the recording screen's Start, until
//  anything else starts.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import RealModule
import SwiftData
import Testing

@Suite("Walk or record")
final class WalkOrRecordTests {
    private let container: ModelContainer
    private let source = StubRecordingLocationSource()
    private let clock = TestClock()
    private let journalDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("walk-or-record-\(UUID().uuidString)", isDirectory: true)
    // periphery:ignore - the strong reference that keeps the recorder alive
    // for the length of the test; never read back.
    private var recorder: HikeRecorder?

    init() throws {
        container = try Fixture.modelContainer()
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: journalDirectory)
    }

    private var context: ModelContext { container.mainContext }

    private func makeRecorder() -> HikeRecorder {
        let instance = HikeRecorder(
            container: container,
            source: source,
            defaults: UserDefaults(suiteName: "walk-or-record-\(UUID().uuidString)") ?? .standard,
            // Never the process-wide monitor in a test: it would assert
            // against the machine's battery rather than against the policy.
            powerMonitor: PowerStateMonitor(read: { PowerState() }, observesNotifications: false),
            journalDirectory: journalDirectory,
            clock: clock.read,
            journalFlushDelay: .zero,
            automaticallyRecovers: false
        )
        recorder = instance
        return instance
    }

    /// Asking the recorder what `OpenHikesModel.makeWalkSession` has it ask,
    /// without the widget feed and the weather, which these walks do not need.
    private func walkSession(asking authority: HikeRecorder) -> TrailWalkSession {
        let session = TrailWalkSession(context: context, clock: clock.read) { [weak authority] in
            authority?.currentHike?.id
        }
        session.hasActiveRecording = { [weak authority] in authority?.isActive ?? false }
        session.walkDidStart = { [weak authority] in authority?.letGoOfUnclaimedWalk() }
        return session
    }

    private func trail() -> Hike {
        Fixture.hike(in: context, title: "Ridge Loop", route: Fixture.outAndBackRoute)
    }

    @Test("a draft from another device opens the recording screen idle, and its Start ends a paused walk first")
    func mirroredDraftStartEndsTheWalkFirst() async throws {
        let hikeRecorder = makeRecorder()
        let session = walkSession(asking: hikeRecorder)
        let requests = HikeOpenRequests()
        let sent = FeedReader(requests.links())
        let entry = RecordingEntry(recorder: hikeRecorder, walkSession: session, openRequests: requests)
        let walked = trail()
        #expect(session.start(hike: walked, profile: RouteProfile(route: walked.route)))
        #expect(session.pause())
        let draft = Fixture.hike(in: context, title: "Another phone's recording") { $0.isRecording = true }
        try context.save()

        // The row opens the recording screen — `MapSheet.open(_:)` asks this —
        // on a recorder with nothing to show but the card's idle Start.
        #expect(draft.belongsToActiveRecording(currentHikeID: hikeRecorder.currentHike?.id))
        #expect(hikeRecorder.phase == .idle)

        // That Start asks before it records, as the map's button does: this
        // is what has the card draw its menu rather than a button.
        #expect(entry.walkToEnd == walked.displayTitle)

        // End Hike and Record: the walk is over before anything records.
        entry.endWalkAndRecord()
        #expect(session.walkUnderWayTitle == nil)
        await settleDelegateHop(until: "the recording's screen to be asked for") { sent.received.count == 1 }

        #expect(hikeRecorder.isActive)
        let started = try #require(hikeRecorder.currentHike)
        #expect(started.id != draft.id, "a recording of this phone's own, not the other's draft")
        #expect(sent.received.last == TrailWidgetDeepLink.recordingURL())
        #expect(!entry.walkEndRefused)
    }

    @Test("recording instead of a walk ends it into the trail's History and begins the recording with it")
    func recordInsteadCarriesTheWalkIntoTheRecording() async throws {
        let hikeRecorder = makeRecorder()
        let session = walkSession(asking: hikeRecorder)
        let requests = HikeOpenRequests()
        let sent = FeedReader(requests.links())
        let entry = RecordingEntry(recorder: hikeRecorder, walkSession: session, openRequests: requests)
        let walked = trail()
        let profile = RouteProfile(route: walked.route)
        #expect(session.start(hike: walked, profile: profile))
        let startedAt = clock.now
        for point in 0...6 {
            clock.advance(by: 60)
            session.recordForegroundMatch(hike: walked, profile: profile, distance: profile.distances[point])
        }
        // Off the trail for a while before saying so.
        clock.advance(by: 180)

        entry.recordInsteadOfWalk()
        await settleDelegateHop(until: "the recording's screen to be asked for") { sent.received.count == 1 }

        #expect(session.walkUnderWayTitle == nil, "the walk is over")
        #expect(walked.walks?.count == 1, "and kept, as an End keeps it")
        #expect(hikeRecorder.isActive)
        let draft = try #require(hikeRecorder.currentHike)
        #expect(draft.id != walked.id, "a hike of its own, not the trail")
        #expect(hikeRecorder.sessionStartedAt == startedAt, "that began when the walk did")
        #expect(hikeRecorder.stats.pointCount > 1)
        #expect(hikeRecorder.stats.distanceMeters.isApproximatelyEqual(to: profile.distances[6], absoluteTolerance: 2))
        #expect(!entry.walkEndRefused)
    }

    /// A walk too short for its trail's History is in no row once it has
    /// ended, so a handoff whose start fails keeps it, and the recording
    /// screen's Start, where the failure was explained, begins with it.
    @Test("a short walk handed to a start that fails is kept for the recording screen's Start")
    func aShortWalkSurvivesAFailedStart() async throws {
        let hikeRecorder = makeRecorder()
        let session = walkSession(asking: hikeRecorder)
        let requests = HikeOpenRequests()
        let sent = FeedReader(requests.links())
        let entry = RecordingEntry(recorder: hikeRecorder, walkSession: session, openRequests: requests)
        let walked = trail()
        let profile = RouteProfile(route: walked.route)
        #expect(session.start(hike: walked, profile: profile))
        for point in 0...1 {
            clock.advance(by: 60)
            session.recordForegroundMatch(hike: walked, profile: profile, distance: profile.distances[point])
        }
        clock.advance(by: 180)
        source.hasFullAccuracy = false

        entry.recordInsteadOfWalk()
        await settleDelegateHop(until: "the recording's screen to be asked for") { sent.received.count == 1 }
        #expect(hikeRecorder.phase == .failed(.preciseLocationRequired))
        #expect(session.walkUnderWayTitle == nil, "the walk is over")
        #expect(walked.walks?.isEmpty != false, "precondition: too short for the History")
        let kept = try #require(hikeRecorder.unclaimedSeed)

        hikeRecorder.dismissFailure()
        source.hasFullAccuracy = true
        entry.startOnRecordingScreen()
        await settleDelegateHop(until: "the screen's Start to be asked for") { sent.received.count == 2 }

        #expect(hikeRecorder.isActive)
        #expect(hikeRecorder.sessionStartedAt == kept.startedAt)
        #expect(hikeRecorder.stats.pointCount == kept.points.count)
    }

    /// A walk adopted at launch reads its line to be handed over. A read that
    /// fails ends nothing: the walk is still under way, nothing records
    /// beside it, and its question is asked again, saying so, for the hiker
    /// to try again — the map's refused End would advise an End, which
    /// carries nothing.
    @Test("a walk whose line cannot be read starts no recording, and asks again")
    func unreadableLineStartsNothing() async {
        let hikeRecorder = makeRecorder()
        let walked = trail()
        let profile = RouteProfile(route: walked.route)
        let opening = walkSession(asking: hikeRecorder)
        #expect(opening.start(hike: walked, profile: profile))
        for point in 0...6 {
            clock.advance(by: 60)
            opening.recordForegroundMatch(hike: walked, profile: profile, distance: profile.distances[point])
        }
        let session = walkSession(asking: hikeRecorder)
        session.restoreAtLaunch()
        await session.lineCheck?.value
        session.lineLooks.fetch = FailingLineFetch(failing: [1]).fetch
        let entry = RecordingEntry(recorder: hikeRecorder, walkSession: session, openRequests: HikeOpenRequests())

        session.withdrawOffTrailQuestion()
        entry.recordInsteadOfWalk()
        await settleDelegateHop(until: "the question to be asked again") { session.offTrailQuestion != nil }

        #expect(session.offTrailQuestion?.handOffFailed == true)
        #expect(!entry.walkEndRefused)
        #expect(!hikeRecorder.isActive)
        #expect(session.walkUnderWayTitle == walked.displayTitle)
        #expect(walked.walks?.isEmpty != false)
    }

    /// The walk is in its trail's History and its ground is in the recording,
    /// and the library's totals count a walk for whatever part of its time
    /// no recording's clock covers. So the recording's clock has to cover
    /// the walk's to the instant — here with the recording stopped before a
    /// fix of its own, which leaves the carried points as the whole of it.
    @Test("the ground handed to a recording is counted once in the library, not once more as the walk")
    func aHandedOverWalkIsCountedOnce() async throws {
        let hikeRecorder = makeRecorder()
        let session = walkSession(asking: hikeRecorder)
        let requests = HikeOpenRequests()
        let sent = FeedReader(requests.links())
        let entry = RecordingEntry(recorder: hikeRecorder, walkSession: session, openRequests: requests)
        let walked = trail()
        let profile = RouteProfile(route: walked.route)
        #expect(session.start(hike: walked, profile: profile))
        for point in 0...6 {
            // Not a whole number of seconds, so the sums have ulps to lose.
            clock.advance(by: 61.3)
            session.recordForegroundMatch(hike: walked, profile: profile, distance: profile.distances[point])
        }
        // And a long lunch, which the carried points wait out before they
        // set off: more to add up, and more to lose in the adding.
        #expect(session.pause())
        clock.advance(by: 3 * 3600 + 0.7)
        #expect(session.resume())
        clock.advance(by: 180)
        entry.recordInsteadOfWalk()
        await settleDelegateHop(until: "the recording's screen to be asked for") { sent.received.count == 1 }
        #expect(walked.walks?.count == 1, "precondition: the walk was kept")

        let recording = try await hikeRecorder.stop()

        let library = try await LibraryTotalsSweep.outings(from: container)
        #expect(library.outings.map(\.hikeID) == [recording.id])
        #expect(library.outings.allSatisfy { !$0.isWalk })
    }

    /// A recorder that has been asked to start and is waiting on its
    /// permission prompt, the clearest of the waits a Start has before its
    /// draft exists; the precision sheet and the journal's first write are the
    /// others, and a recovery reading its journal back is a fourth.
    private func recordingWithoutADraft() async -> HikeRecorder {
        let hikeRecorder = makeRecorder()
        source.authorization = .notDetermined
        await hikeRecorder.start()
        #expect(hikeRecorder.isActive, "precondition: a recording under way")
        #expect(hikeRecorder.currentHike == nil, "precondition: with no draft yet")
        return hikeRecorder
    }

    @Test("a recording still waiting for its draft holds back a walk started by hand")
    func recordingWithoutADraftRefusesAStartByHand() async {
        let session = walkSession(asking: await recordingWithoutADraft())
        let walked = trail()

        #expect(!session.start(hike: walked, profile: RouteProfile(route: walked.route)))
        #expect(session.walkUnderWayTitle == nil)
        #expect(walked.walkInProgress == nil)
    }

    /// The fixes that start a walk with nothing recording — see
    /// ``PendingWalkStart`` — start none while a recording waits.
    @Test("a recording still waiting for its draft holds back a walk matched fixes would start")
    func recordingWithoutADraftRefusesAStartByFixes() async {
        let session = walkSession(asking: await recordingWithoutADraft())
        let walked = trail()
        let profile = RouteProfile(route: walked.route)

        for point in 0...2 {
            clock.advance(by: 60)
            session.recordForegroundMatch(hike: walked, profile: profile, distance: profile.distances[point])
        }

        #expect(session.walkUnderWayTitle == nil)
        #expect(walked.walkInProgress == nil)
    }

    /// The suites above hand their session the recorder's answer themselves;
    /// this holds the composition root to handing over the same one.
    @Test("the app's walk session asks the recorder whether a recording is under way")
    func composedSessionAsksTheRecorder() async throws {
        let hikeRecorder = makeRecorder()
        let session = OpenHikesModel.makeWalkSession(
            container,
            BackgroundTrailTracker(
                container: container,
                monitor: StubLocationMonitor(),
                regionMonitor: FakeTrailRegionMonitor(),
                defaults: try makeScratchDefaults()
            ),
            nil,
            hikeRecorder,
            WeatherManager(widgetPublisher: .inert)
        )
        #expect(!session.isRecording, "precondition: nothing recording")

        source.authorization = .notDetermined
        await hikeRecorder.start()
        #expect(hikeRecorder.currentHike == nil, "precondition: with no draft yet")

        #expect(session.isRecording)
    }
}

// MARK: - A handoff whose start failed

extension WalkOrRecordTests {
    /// What the walk under way covered when the hiker said to record instead
    /// and the start was refused precise location: the walk over, and the
    /// recorder keeping what it covered for the recording screen's Start.
    private func failedHandoff(
        _ hikeRecorder: HikeRecorder,
        session: TrailWalkSession,
        entry: RecordingEntry,
        sent: FeedReader<URL>
    ) async throws -> RecordingSeed {
        let walked = trail()
        let profile = RouteProfile(route: walked.route)
        #expect(session.start(hike: walked, profile: profile))
        for point in 0...6 {
            clock.advance(by: 60)
            session.recordForegroundMatch(hike: walked, profile: profile, distance: profile.distances[point])
        }
        clock.advance(by: 180)
        source.hasFullAccuracy = false
        let asked = sent.received.count
        entry.recordInsteadOfWalk()
        await settleDelegateHop(until: "the recording's screen to be asked for") { sent.received.count == asked + 1 }
        #expect(hikeRecorder.phase == .failed(.preciseLocationRequired))
        // The alert answered, as its OK does.
        hikeRecorder.dismissFailure()
        source.hasFullAccuracy = true
        return try #require(hikeRecorder.unclaimedSeed, "precondition: kept for the retry")
    }

    /// A retry is clocked from the first walk's start, so one made after
    /// another walk would cover that walk too: the library leaves out a walk
    /// inside a counted hike's clock, and its ground would be in no
    /// recording. So a walk that starts lets the first one go.
    @Test("a walk started after a failed handoff lets its walk go, and the screen's Start begins afresh")
    func aLaterWalkLetsAFailedHandoffGo() async throws {
        let hikeRecorder = makeRecorder()
        let session = walkSession(asking: hikeRecorder)
        let requests = HikeOpenRequests()
        let sent = FeedReader(requests.links())
        let entry = RecordingEntry(recorder: hikeRecorder, walkSession: session, openRequests: requests)
        _ = try await failedHandoff(hikeRecorder, session: session, entry: entry, sent: sent)

        let next = trail()
        let profile = RouteProfile(route: next.route)
        #expect(session.start(hike: next, profile: profile))
        #expect(hikeRecorder.unclaimedSeed == nil, "let go of as the next walk started")
        for point in 0...6 {
            clock.advance(by: 60)
            session.recordForegroundMatch(hike: next, profile: profile, distance: profile.distances[point])
        }
        session.end()
        #expect(next.walks?.count == 1, "precondition: the next walk is in its trail's History")

        entry.startOnRecordingScreen()
        await settleDelegateHop(until: "the screen's Start to be asked for") { sent.received.count == 2 }

        #expect(hikeRecorder.isActive)
        #expect(hikeRecorder.sessionStartedAt == clock.now, "a recording of its own, from now")
        #expect(hikeRecorder.stats.pointCount == 0)
    }

    /// A row carrying another device's draft opens the recording screen on
    /// this phone's idle recorder — `MapSheet.openRecording()` asks this as
    /// it does — and the screen is up for that row, not for the handoff.
    @Test("the recording screen a draft's row opens begins afresh, not with a failed handoff's walk")
    func aRowsRecordingScreenBeginsAfresh() async throws {
        let hikeRecorder = makeRecorder()
        let session = walkSession(asking: hikeRecorder)
        let requests = HikeOpenRequests()
        let sent = FeedReader(requests.links())
        let entry = RecordingEntry(recorder: hikeRecorder, walkSession: session, openRequests: requests)
        _ = try await failedHandoff(hikeRecorder, session: session, entry: entry, sent: sent)

        hikeRecorder.letGoOfUnclaimedWalk()
        entry.startOnRecordingScreen()
        await settleDelegateHop(until: "the screen's Start to be asked for") { sent.received.count == 2 }

        #expect(hikeRecorder.isActive)
        #expect(hikeRecorder.sessionStartedAt == clock.now)
        #expect(hikeRecorder.stats.pointCount == 0)
    }

    /// The suites above hand their session the recorder's hook themselves;
    /// this holds the model, which joins the two, to handing over the same
    /// one.
    @Test("the app's model has a walk that starts let go of a failed handoff's walk")
    func theModelLetsAFailedHandoffGoWhenAWalkStarts() async throws {
        let hikeRecorder = makeRecorder()
        let tiles = TileSandbox()
        let model = OpenHikesModel(
            container: container,
            backgroundTracker: BackgroundTrailTracker(
                container: container,
                monitor: StubLocationMonitor(),
                regionMonitor: FakeTrailRegionMonitor(),
                defaults: try makeScratchDefaults()
            ),
            autoSaveController: AutoSaveController(store: tiles.store, drainInterval: nil),
            hikeRecorder: hikeRecorder,
            locationManager: LocationManager(),
            weatherManager: WeatherManager(widgetPublisher: .inert),
            significantLocations: SignificantLocationFeed(monitor: DormantLocationSource()),
            defaults: try makeScratchDefaults()
        )
        let point = RecordingPoint(
            latitude: 47.63,
            longitude: 12.86,
            timestamp: clock.now.addingTimeInterval(-60),
            horizontalAccuracy: RecordingSeed.carriedAccuracyMeters
        )
        source.hasFullAccuracy = false
        await hikeRecorder.start(carrying: RecordingSeed(startedAt: point.timestamp, points: [point]))
        try #require(hikeRecorder.unclaimedSeed != nil, "precondition: kept for the retry")

        model.walkSession.walkDidStart()

        #expect(hikeRecorder.unclaimedSeed == nil)
        withExtendedLifetime(tiles) { /* the model's tile store, until here */ }
    }
}
