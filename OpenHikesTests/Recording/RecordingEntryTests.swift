//
//  RecordingEntryTests.swift
//  OpenHikesTests
//
//  What the map's record button does with a tap: start a recording only when
//  none is under way, and then ask for its screen the way a widget tap does —
//  and, mid-walk, only once the hiker has said to end the walk.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

@Suite("Recording entry")
struct RecordingEntryTests {
    @Test("with nothing recording, a tap starts one and then asks for its screen")
    func startsThenOpens() async {
        let requests = HikeOpenRequests()
        let sent = FeedReader(requests.links())
        var live = false
        var starts = 0
        // How many requests had been sent when the recording started — the
        // order is the claim, not only that both happened. Read after letting
        // the reader catch up: requests arrive on its task, so a count taken
        // straight away would read 0 even if the request had gone first.
        var requestsAtStart: Int?
        let entry = RecordingEntry(
            isLive: { live },
            start: {
                starts += 1
                await settleDelegateHop()
                requestsAtStart = sent.received.count
                live = true
            },
            openRequests: requests
        )
        #expect(!entry.isRecording)

        entry.requestRecording()
        await settleDelegateHop(until: "the screen to be asked for") { sent.received.count == 1 }

        #expect(starts == 1)
        #expect(requestsAtStart == 0, "the screen was asked for before the recording started")
        #expect(sent.received.count == 1)
        #expect(sent.received.last == TrailWidgetDeepLink.recordingURL())
        #expect(entry.isRecording)
    }

    @Test("with a recording under way, a tap reopens it and starts nothing")
    func reopensWithoutStarting() async {
        let requests = HikeOpenRequests()
        let sent = FeedReader(requests.links())
        var starts = 0
        let entry = RecordingEntry(
            isLive: { true },
            start: { starts += 1 },
            openRequests: requests
        )

        entry.requestRecording()
        await settleDelegateHop(until: "the screen to be asked for") { sent.received.count == 1 }

        #expect(starts == 0)
        #expect(sent.received.count == 1)
        #expect(sent.received.last == TrailWidgetDeepLink.recordingURL())
    }

    /// A hiker walks or records, never both: mid-walk the button asks first,
    /// and a tap that reaches here anyway starts nothing beside the walk.
    @Test("with a walk under way, a tap starts nothing and the button asks first")
    func walkUnderWayAsksFirst() {
        var starts = 0
        let entry = RecordingEntry(
            isLive: { false },
            start: { starts += 1 },
            walkUnderWay: { "Ridge Loop" },
            endWalk: { true },
            openRequests: HikeOpenRequests()
        )
        #expect(entry.walkToEnd == "Ridge Loop")

        entry.requestRecording()

        #expect(starts == 0, "refused before any task is made")
    }

    @Test("with a recording live, a walk asks nothing: the tap only reopens it")
    func liveRecordingAsksNothing() {
        let entry = RecordingEntry(
            isLive: { true },
            start: { /* already live, never called */ },
            walkUnderWay: { "Ridge Loop" },
            endWalk: { true },
            openRequests: HikeOpenRequests()
        )
        #expect(entry.walkToEnd == nil)
    }

    @Test("ending the walk to record ends it, then starts the recording and asks for its screen")
    func endWalkAndRecord() async {
        let requests = HikeOpenRequests()
        let sent = FeedReader(requests.links())
        var walking: String? = "Ridge Loop"
        var startsMidWalk = 0
        var starts = 0
        let entry = RecordingEntry(
            isLive: { false },
            start: {
                starts += 1
                if walking != nil { startsMidWalk += 1 }
            },
            walkUnderWay: { walking },
            endWalk: {
                walking = nil
                return true
            },
            openRequests: requests
        )

        entry.endWalkAndRecord()
        await settleDelegateHop(until: "the screen to be asked for") { sent.received.count == 1 }

        #expect(starts == 1)
        #expect(startsMidWalk == 0, "the walk ended before the recording began")
        #expect(sent.received.last == TrailWidgetDeepLink.recordingURL())
    }

    /// A commit the store refused leaves the walk under way, so recording now
    /// would be the overlap all over again.
    @Test("a walk the store would not end starts no recording")
    func refusedEndStartsNothing() {
        var starts = 0
        let entry = RecordingEntry(
            isLive: { false },
            start: { starts += 1 },
            walkUnderWay: { "Ridge Loop" },
            endWalk: { false },
            openRequests: HikeOpenRequests()
        )

        entry.endWalkAndRecord()

        #expect(starts == 0)
        #expect(entry.walkToEnd == "Ridge Loop")
    }

    /// Two taps are two requests, for the reason ``HikeOpenRequests`` sends
    /// each one: a recording screen closed and asked for again has to open.
    @Test("each tap is its own request")
    func eachTapCounts() async {
        let requests = HikeOpenRequests()
        let sent = FeedReader(requests.links())
        let entry = RecordingEntry(
            isLive: { true },
            start: { /* already live, never called */ },
            openRequests: requests
        )

        entry.requestRecording()
        entry.requestRecording()
        await settleDelegateHop(until: "both requests to land") { sent.received.count == 2 }

        #expect(sent.received.count == 2)
    }
}
