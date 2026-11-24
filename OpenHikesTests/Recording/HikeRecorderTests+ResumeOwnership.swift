//
//  HikeRecorderTests+ResumeOwnership.swift
//  OpenHikesTests
//
//  A Resume that is still waiting on the precision sheet when the hiker
//  discards or stops the walk, or starts another, and one asked for while a
//  Discard is still finishing (#1608).
//
//  Resume checked for a paused walk once, on the way in, and then woke from
//  the sheet and carried on: a refusal failed a recorder that was idle, and
//  a grant would have reopened a journal and started the GPS for a walk
//  that was gone. Resume's half of what `HikeRecorderTests+Activation` holds
//  for a Start (#967).
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

extension HikeRecorderTests {
    /// Where the paused walk took its fixes. Named because
    /// `no_magic_numbers` skips a `@Test` body and this is a helper.
    private static let pausedWalkStart = 47.63
    private static let pausedWalkEnd = 47.632
    private static let pausedWalkMinute: TimeInterval = 60

    /// A recorder with a walk paused two fixes in, and a Resume of it
    /// waiting on the precision sheet.
    private func resumeWaitingOnPrecision() async -> (recorder: HikeRecorder, resuming: Task<Void, Never>) {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()
        source.deliver(fix(latitude: Self.pausedWalkStart))
        clock.advance(by: Self.pausedWalkMinute)
        source.deliver(fix(latitude: Self.pausedWalkEnd))
        hikeRecorder.pause()
        source.hasFullAccuracy = false
        source.holdsFullAccuracyRequests = true
        let resuming = Task { await hikeRecorder.resume() }
        await settleDelegateHop(until: "Resume to ask for precise location") {
            self.source.fullAccuracyRequests == 1
        }
        return (hikeRecorder, resuming)
    }

    @Test(
        "Discard during Resume's precision prompt keeps the old Resume from failing or recording",
        arguments: [true, false]
    )
    func discardDuringResumePrompt(granted: Bool) async {
        let (hikeRecorder, resuming) = await resumeWaitingOnPrecision()
        let sensorStarts = source.startCount

        await hikeRecorder.discard()
        #expect(hikeRecorder.phase == .idle)
        source.answerFullAccuracyRequests(granted: granted)
        await resuming.value

        // Not `.failed(.preciseLocationRequired)`: a refusal answering a
        // Resume nobody wants any more has nothing left to fail.
        #expect(hikeRecorder.phase == .idle)
        #expect(hikeRecorder.sessionID == nil)
        #expect(!hikeRecorder.isActive)
        #expect(source.startCount == sensorStarts, "no GPS for a walk that was thrown away")
    }

    /// The same sheet is still up for the new walk's Start, so both wake to
    /// the one answer, and only the Start acts on it.
    @Test("a walk started after a discarded Resume records as itself")
    func newWalkAfterDiscardedResume() async throws {
        let (hikeRecorder, resuming) = await resumeWaitingOnPrecision()
        await hikeRecorder.discard()
        let sensorStarts = source.startCount

        let starting = Task { await hikeRecorder.start() }
        await settleDelegateHop(until: "the new Start to ask for precise location") {
            self.source.fullAccuracyRequests == 2
        }
        source.answerFullAccuracyRequests(granted: true)
        await resuming.value
        await starting.value

        let sessionID = try #require(hikeRecorder.sessionID)
        #expect(hikeRecorder.phase == .waitingForFix, "the new walk, not resumed into recording by the old Resume")
        #expect(hikeRecorder.currentHike?.id == sessionID)
        #expect(source.startCount == sensorStarts + 1)
    }

    @Test("Stop during Resume's precision prompt saves the walk, and the old Resume changes nothing")
    func stopDuringResumePrompt() async throws {
        let (hikeRecorder, resuming) = await resumeWaitingOnPrecision()

        let saved = try await hikeRecorder.stop()
        #expect(hikeRecorder.phase == .idle)
        source.answerFullAccuracyRequests(granted: false)
        await resuming.value

        #expect(hikeRecorder.phase == .idle)
        #expect(!hikeRecorder.isActive)
        let hikes = try ModelContext(container).fetch(FetchDescriptor<Hike>())
        #expect(hikes.map(\.id) == [saved.id])
    }

    /// Discard's phase stays paused across its waits, so a Resume from the
    /// bar, the panel or an intent found a paused walk of its own there, and
    /// started the GPS for it after the Discard had stopped it. The Discard
    /// then left the recorder idle with the GPS still on.
    @Test("a Resume asked for while a Discard is still finishing starts no GPS")
    func resumeDuringDiscard() async {
        let sharedStore = HeldFixReadSharedStateStore()
        let hikeRecorder = makeRecorder(sharedStateStore: sharedStore)
        await hikeRecorder.start()
        // The first fix asks the widget's store for its fixes, and the read
        // is held: the Discard below waits on it first.
        source.deliver(fix(latitude: Self.pausedWalkStart))
        clock.advance(by: Self.pausedWalkMinute)
        source.deliver(fix(latitude: Self.pausedWalkEnd))
        hikeRecorder.pause()
        await settleDelegateHop(until: "the pause to stop the GPS") { self.source.stopCount == 1 }
        let discarding = Task { await hikeRecorder.discard() }
        await settleDelegateHop(until: "Discard to stop the GPS before its first wait") {
            self.source.stopCount == 2
        }
        #expect(hikeRecorder.phase == .paused, "the Discard still waiting on the widget's fixes")
        let sensorStarts = source.startCount

        await hikeRecorder.resume()
        await sharedStore.releaseReads()
        await discarding.value

        #expect(hikeRecorder.phase == .idle)
        #expect(hikeRecorder.sessionID == nil)
        #expect(source.startCount == sensorStarts, "no GPS for a walk being thrown away")
    }

    /// The precondition the four above lean on: a Resume nobody interrupted
    /// still resumes once the sheet is answered.
    @Test("a Resume nothing interrupted resumes once precise location is granted")
    func uninterruptedResume() async {
        let (hikeRecorder, resuming) = await resumeWaitingOnPrecision()

        source.answerFullAccuracyRequests(granted: true)
        await resuming.value

        #expect(hikeRecorder.phase == .recording)
    }
}

/// A widget's store whose reads of its queued fixes wait until let go, which
/// holds a Discard in its first wait: the merge a fix started.
private actor HeldFixReadSharedStateStore: RecordingSharedStateStoring {
    private var heldReads: [CheckedContinuation<Void, Never>] = []
    private var holdsReads = true

    func save(_ snapshot: SharedRecordingSnapshot, reloadWidget: Bool) { /* no-op stub */ }

    func clear(sessionID: UUID?) { /* no-op stub */ }

    func pendingFixes(for sessionID: UUID) async -> [SharedRecordingFix] {
        if holdsReads {
            await withCheckedContinuation { continuation in
                heldReads.append(continuation)
            }
        }
        return []
    }

    func removePendingFixes(ids: Set<UUID>) { /* no-op stub */ }

    /// Answers every read held, and every read after, with no fixes.
    func releaseReads() {
        holdsReads = false
        let held = heldReads
        heldReads = []
        for continuation in held {
            continuation.resume()
        }
    }
}
