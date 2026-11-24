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
//  run outside any update and land in one transaction, as a tap's do. See *The
//  map screen* in `AGENTS.md`.
//
//  ## Why a stream per reader
//
//  An `AsyncStream` has a single consumer and finishes for good when that
//  consumer's task is cancelled. One shared stream would go dead the first
//  time the view's `.task` was torn down — a scene disconnecting does it —
//  and every message after that would vanish without a word. So each
//  ``events()`` call makes a stream of its own and takes it out again on
//  termination, and a message goes to every reader there is. More than one
//  scene can be connected, and each root view reads its own.
//
//  The same shape carries notifications that only say "there is work", such
//  as ``AutoSaveTileStore/pendingKeySignals()``: a reader that asks for
//  `.bufferingNewest(1)` hears a burst of them as one.
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
    /// How each reader is handed a message, keyed so a reader's leaving can
    /// take its own out. A `Mutex` because `onTermination` runs wherever the
    /// stream happened to finish.
    private let readers = Mutex([UUID: @Sendable (Element) -> Void]())

    init() {
        // No readers until something asks for ``events()``.
    }

    /// The messages sent from now on, for one reader. Nothing sent before
    /// the call is replayed. A reader coalescing notifications can bound its
    /// unread buffer; other readers keep every message by default.
    func events(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: bufferingPolicy)
        let leave = join { element in continuation.yield(element) }
        continuation.onTermination = { _ in leave() }
        return stream
    }

    /// The messages sent from now on, each made a `Merged` and yielded to
    /// `continuation` as it is sent, for a reader of several feeds as one
    /// stream. Nothing sent before the call is replayed.
    ///
    /// Each feed's own stream keeps its messages in order, but nothing keeps
    /// the order between two streams: their readers are woken as the
    /// executor gets to them, so of two messages sent one after the other
    /// down two feeds, either can be read first. Feeds that yield to one
    /// continuation as they send keep, in its stream, the order their
    /// messages were sent in.
    ///
    /// One continuation takes several feeds, so its `onTermination` is the
    /// reader's to set. This returns what takes this feed's part out again,
    /// for the reader to call when it stops reading.
    func events<Merged: Sendable>(
        into continuation: AsyncStream<Merged>.Continuation,
        as transform: @escaping @Sendable (Element) -> Merged
    ) -> @Sendable () -> Void {
        join { element in continuation.yield(transform(element)) }
    }

    /// Hands `element` to every current reader and returns at once, whether
    /// or not anybody is reading. The readers are copied out under the lock
    /// and handed the element after it is let go.
    func send(_ element: Element) {
        let current = readers.withLock { readers in Array(readers.values) }
        for deliver in current {
            deliver(element)
        }
    }

    /// How many readers ``events(bufferingPolicy:)`` and
    /// ``events(into:as:)`` have taken on that have not left.
    ///
    /// **Test seam.** A stream ends when its reader's task is cancelled or
    /// the stream is let go, and takes itself out then, so a suite can see a
    /// read really end without waiting out a duration.
    var readerCount: Int {
        readers.withLock { readers in readers.count }
    }

    /// Takes on a reader, and returns what takes it out again.
    private func join(_ deliver: @escaping @Sendable (Element) -> Void) -> @Sendable () -> Void {
        let id = UUID()
        readers.withLock { readers in readers[id] = deliver }
        return { [weak self] in
            self?.readers.withLock { readers in readers[id] = nil }
        }
    }
}
