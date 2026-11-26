//
//  CommunityReviewQueueTests+Retry.swift
//  OpenHikesTests
//
//  The launch's one question, when the first asking answered nothing. A
//  reviewer who opened the Community tab with no connection had their read
//  fail, the launch counted it as asked, and the queue stayed empty until the
//  app was relaunched. Rows, the server's refusal or a signed-out device are
//  an answer; a failed read is not, and a later selection of the tab asks
//  again, after a wait.
//

import Foundation
@testable import OpenHikes
import Synchronization
import Testing

extension CommunityReviewQueueTests {
    @Test("a read that answered nothing is asked again on a later selection")
    func anUnansweredReadIsAskedAgain() async {
        let clock = TestClock()
        let transport = StubCommunityTransport()
        transport.pendingResult = .failure(.unreachable)
        let queue = CommunityReviewQueue(transport: transport, now: clock.read)
        queue.startBrowsing()
        await settle(queue)
        #expect(queue.pending.isEmpty, "and nothing was said about it")

        queue.stopBrowsing()
        transport.pendingResult = .success(.hikes([.stub(), .stub(id: "notice-2")]))
        clock.advance(by: CommunityReviewQueue.retryDelay)
        queue.startBrowsing()
        await settle(queue)

        #expect(transport.recording.queueRequests == 2)
        #expect(queue.pending.count == 2)
        #expect(queue.isReviewer)

        queue.stopBrowsing()
        queue.startBrowsing()
        await settle(queue)
        #expect(transport.recording.queueRequests == 2, "and now the launch has its answer")
    }

    /// Tapping between the segments in a valley must not ask on every tap.
    @Test("a selection inside the wait after a failure does not ask")
    func aSelectionInsideTheWaitDoesNotAsk() async {
        let clock = TestClock()
        let transport = StubCommunityTransport()
        transport.pendingResult = .failure(.unreachable)
        let queue = CommunityReviewQueue(transport: transport, now: clock.read)
        queue.startBrowsing()
        await settle(queue)

        clock.advance(by: CommunityReviewQueue.retryDelay - 1)
        queue.stopBrowsing()
        queue.startBrowsing()
        await settle(queue)
        #expect(transport.recording.queueRequests == 1)

        clock.advance(by: 1)
        queue.stopBrowsing()
        queue.startBrowsing()
        await settle(queue)
        #expect(transport.recording.queueRequests == 2)
    }

    /// Almost every launch: the server refuses, and that is the answer.
    @Test("a refusal is the launch's answer, however long it has been")
    func aRefusalIsAskedOnce() async {
        let clock = TestClock()
        let transport = StubCommunityTransport()
        transport.pendingResult = .failure(.notPermitted)
        let queue = CommunityReviewQueue(transport: transport, now: clock.read)
        queue.startBrowsing()
        await settle(queue)

        clock.advance(by: CommunityReviewQueue.retryDelay * 10)
        queue.stopBrowsing()
        queue.startBrowsing()
        await settle(queue)

        #expect(transport.recording.queueRequests == 1)
        #expect(!queue.isReviewer)
    }

    /// A phone with no account is not one the server can place in the role,
    /// and asking again would be told the same until the hiker signs in: the
    /// once-a-launch rule is for them as much as for a refused account.
    @Test("a signed-out device is the launch's answer too")
    func aSignedOutDeviceIsAskedOnce() async {
        let clock = TestClock()
        let transport = StubCommunityTransport()
        transport.pendingResult = .failure(.notSignedIn)
        let queue = CommunityReviewQueue(transport: transport, now: clock.read)
        queue.startBrowsing()
        await settle(queue)

        clock.advance(by: CommunityReviewQueue.retryDelay * 10)
        queue.stopBrowsing()
        queue.startBrowsing()
        await settle(queue)

        #expect(transport.recording.queueRequests == 1)
        #expect(queue.pending.isEmpty)
    }

    /// Leaving the tab cancels the read, and a cancelled read usually comes
    /// back as a failure. Taken for one, it held the hiker who came straight
    /// back behind the wait, for a read nobody was waiting for.
    @Test("a read abandoned on the way out holds no later selection back")
    func anAbandonedFailureHoldsNothingBack() async {
        let clock = TestClock()
        let transport = StubCommunityTransport()
        transport.pendingResult = .failure(.unreachable)
        let gate = AsyncGate()
        let returned = Mutex(false)
        transport.beforeQueueReturns = {
            await gate.wait()
            returned.withLock { $0 = true }
        }
        let queue = CommunityReviewQueue(transport: transport, now: clock.read)

        queue.startBrowsing()
        queue.stopBrowsing()
        await gate.open()
        await settleDelegateHop(until: "the abandoned read to come back") {
            returned.withLock { $0 }
        }
        // And its failure to reach the queue, behind it on the main actor.
        await settleDelegateHop()

        transport.pendingResult = .success(.hikes([.stub()]))
        queue.startBrowsing()
        await settle(queue)

        #expect(transport.recording.queueRequests == 2)
        #expect(queue.pending.count == 1)
    }
}
