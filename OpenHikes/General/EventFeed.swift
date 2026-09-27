//
//  EventFeed.swift
//  OpenHikes
//
//  A one-shot message handed to whoever is listening when it is sent — the
//  shape a navigation request from outside the view tree needs.
//
//  ## Why not a token
//
//  The requests this carries used to be tokens: a counter on an `@Observable`
//  whose *change* was the message, read by an `onChange` in `OpenHikesView`.
//  That reads the request during a view update, so the navigation it asks
//  for ran *inside* one — and every one of them writes the sheet's path
//  together with something else: the root view's selection, the sheet's
//  height. Written from an update, those arrive as separate passes over the
//  view graph in the same frame, each updating the sheet's `NavigationStack`,
//  and SwiftUI reports it: "Update NavigationRequestObserver tried to update
//  multiple times per frame". Read from a stream by the view's own task, they
//  run outside any update and land in one transaction, as a tap's do. See the
//  repository instructions, *Render isolation, in practice*.
//
//  ## Why a stream per reader
//
//  An `AsyncStream` has a single consumer and finishes for good when that
//  consumer's task is cancelled. One shared stream would go dead the first
//  time the view's `.task` was torn down — a scene disconnecting does it —
//  and every message after that would vanish without a word. So each
//  ``events()`` call makes a stream of its own and takes it out again on
//  termination, the shape ``AutoSaveTileStore/pendingKeySignals()`` has, and
//  a message goes to every reader there is. More than one scene can be
//  connected, and each root view reads its own.
//
//  ## Why not swift-async-algorithms
//
//  `AsyncChannel`'s `send` waits for a reader, and ``RecordAlongTrailIntent``
//  awaits its request before it starts recording — launched in the background
//  with no view tree, it would wait forever. `share()` keeps a buffer that
//  hands an old message to a reader arriving late, which is exactly the stale
//  request at launch this must not replay.
//

import Foundation
import Synchronization

/// Messages sent to every current reader, and to nobody who arrives later.
nonisolated final class EventFeed<Element: Sendable>: Sendable {
    /// Every reader's continuation, keyed so a reader's termination can take
    /// its own out. A `Mutex` because `onTermination` runs wherever the
    /// stream happened to finish.
    private let readers = Mutex([UUID: AsyncStream<Element>.Continuation]())

    init() {
        // No readers until something asks for ``events()``.
    }

    /// The messages sent from now on, for one reader. Nothing sent before
    /// the call is replayed.
    func events() -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        continuation.onTermination = { [weak self] _ in
            self?.readers.withLock { readers in readers[id] = nil }
        }
        readers.withLock { readers in readers[id] = continuation }
        return stream
    }

    /// Hands `element` to every current reader and returns at once, whether
    /// or not anybody is reading.
    func send(_ element: Element) {
        let current = readers.withLock { readers in Array(readers.values) }
        for continuation in current {
            continuation.yield(element)
        }
    }
}
