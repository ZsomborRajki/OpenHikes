//
//  EventFeedTests.swift
//  OpenHikesTests
//
//  The three things ``EventFeed`` promises its readers — every reader hears
//  every message, a reader that goes away leaves the next one working, and
//  nothing is replayed to a reader that arrives late — and the one it
//  promises its senders: a send never waits for anybody. The first holds by
//  default: a reader that asks for only its newest unread message, as the
//  hike detail's byte refresh does, gets that and nothing older. And the
//  count a suite reads a reader's end by follows the reads.
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

    @Test("a reader can retain only its newest unread notification")
    func newestNotificationBuffer() async {
        let feed = EventFeed<Int>()
        var reader = feed.events(bufferingPolicy: .bufferingNewest(1)).makeAsyncIterator()

        feed.send(1)
        feed.send(2)
        feed.send(3)

        #expect(await reader.next() == 3)
    }

    /// What the root view reads its navigation by — see
    /// ``RootNavigationRequest``. Separate streams cannot keep the order of
    /// two messages sent down two feeds; one stream both feeds yield to as
    /// they send can. Each feed's part is a reader until it is taken out.
    @Test("feeds yielding to one stream keep, between them, the order they were sent in")
    func feedsIntoOneStreamKeepTheirOrder() async {
        let numbers = EventFeed<Int>()
        let words = EventFeed<String>()
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let leaves = [
            numbers.events(into: continuation) { String($0) },
            words.events(into: continuation) { $0 },
        ]
        let reader = FeedReader(stream)

        numbers.send(1)
        words.send("a")
        words.send("b")
        numbers.send(2)
        await settleDelegateHop(until: "all four to arrive") { reader.received.count == 4 }

        #expect(reader.received == ["1", "a", "b", "2"])
        #expect(numbers.readerCount == 1)
        #expect(words.readerCount == 1)
        for leave in leaves {
            leave()
        }
        #expect(numbers.readerCount == 0, "taken out at once")
        #expect(words.readerCount == 0, "taken out at once")
    }

    /// What `AutoSaveTaskLifecycleTests` reads a drain's end by: a stream is
    /// counted from the moment it is handed out, until its reader stops or
    /// the stream is let go, and the rest stay counted.
    @Test("a reader is counted until its read ends")
    func readerCountFollowsTheReads() async {
        let feed = EventFeed<Int>()
        _ = feed.events()
        #expect(feed.readerCount == 0, "a stream let go ends at once")

        let first = FeedReader(feed.events())
        let second = FeedReader(feed.events())
        #expect(feed.readerCount == 2, "a stream counts from the moment it is handed out")

        first.stop()
        await settleDelegateHop(until: "the stopped reader to drop out") { feed.readerCount == 1 }
        #expect(feed.readerCount == 1, "the reader still reading is still counted")

        second.stop()
        await settleDelegateHop(until: "the last reader to drop out") { feed.readerCount == 0 }
        #expect(feed.readerCount == 0)
    }
}
