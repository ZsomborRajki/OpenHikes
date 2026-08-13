//
//  TileLoadGateTests.swift
//  OpenTrailsTests
//
//  The gate is the only thing standing between this app and the stall it was
//  written to prevent: every tile pipeline blocks a thread in Swift's small
//  cooperative pool, MapKit's own tile rendering competes for the same
//  threads, and the pool doesn't grow to absorb either.
//
//  It replaced two independent caps (the renderer's 4, the downloader's 5)
//  that between them allowed 9. What matters now is that the total really is
//  one number, and that a 4,000-tile download can't take the map's share of
//  it — so those are what's pinned here, rather than the numbers themselves.
//

import Foundation
@testable import OpenTrails
import Testing

@Suite("Tile load gate")
struct TileLoadGateTests {
    /// A gate of its own per test: `TileLoadGate.shared` is live in the host
    /// app, and a test that filled it would deadlock whatever else is drawing.
    private let gate = TileLoadGate()

    /// Holds `count` slots at `priority`, then hands them all back.
    private func holdSlots(_ count: Int, _ priority: TileLoadGate.Priority) async {
        for _ in 0..<count { await gate.acquire(priority) }
    }

    private func releaseSlots(_ count: Int, _ priority: TileLoadGate.Priority) async {
        for _ in 0..<count { await gate.release(priority) }
    }

    /// Waits until every spawned acquire has reached the actor and either
    /// entered or queued. Unlike a fixed sleep, this remains deterministic on
    /// a busy simulator.
    private func waitForAcquireAttempts(_ expected: Int) async -> TileLoadGate.TestState {
        while true {
            let state = await gate.testState
            let attempts = state.total + state.interactiveWaiters + state.backgroundWaiters
            if attempts == expected { return state }
            await Task.yield()
        }
    }

    /// The whole point: one number bounds everything, whoever asked.
    @Test("the total in flight never exceeds the budget, from either side")
    func totalIsBounded() async {
        let (total, background) = await gate.budgets

        await holdSlots(total - background, .interactive)
        await holdSlots(background, .background)

        let inFlight = await gate.inFlight
        #expect(inFlight.total == total, "the gate fills")

        // Nothing more may enter, from either side, until something leaves.
        let blocked = Task { await gate.acquire(.interactive) }
        let blockedState = await waitForAcquireAttempts(total + 1)
        #expect(blockedState.total == total, "an extra request waits rather than squeezing in")
        #expect(blockedState.interactiveWaiters == 1)

        await releaseSlots(1, .background)
        await blocked.value
        #expect(await gate.inFlight.total == total, "and takes the freed slot, not a new one")

        await releaseSlots(total - background, .interactive)
        await releaseSlots(background - 1, .background)
    }

    /// A bulk download is 4,000 tiles. If it could take the whole gate, the map
    /// would stop loading tiles for as long as the download ran — which is the
    /// failure the two old caps were each trying to prevent and neither could.
    @Test("a bulk download can never hold more than its share")
    func downloadCannotStarveTheMap() async {
        let (total, background) = await gate.budgets

        // Far more background work than the gate will admit at once.
        let waiting = (0..<(total + 4)).map { _ in
            Task { await gate.acquire(.background) }
        }

        let inFlight = await waitForAcquireAttempts(total + 4)
        #expect(inFlight.background == background, "the download saturates its own share")
        #expect(inFlight.total == background, "and takes nothing beyond it")
        #expect(total - inFlight.total > 0, "so the map always has slots left")
        #expect(inFlight.backgroundWaiters == total + 4 - background)

        // One release per acquire, which drains the queue and then empties the
        // gate — a release hands its slot to the next waiter rather than
        // counting itself out, so the two only balance if that bookkeeping is
        // right.
        for _ in 0..<(total + 4) {
            await gate.release(.background)
        }
        for task in waiting { await task.value }
        #expect(await gate.inFlight.total == 0)
    }

    /// The map is what the user is looking at, so a freed slot goes there
    /// first — otherwise a download queued ahead of it would still delay the
    /// tile on screen, just by a shorter queue.
    @Test("a freed slot goes to the map before the download")
    func interactiveWaitersAreServedFirst() async {
        let (total, background) = await gate.budgets

        // Fill the gate, leaving the download at its limit.
        await holdSlots(total - background, .interactive)
        await holdSlots(background, .background)

        // A background waiter queues first, an interactive one second.
        let backgroundWaiter = Task { await gate.acquire(.background) }
        let backgroundQueued = await waitForAcquireAttempts(total + 1)
        #expect(backgroundQueued.backgroundWaiters == 1)
        let interactiveWaiter = Task { await gate.acquire(.interactive) }
        let bothQueued = await waitForAcquireAttempts(total + 2)
        #expect(bothQueued.interactiveWaiters == 1)
        #expect(bothQueued.backgroundWaiters == 1)

        // One slot comes back. Despite queueing later, the map takes it —
        // awaiting it here is the assertion: this only returns if the gate
        // chose the interactive waiter over the background one ahead of it.
        await gate.release(.interactive)
        await interactiveWaiter.value

        let inFlight = await gate.inFlight
        #expect(inFlight.background == background, "the download is still at its share, not above it")
        #expect(inFlight.total == total, "and the gate is still full")

        // Drain, one release per holder.
        await gate.release(.background)
        await backgroundWaiter.value
        await releaseSlots(total - background, .interactive)
        await releaseSlots(background, .background)
        #expect(await gate.inFlight.total == 0)
    }

    /// Releasing hands the slot on rather than counting it out and back in, so
    /// the accounting can't drift over a long download.
    @Test("acquiring and releasing in balance leaves the gate empty")
    func accountingIsBalanced() async {
        for _ in 0..<50 {
            await gate.acquire(.interactive)
            await gate.acquire(.background)
            await gate.release(.background)
            await gate.release(.interactive)
        }
        let inFlight = await gate.inFlight
        #expect(inFlight.total == 0)
        #expect(inFlight.background == 0)
    }
}
