//
//  CommunityReviewQueueTests+Retry.swift
//  OpenHikesTests
//
//  The launch's one question, when the first asking answered nothing. A
//  reviewer who opened the Community tab with no connection had their read
//  fail, the launch counted it as asked, and the queue stayed empty until the
//  app was relaunched. Rows or the server's refusal are an answer; a failed
//  read is not, and a later selection of the tab asks again, after a wait.
//

import Foundation
@testable import OpenHikes
import Testing

extension CommunityReviewQueueTests {
    private func settled(_ queue: CommunityReviewQueue) async {
        while queue.isLoading {
            await Task.yield()
        }
    }

    @Test("a read that answered nothing is asked again on a later selection")
    func anUnansweredReadIsAskedAgain() async {
        let clock = TestClock()
        let transport = StubCommunityTransport()
        transport.pendingResult = .failure(.unreachable)
        let queue = CommunityReviewQueue(transport: transport, now: clock.read)
        queue.startBrowsing()
        await settled(queue)
        #expect(queue.pending.isEmpty, "and nothing was said about it")

        queue.stopBrowsing()
        transport.pendingResult = .success(.hikes([.stub(), .stub(id: "notice-2")]))
        clock.advance(by: CommunityReviewQueue.retryDelay)
        queue.startBrowsing()
        await settled(queue)

        #expect(transport.recording.queueRequests == 2)
        #expect(queue.pending.count == 2)
        #expect(queue.isReviewer)

        queue.stopBrowsing()
        queue.startBrowsing()
        await settled(queue)
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
        await settled(queue)

        clock.advance(by: CommunityReviewQueue.retryDelay - 1)
        queue.stopBrowsing()
        queue.startBrowsing()
        await settled(queue)
        #expect(transport.recording.queueRequests == 1)

        clock.advance(by: 1)
        queue.stopBrowsing()
        queue.startBrowsing()
        await settled(queue)
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
        await settled(queue)

        clock.advance(by: CommunityReviewQueue.retryDelay * 10)
        queue.stopBrowsing()
        queue.startBrowsing()
        await settled(queue)

        #expect(transport.recording.queueRequests == 1)
        #expect(!queue.isReviewer)
    }
}
