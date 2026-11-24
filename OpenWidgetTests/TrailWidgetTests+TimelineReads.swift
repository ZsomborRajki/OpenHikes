//
//  TrailWidgetTests+TimelineReads.swift
//  OpenWidgetTests
//
//  How many times a timeline reads the App Group. Each read is the recording,
//  the trail, the basemap's metadata and the weather, and the provider used to
//  make two even when nothing could have changed between them: one to decide
//  whether a recording needed a location sample, and one to draw. Now only a
//  recording capturing fixes is read twice, because the sample it waits for
//  writes what the timeline must show.
//
//  Driven through `TrailWidgetProvider.timeline(reading:sampling:)`, the
//  decision `timeline(for:in:)` makes, with a read that counts and a sampler
//  that records, since no test can build the `Context` the protocol method
//  takes. An extension of `TrailWidgetTests` for its fixtures and its reset of
//  the App Group, which the entries built here read.
//

import Foundation
import OpenHikesShared
import Testing
import WidgetKit

extension TrailWidgetStoreSuites.TrailWidgetTests {
    /// A read that counts, answering with each of `entries` in turn and then
    /// with the last.
    @MainActor
    private final class CountedReads {
        private let entries: [TrailWidgetEntry]
        private(set) var count = 0
        private(set) var sampled: [UUID] = []

        init(_ entries: TrailWidgetEntry...) {
            self.entries = entries
        }

        func read() -> TrailWidgetEntry {
            defer { count += 1 }
            return entries[min(count, entries.count - 1)]
        }

        func sample(_ sessionID: UUID) {
            sampled.append(sessionID)
        }
    }

    @Test("a trail's timeline is drawn from the one read that decided it")
    @MainActor
    func trailReadsOnce() async {
        let readDate = Date(timeIntervalSince1970: 1_750_000_000)
        let reads = CountedReads(TrailWidgetEntry(date: readDate, snapshot: Self.snapshot(title: "Ridge")))

        let timeline = await TrailWidgetProvider.timeline(reading: reads.read, sampling: reads.sample)

        #expect(reads.count == 1)
        #expect(reads.sampled.isEmpty)
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
        let reads = CountedReads(TrailWidgetEntry(
            date: readDate,
            snapshot: Self.snapshot(title: "Ridge"),
            recordingSnapshot: paused
        ))

        let timeline = await TrailWidgetProvider.timeline(reading: reads.read, sampling: reads.sample)

        #expect(reads.count == 1)
        #expect(reads.sampled.isEmpty)
        #expect(timeline.entries.first?.recordingSnapshot == paused)
        #expect(timeline.entries.first?.snapshot == nil, "the takeover holds through the pause")
        #expect(timeline.policy == .after(TrailWidgetProvider.nextReload(after: readDate)))
    }

    /// The sample writes a fix, so the timeline is the read made after it,
    /// not the one that asked for it.
    @Test("a recording capturing fixes is sampled, then read again for the timeline")
    @MainActor
    func capturingRecordingReadsAfterTheSample() async {
        let readDate = Date(timeIntervalSince1970: 1_750_000_000)
        let session = UUID()
        let before = Self.recordingSnapshot(sessionID: session)
        var after = before
        after.pointCount += 1
        let afterDate = readDate.addingTimeInterval(30)
        let reads = CountedReads(
            TrailWidgetEntry(date: readDate, snapshot: nil, recordingSnapshot: before),
            TrailWidgetEntry(date: afterDate, snapshot: nil, recordingSnapshot: after)
        )

        let timeline = await TrailWidgetProvider.timeline(reading: reads.read, sampling: reads.sample)

        #expect(reads.count == 2)
        #expect(reads.sampled == [session])
        #expect(timeline.entries.first?.recordingSnapshot == after)
        #expect(timeline.policy == .after(TrailWidgetProvider.nextReload(after: afterDate, recording: true)))
    }
}
