//
//  HikeRecorderTests+Activation.swift
//  OpenHikesTests
//
//  A Start that is still waiting — on the precision sheet, or on the journal
//  it is creating — when the hiker discards it (#967).
//
//  Discard ran to `.idle`, and then the old Start woke up and carried on: it
//  wrote a journal, inserted a draft and turned the GPS back on, so a
//  recording the hiker had thrown away came back by itself. The recording
//  controls are independent surfaces (the app, the Live Activity, Control
//  Center, Siri and the watch), so a Discard arriving in the middle of a Start
//  is an ordinary interleaving rather than a contrived one.
//

import CoreLocation
import Dispatch
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Synchronization
import Testing

/// Opens the journal's file only once the test lets it, so a suite can act
/// while `TrackJournal.start` is part-way through.
///
/// It blocks the journal actor's thread rather than suspending, because the
/// opener is synchronous by contract. The wait is bounded so that a test which
/// fails before ``letThrough()`` leaves no thread parked for the rest of the
/// run.
nonisolated private final class HeldJournalOpen: Sendable {
    private let entered = Mutex(false)
    private let release = DispatchSemaphore(value: 0)

    var hasEntered: Bool { entered.withLock { $0 } }

    func open(_ url: URL) throws -> any TrackJournalHandle {
        entered.withLock { $0 = true }
        _ = release.wait(timeout: .now() + 30)
        return try FileHandle(forWritingTo: url)
    }

    func letThrough() {
        release.signal()
    }
}

extension HikeRecorderTests {
    private var journalFiles: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("recording.") }
    }

    private func savedHikes() throws -> [Hike] {
        try ModelContext(container).fetch(FetchDescriptor<Hike>())
    }

    @Test(
        "Discard during the precision prompt keeps the old Start from recording",
        arguments: [true, false]
    )
    func discardDuringPrecisionPrompt(granted: Bool) async throws {
        source.hasFullAccuracy = false
        source.holdsFullAccuracyRequests = true
        let hikeRecorder = makeRecorder()
        let starting = Task { await hikeRecorder.start() }
        await settleDelegateHop(until: "Start to ask for precise location") {
            self.source.fullAccuracyRequests == 1
        }

        await hikeRecorder.discard()
        #expect(hikeRecorder.phase == .idle)
        source.answerFullAccuracyRequests(granted: granted)
        await starting.value

        // Not `.failed(.preciseLocationRequired)` either: a refusal answering
        // a Start nobody wants any more has nothing left to fail.
        #expect(hikeRecorder.phase == .idle)
        #expect(hikeRecorder.sessionID == nil)
        #expect(!hikeRecorder.isActive)
        #expect(source.startCount == 0)
        #expect(journalFiles.isEmpty)
        #expect(try savedHikes().isEmpty)
    }

    @Test("a fresh Start after an abandoned one records once, as itself")
    func freshStartAfterAbandonedActivation() async throws {
        source.hasFullAccuracy = false
        source.holdsFullAccuracyRequests = true
        let hikeRecorder = makeRecorder()
        let abandoned = Task { await hikeRecorder.start() }
        await settleDelegateHop(until: "the first Start to ask for precise location") {
            self.source.fullAccuracyRequests == 1
        }
        await hikeRecorder.discard()

        // The same sheet is still up, so the new Start waits on it as well,
        // and both wake to the one answer.
        let fresh = Task { await hikeRecorder.start() }
        await settleDelegateHop(until: "the second Start to ask for precise location") {
            self.source.fullAccuracyRequests == 2
        }
        source.answerFullAccuracyRequests(granted: true)
        await abandoned.value
        await fresh.value

        let sessionID = try #require(hikeRecorder.sessionID)
        #expect(hikeRecorder.phase == .waitingForFix)
        #expect(source.startCount == 1)
        #expect(hikeRecorder.currentHike?.id == sessionID)
        #expect(try savedHikes().map(\.id) == [sessionID])
        let journal = TrackJournal(directory: directory, clock: clock.read)
        let session = try #require(try await journal.loadSession())
        #expect(session.metadata.sessionID == sessionID)
    }

    @Test("Discard while the journal is being created leaves no journal, draft or GPS")
    func discardDuringJournalStartup() async throws {
        let gate = HeldJournalOpen()
        defer { gate.letThrough() }
        let hikeRecorder = makeRecorder(openJournalHandle: gate.open)
        let starting = Task { await hikeRecorder.start() }
        await settleDelegateHop(until: "Start to begin writing its journal") {
            gate.hasEntered
        }

        let discarding = Task { await hikeRecorder.discard() }
        await settleDelegateHop(until: "Discard to stop the sensors") {
            self.source.stopCount == 1
        }
        gate.letThrough()
        await starting.value
        await discarding.value

        #expect(hikeRecorder.phase == .idle)
        #expect(hikeRecorder.sessionID == nil)
        #expect(source.startCount == 0)
        #expect(journalFiles.isEmpty)
        #expect(try savedHikes().isEmpty)
    }

    @Test("the precision answer cannot begin a new Start while a Discard is still finishing")
    func authorizationCallbackDuringDiscard() async throws {
        source.hasFullAccuracy = false
        source.holdsFullAccuracyRequests = true
        let sharedStore = BlockingClearRecordingSharedStateStore()
        let hikeRecorder = makeRecorder(sharedStateStore: sharedStore)
        let abandoned = Task { await hikeRecorder.start() }
        await settleDelegateHop(until: "Start to ask for precise location") {
            self.source.fullAccuracyRequests == 1
        }
        // Held in its last wait, past the journal and before `resetSession()`.
        let discarding = Task { await hikeRecorder.discard() }
        await sharedStore.waitForClearToStart()

        // One answer, two deliveries: the request returns, and Core Location
        // reports the changed accuracy to the delegate.
        source.answerFullAccuracyRequests(granted: true)
        await abandoned.value
        hikeRecorder.locationManagerDidChangeAuthorization(CLLocationManager())
        // Barriers rather than a condition, because the effect being ruled
        // out has no counterpart when the fix holds. The round trip runs the
        // callback's hop; were it to begin an activation, that activation is
        // then queued on the journal ahead of this read, and is back on the
        // main actor — drafting and starting the GPS — before the read is.
        await settleDelegateHop()
        _ = try await hikeRecorder.journal?.loadSession()

        await sharedStore.releaseClear()
        await discarding.value

        #expect(hikeRecorder.phase == .idle)
        #expect(hikeRecorder.sessionID == nil)
        #expect(source.startCount == 0)
        #expect(journalFiles.isEmpty)
        #expect(try savedHikes().isEmpty)
    }
}
