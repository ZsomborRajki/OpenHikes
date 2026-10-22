//
//  CommunitySendPhaseTests.swift
//  OpenHikesTests
//
//  Where a send form stands after an attempt, and which controls that disables.
//
//  Both send forms read these three questions off ``CommunitySendPhase`` and
//  neither answers them itself, so the pair of mistakes this suite exists to
//  catch are the same ones in either screen: an upload that reached the public
//  database being drawn as a failure — which is what invited the second copy —
//  and a request that is in flight leaving its controls live.
//

@testable import OpenHikes
import Testing

@MainActor
@Suite("Community send phase")
struct CommunitySendPhaseTests {
    @Test("an accepted send ends the trip")
    func submittedIsSent() {
        #expect(CommunitySendPhase(.submitted) == .sent)
    }

    @Test("a refused send is something to say")
    func refusedIsFailed() {
        #expect(CommunitySendPhase(.refused(.unreachable)) == .failed(.unreachable))
    }

    /// The reported bug in one line. An upload whose notice failed is not a
    /// failure — the route is out there — and drawing it as one is what sent it
    /// twice.
    @Test("an upload that is out but not queued is its own state, not a failure")
    func uploadedNotQueuedIsAwaitingQueue() {
        let phase = CommunitySendPhase(.uploadedNotQueued(.unreachable))

        #expect(phase == .awaitingQueue(.unreachable))
        #expect(phase != .failed(.unreachable))
    }

    /// Everything on both forms disables itself against this, and the notice
    /// of an earlier upload is a hiker waiting on the network exactly as an
    /// upload is.
    @Test("a notice being sent holds the form as an upload does")
    func finishingAndSendingAreInFlight() {
        #expect(CommunitySendPhase.sending.isSending)
        #expect(CommunitySendPhase.finishing.isSending)
        #expect(!CommunitySendPhase.editing.isSending)
        #expect(!CommunitySendPhase.sent.isSending)
        #expect(!CommunitySendPhase.failed(.unreachable).isSending)
        #expect(!CommunitySendPhase.awaitingQueue(nil).isSending)
        #expect(!CommunitySendPhase.awaitingQueue(.unreachable).isSending)
    }

    /// Cancel becomes Done when there are no fields left to cancel. An upload
    /// waiting on its notice has none: they were sent. A notice in flight is
    /// still a request, not an outcome.
    @Test("an upload waiting for its notice has nothing left to cancel")
    func awaitingQueueHasFinished() {
        #expect(CommunitySendPhase.sent.hasFinished)
        #expect(CommunitySendPhase.awaitingQueue(nil).hasFinished)
        #expect(CommunitySendPhase.awaitingQueue(.unreachable).hasFinished)
        #expect(!CommunitySendPhase.editing.hasFinished)
        #expect(!CommunitySendPhase.sending.hasFinished)
        #expect(!CommunitySendPhase.finishing.hasFinished)
        #expect(!CommunitySendPhase.failed(.unreachable).hasFinished)
    }
}
