//
//  RecordingEntryTests.swift
//  OpenHikesTests
//
//  What the map's record button does with a tap: start a recording only when
//  none is under way, and then ask for its screen the way a widget tap does.
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
