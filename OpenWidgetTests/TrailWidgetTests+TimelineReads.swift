//
//  TrailWidgetTests+TimelineReads.swift
//  OpenWidgetTests
//
//  How many times a timeline reads the App Group, and when. Each read is the
//  recording, the trail, the basemap's metadata and the weather, and the
//  provider used to make two even when nothing could have changed between
//  them: one to decide whether a recording needed a location sample, and one
//  to draw. Now a second read is made only after a sample that waited on a
//  location request, because the app may have written in the meantime (a
//  pause, a stop, a newer snapshot). The sample's own fix is not what it is
//  for: that goes to the pending queue, which the widget never reads back.
//
//  Driven through `TrailWidgetProvider.timeline(reading:sampling:)`, the
//  decision `timeline(for:in:)` makes, since no test can build the `Context`
//  the protocol method takes. The read and the sample go to a stand-in for
//  the App Group that logs them in order. A sample that waits lets the app's
//  write land, so a read made before the wait is over still sees the store as
//  it was; a declined one answers at once and changes nothing. An extension
//  of `TrailWidgetTests` for its fixtures and its reset of the App Group,
//  which the entries built here read.
//

import Foundation
import OpenHikesShared
import Testing
import WidgetKit

extension TrailWidgetStoreSuites.TrailWidgetTests {
    /// The App Group, as far as a timeline sees it: each read answers with the
    /// entry it holds now. A sample answers whether it waited on a location
    /// request, and one that did leaves the store holding what the app wrote
    /// during the wait, if anything.
    @MainActor
    private final class StandInStore {
        enum Access: Equatable {
            case read
            case sample(UUID)
        }

        private var held: TrailWidgetEntry
        private let writtenDuringWait: TrailWidgetEntry?
        private let sampleWaits: Bool
        private(set) var accesses: [Access] = []

        init(
            holding entry: TrailWidgetEntry,
            writtenDuringWait: TrailWidgetEntry? = nil,
            sampleWaits: Bool = true
        ) {
            held = entry
            self.writtenDuringWait = writtenDuringWait
            self.sampleWaits = sampleWaits
        }

        func read() -> TrailWidgetEntry {
            accesses.append(.read)
            return held
        }

        func sample(_ sessionID: UUID) -> Bool {
            accesses.append(.sample(sessionID))
            guard sampleWaits else { return false }
            if let writtenDuringWait { held = writtenDuringWait }
            return true
        }
    }

    @Test("a trail's timeline is drawn from the one read that decided it")
    @MainActor
    func trailReadsOnce() async {
        let readDate = Date(timeIntervalSince1970: 1_750_000_000)
        let store = StandInStore(holding: TrailWidgetEntry(date: readDate, snapshot: Self.snapshot(title: "Ridge")))

        let timeline = await TrailWidgetProvider.timeline(reading: store.read, sampling: store.sample)

        #expect(store.accesses == [.read])
        #expect(timeline.entries.first?.snapshot?.title == "Ridge")
        #expect(timeline.policy == .after(TrailWidgetProvider.nextReload(after: readDate)))
    }

    /// A paused walk keeps the widget, and is not worth a location sample:
    /// it is drawn from the one read, at the quiet cadence.
    @Test("a paused recording keeps the widget from one read, with no sample")
    @MainActor
    func pausedRecordingReadsOnce() async {
        let readDate = Date(timeIntervalSince1970: 1_750_000_000)
        let paused = Self.recordingSnapshot(isCapturingFixes: false)
        let store = StandInStore(holding: TrailWidgetEntry(
            date: readDate,
            snapshot: Self.snapshot(title: "Ridge"),
            recordingSnapshot: paused
        ))

        let timeline = await TrailWidgetProvider.timeline(reading: store.read, sampling: store.sample)

        #expect(store.accesses == [.read])
        #expect(timeline.entries.first?.recordingSnapshot == paused)
        #expect(timeline.entries.first?.snapshot == nil, "the takeover holds through the pause")
        #expect(timeline.policy == .after(TrailWidgetProvider.nextReload(after: readDate)))
    }

    /// The hiker pauses while the sampler waits on a location request, and
    /// the app publishes it. The timeline is the read made once the wait is
    /// over, so it draws the pause at the quiet cadence, counted from then:
    /// the read that asked for the sample, or one made before the wait ended,
    /// would still draw a recording capturing fixes and reload in twenty
    /// minutes from before it.
    @Test("a recording capturing fixes is read again after a sample that waited")
    @MainActor
    func capturingRecordingReadsAfterTheWait() async {
        let readDate = Date(timeIntervalSince1970: 1_750_000_000)
        let session = UUID()
        let before = Self.recordingSnapshot(sessionID: session)
        let pausedDuringWait = Self.recordingSnapshot(sessionID: session, isCapturingFixes: false)
        let afterDate = readDate.addingTimeInterval(8)
        let store = StandInStore(
            holding: TrailWidgetEntry(date: readDate, snapshot: nil, recordingSnapshot: before),
            writtenDuringWait: TrailWidgetEntry(date: afterDate, snapshot: nil, recordingSnapshot: pausedDuringWait)
        )

        let timeline = await TrailWidgetProvider.timeline(reading: store.read, sampling: store.sample)

        #expect(store.accesses == [.read, .sample(session), .read])
        #expect(timeline.entries.first?.recordingSnapshot == pausedDuringWait)
        #expect(timeline.policy == .after(TrailWidgetProvider.nextReload(after: afterDate)))
    }

    /// The sampler declines at once when a request is already in flight, the
    /// widget may not use location, or this recording was sampled in the last
    /// fifteen minutes. Nothing was waited for, so the read that asked is the
    /// timeline, at the recording's cadence.
    @Test("a recording whose sample was declined is drawn from the one read")
    @MainActor
    func declinedSampleReadsOnce() async {
        let readDate = Date(timeIntervalSince1970: 1_750_000_000)
        let session = UUID()
        let recording = Self.recordingSnapshot(sessionID: session)
        let store = StandInStore(
            holding: TrailWidgetEntry(date: readDate, snapshot: nil, recordingSnapshot: recording),
            sampleWaits: false
        )

        let timeline = await TrailWidgetProvider.timeline(reading: store.read, sampling: store.sample)

        #expect(store.accesses == [.read, .sample(session)])
        #expect(timeline.entries.first?.recordingSnapshot == recording)
        #expect(timeline.policy == .after(TrailWidgetProvider.nextReload(after: readDate, recording: true)))
    }
}
