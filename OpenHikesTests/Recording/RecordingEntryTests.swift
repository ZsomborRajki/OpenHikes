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
        var live = false
        var starts = 0
        // How many requests had been left when the recording started — the
        // order is the claim, not only that both happened.
        var requestsAtStart: Int?
        let entry = RecordingEntry(
            isLive: { live },
            start: {
                starts += 1
                requestsAtStart = requests.request
                live = true
            },
            openRequests: requests
        )
        #expect(!entry.isRecording)

        entry.requestRecording()
        await settleDelegateHop(until: "the screen to be asked for") { requests.request == 1 }

        #expect(starts == 1)
        #expect(requestsAtStart == 0, "the screen was asked for before the recording started")
        #expect(requests.link == TrailWidgetDeepLink.recordingURL())
        #expect(entry.isRecording)
    }

    @Test("with a recording under way, a tap reopens it and starts nothing")
    func reopensWithoutStarting() async {
        let requests = HikeOpenRequests()
        var starts = 0
        let entry = RecordingEntry(
            isLive: { true },
            start: { starts += 1 },
            openRequests: requests
        )

        entry.requestRecording()
        await settleDelegateHop(until: "the screen to be asked for") { requests.request == 1 }

        #expect(starts == 0)
        #expect(requests.link == TrailWidgetDeepLink.recordingURL())
    }

    /// Two taps are two requests, for the reason ``HikeOpenRequests`` is a
    /// token: a recording screen closed and asked for again has to open.
    @Test("each tap is its own request")
    func eachTapCounts() async {
        let requests = HikeOpenRequests()
        let entry = RecordingEntry(
            isLive: { true },
            start: { /* already live, never called */ },
            openRequests: requests
        )

        entry.requestRecording()
        entry.requestRecording()
        await settleDelegateHop(until: "both requests to land") { requests.request == 2 }

        #expect(requests.request == 2)
    }
}
