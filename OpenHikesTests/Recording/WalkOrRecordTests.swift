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

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
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

    /// The permission prompt is the clearest of the waits a Start has before
    /// its draft exists; the precision sheet and the journal's first write
    /// are the others, and a recovery reading its journal back is a fourth.
    @Test("a recording still waiting for its draft holds a walk back, by hand or by matched fixes")
    func recordingWithoutADraftHoldsAWalkBack() async {
        let hikeRecorder = makeRecorder()
        let session = walkSession(asking: hikeRecorder)
        source.authorization = .notDetermined
        await hikeRecorder.start()
        #expect(hikeRecorder.isActive, "precondition: a recording under way")
        #expect(hikeRecorder.currentHike == nil, "precondition: with no draft yet")

        let walked = trail()
        let profile = RouteProfile(route: walked.route)
        #expect(!session.start(hike: walked, profile: profile))
        for point in 0...2 {
            clock.advance(by: 60)
            session.recordForegroundMatch(hike: walked, profile: profile, distance: profile.distances[point])
        }

        #expect(session.walkUnderWayTitle == nil)
        #expect(walked.walkInProgress == nil)
    }
}
