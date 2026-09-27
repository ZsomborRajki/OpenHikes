//
//  EventFeedTests.swift
//  OpenHikesTests
//
//  The three things ``EventFeed`` promises its readers — every reader hears
//  every message, a reader that goes away leaves the next one working, and
//  nothing is replayed to a reader that arrives late — and the one it
//  promises its senders: a send never waits for anybody.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Event feed")
@MainActor
struct EventFeedTests {
    @Test("messages arrive once each, in the order they were sent")
    func messagesArriveInOrder() async {
        let feed = EventFeed<Int>()
        let reader = FeedReader(feed.events())

        feed.send(1)
        feed.send(1)
        feed.send(2)
        await settleDelegateHop(until: "all three to arrive") { reader.received.count == 3 }

        #expect(reader.received == [1, 1, 2], "a repeat is a message of its own")
    }

    /// A request is an event, not a value left lying about: whatever was sent
    /// before a reader started is not replayed to it, so a launch cannot act
    /// on a stale request. Proved by a later message that *is* read, so the
    /// absence of the first is not simply a read that had not happened yet.
    @Test("a message sent before anyone listened is not replayed")
    func nothingIsReplayedToALateReader() async {
        let feed = EventFeed<Int>()

        feed.send(1)
        let reader = FeedReader(feed.events())
        feed.send(2)
        await settleDelegateHop(until: "the later message to arrive") { !reader.received.isEmpty }

        #expect(reader.received == [2])
    }

    /// More than one scene can be connected, and each root view reads its own
    /// stream. The tokens this replaced were observed by all of them.
    @Test("every reader hears every message")
    func everyReaderHearsIt() async {
        let feed = EventFeed<Int>()
        let one = FeedReader(feed.events())
        let other = FeedReader(feed.events())

        feed.send(7)
        await settleDelegateHop(until: "both readers to hear it") {
            one.received.count == 1 && other.received.count == 1
        }

        #expect(one.received == [7])
        #expect(other.received == [7])
    }

    /// The hazard a single shared stream would have: an `AsyncStream` whose
    /// reader is cancelled is finished for good. A view's `.task` is torn down
    /// and started again — a scene reconnecting does it — and a message after
    /// that has to reach the new reader rather than a dead stream.
    @Test("a reader that stops does not take later messages with it")
    func aNewReaderHearsAfterAnOldOneStops() async {
        let feed = EventFeed<Int>()
        let first = FeedReader(feed.events())
        // Stopped while it is waiting, as a view's task is when the view
        // goes: a task cancelled before it has begun to read has not taken
        // its stream out yet, and would still read what is sent next.
        await settleDelegateHop()

        first.stop()
        let second = FeedReader(feed.events())
        feed.send(3)
        await settleDelegateHop(until: "the new reader to hear it") { !second.received.isEmpty }

        #expect(second.received == [3])
        #expect(first.received.isEmpty)
    }

    /// ``RecordAlongTrailIntent`` sends before it starts a recording, and may
    /// run with no view tree at all. A send that waited for a reader, as
    /// `AsyncChannel`'s does, would never start that recording.
    @Test("a send with nobody reading returns at once")
    func sendingToNobodyDoesNotWait() {
        let feed = EventFeed<Int>()

        feed.send(1)

        let reader = FeedReader(feed.events())
        #expect(reader.received.isEmpty)
    }
}
