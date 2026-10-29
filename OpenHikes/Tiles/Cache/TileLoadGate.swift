//
//  TileLoadGate.swift
//  OpenHikes
//
//  One admission gate for the map's tile loads and the bulk downloader's.
//
//  There used to be two, which is the problem this file exists to fix: the
//  renderer capped on-screen tile loads at 4, the bulk downloader
//  independently capped its own fetches at 5, and neither knew about the
//  other — so a download running while the map was being panned could have 9
//  pipelines under way at once, with 9 requests open and their disk work
//  queued for Swift's small cooperative pool, which is the exact jam the
//  renderer's cap was written to prevent.
//

import DequeModule
import Foundation

/// Bounds how many tile pipelines (network fetch, disk reads and writes, and —
/// via ``AutoSaveTileStore`` — a file move into durable storage) are under way
/// at once, across both callers.
///
/// A slot is held for the whole pipeline, but a thread only for part of it.
/// The request is an `await` on `URLSession`, which suspends the pipeline and
/// gives its thread back for as long as the server takes, and a second caller
/// after the same tile awaits that request rather than making its own. What
/// does hold a thread is the synchronous work around the request — the disk
/// lookup, the image decode, the file write or move — which runs on Swift's
/// cooperative pool. The pool is sized to the CPU and doesn't grow to absorb
/// blocking work, so an unbounded burst of that work, like the zoom-to-fit
/// described above ``CachingTileOverlayRenderer``, leaves the tile loads and
/// everything else that runs there queued behind the disk.
///
/// The budgets therefore bound two things, and those, rather than one thread
/// per slot, are what a change to them is measured against:
///
/// - how much synchronous tile work can be on the cooperative pool at once, and
/// - how many requests the map and a download have open against tile servers
///   at once. A slow server ties up slots, not threads.
///
/// Because a slow server ties up slots, the map takes one only for a tile it
/// may have to request. A tile already on disk is read first, outside the
/// gate, and offered to auto-save there (see ``CachingTileOverlayRenderer``):
/// read under a slot, a saved tile waited out every slow request ahead of
/// it, for bytes that never needed the radio. That read, a few stats and one
/// small file, and the offer, which moves a browsed tile near the auto-saved
/// hike's route into durable storage, are the part of the map's synchronous
/// tile work the budgets leave unbounded.
///
/// Admission is by ``Priority`` rather than first-come-first-served, because
/// the two callers want opposite things. Tiles the user is looking at are
/// needed *now*; a bulk download of 4,000 tiles is happy to take an extra
/// minute. Two rules keep the download from ever getting in the way:
///
/// - it may never hold more than ``backgroundBudget`` slots, so
///   ``totalBudget`` − ``backgroundBudget`` are always reachable by the map, and
/// - a freed slot goes to a waiting interactive load before a background one.
///
/// A pure admission gate: it doesn't know what the work is, so it can't get out
/// of step with what the callers actually do.
actor TileLoadGate {
    static let shared = TileLoadGate()

    enum Priority {
        /// A tile the map needs to draw. Served first, and never capped below
        /// `totalBudget - backgroundBudget`.
        case interactive
        /// A tile a bulk download wants. Yields to the map.
        case background
    }

    /// Pipelines allowed at once, across every caller.
    private let totalBudget: Int
    /// The most of those a bulk download may hold. The remainder is what
    /// guarantees the map keeps loading tiles while a download runs.
    private let backgroundBudget: Int

    /// The app's budgets are the defaults, so ``shared`` and a
    /// ``OfflineTileDownloader`` under test agree about what they mean. They
    /// are parameters only so a test can widen them past whatever it is
    /// measuring — a caller's own in-flight window is invisible behind a gate
    /// narrower than it is.
    init(totalBudget: Int = 6, backgroundBudget: Int = 3) {
        self.totalBudget = totalBudget
        self.backgroundBudget = backgroundBudget
    }

    private var active = 0
    private var activeBackground = 0
    /// FIFO, and served from the front — a `Deque` so handing a freed slot to
    /// the longest-waiting tile is a constant-time pop rather than shuffling
    /// every remaining waiter down by one. A stalled provider can leave a
    /// screenful of tiles queued here at once.
    private var interactiveWaiters: Deque<CheckedContinuation<Void, Never>> = []
    private var backgroundWaiters: Deque<CheckedContinuation<Void, Never>> = []

    /// Waits for a slot. Every caller must ``release(_:)`` the same priority
    /// once its work is done.
    func acquire(_ priority: Priority = .interactive) async {
        if admit(priority) { return }
        await withCheckedContinuation { continuation in
            switch priority {
            case .interactive: interactiveWaiters.append(continuation)
            case .background: backgroundWaiters.append(continuation)
            }
        }
    }

    /// Gives a slot back, handing it straight to the next eligible waiter when
    /// there is one — so `active` never dips below what's really in flight
    /// between the two.
    func release(_ priority: Priority = .interactive) {
        if priority == .background { activeBackground -= 1 }

        // The map first, always. A background waiter can only take the slot if
        // nothing interactive wants it *and* the download is still under its
        // own share.
        if !interactiveWaiters.isEmpty {
            interactiveWaiters.removeFirst().resume()
            return
        }
        if !backgroundWaiters.isEmpty, activeBackground < backgroundBudget {
            activeBackground += 1
            backgroundWaiters.removeFirst().resume()
            return
        }
        active -= 1
    }

    /// Takes a slot if one is available to this priority right now.
    private func admit(_ priority: Priority) -> Bool {
        guard active < totalBudget else { return false }
        if priority == .background {
            guard activeBackground < backgroundBudget else { return false }
            activeBackground += 1
        }
        active += 1
        return true
    }

    #if DEBUG
    /// Test-only view of what the gate has handed out.
    var inFlight: (total: Int, background: Int) { (active, activeBackground) }

    var budgets: (total: Int, background: Int) { (totalBudget, backgroundBudget) }

    struct TestState {
        let total: Int
        let background: Int
        let interactiveWaiters: Int
        let backgroundWaiters: Int
    }

    /// Atomic test snapshot used to wait until spawned acquire tasks have
    /// either entered or queued, without guessing at actor scheduling delays.
    var testState: TestState {
        TestState(
            total: active,
            background: activeBackground,
            interactiveWaiters: interactiveWaiters.count,
            backgroundWaiters: backgroundWaiters.count
        )
    }
    #endif
}
