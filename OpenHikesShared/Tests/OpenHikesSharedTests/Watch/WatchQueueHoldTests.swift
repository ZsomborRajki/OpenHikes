//
//  WatchQueueHoldTests.swift
//  OpenHikesSharedTests
//
//  Which queued walks the watch's drain leaves unsent while its recorder may
//  still replace them (#1572). Each change is one the recorder's phases make,
//  with the hold `WatchRecorder.Phase.queueHold(recording:)` names for each.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Which queued walks the watch's recorder holds back from the phone")
struct WatchQueueHoldTests {
    @Test("no hold keeps back no walk")
    func nothingHoldsNothing() {
        #expect(!WatchQueueHold.nothing.holds(UUID()))
    }

    @Test("a journal still being read keeps back every walk")
    func everythingHoldsEveryWalk() {
        #expect(WatchQueueHold.everything.holds(UUID()))
    }

    @Test("a held session keeps back its own walk and no other")
    func sessionHoldsOnlyItself() {
        let held = UUID()
        #expect(WatchQueueHold.session(held).holds(held))
        #expect(!WatchQueueHold.session(held).holds(UUID()))
    }

    @Test("the journal's answer releases the queue, an offer bar its own walk")
    func checkAnswering() {
        // No journal, or one whose walk already went: idle.
        #expect(WatchQueueHold.everything.releases(into: .nothing))
        // An offer: the recorder holds the journal's session.
        #expect(WatchQueueHold.everything.releases(into: .session(UUID())))
    }

    @Test("an interrupted walk carried on stays held until Stop has saved it")
    func continueThenStop() {
        let journal = UUID()
        let offered = WatchQueueHold.session(journal)
        // Continue, recording, paused, saving, or a refused permission back
        // to the choice: every phase between names the same session, so no
        // drain sends the queued copy the walk carried on from.
        #expect(!offered.releases(into: .session(journal)))
        // Stop's walk is on the queue in place of the copy, and goes.
        #expect(offered.releases(into: .nothing))
    }

    @Test("an interrupted walk discarded lets its queued copy go")
    func discard() {
        let journal = UUID()
        #expect(WatchQueueHold.session(journal).releases(into: .nothing))
        #expect(!WatchQueueHold.nothing.holds(journal))
    }

    @Test("a hold that grows or starts holds releases nothing")
    func tighteningReleasesNothing() {
        let held = UUID()
        #expect(!WatchQueueHold.everything.releases(into: .everything))
        #expect(!WatchQueueHold.session(held).releases(into: .everything))
        #expect(!WatchQueueHold.nothing.releases(into: .session(held)))
        #expect(!WatchQueueHold.nothing.releases(into: .nothing))
    }

    @Test("a hold that moves to another session releases the one it held")
    func movingToAnotherSession() {
        #expect(WatchQueueHold.session(UUID()).releases(into: .session(UUID())))
    }
}
