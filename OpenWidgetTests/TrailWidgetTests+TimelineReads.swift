//
//  TrailWidgetTests+TimelineReads.swift
//  OpenWidgetTests
//
//  How many times a timeline reads the App Group, and when. Each read is the
//  recording, the trail, the basemap's metadata and the weather, and the
//  provider used to make two even when nothing could have changed between
//  them: one to decide whether a recording needed a location sample, and one
//  to draw. Now only a recording capturing fixes is read twice, because the
//  sample it waits for writes what the timeline must show, so its second read
//  has to come after the sample.
//
//  Driven through `TrailWidgetProvider.timeline(reading:sampling:)`, the
//  decision `timeline(for:in:)` makes, since no test can build the `Context`
//  the protocol method takes. The read and the sample go to a stand-in for
//  the App Group that logs them in order, and whose sample changes what the
//  next read answers, as the real sampler's fix does: a read made before the
//  sample returned would still see the store as it was. An extension of
//  `TrailWidgetTests` for its fixtures and its reset of the App Group, which
//  the entries built here read.
//

import Foundation
import OpenHikesShared
import Testing
import WidgetKit

extension TrailWidgetStoreSuites.TrailWidgetTests {
    /// The App Group, as far as a timeline sees it: each read answers with the
    /// entry it holds now, and a sample, like the sampler appending a fix,
    /// leaves it holding `written` for every read after.
    @MainActor
    private final class StandInStore {
        enum Access: Equatable {
            case read
            case sample(UUID)
        }

        private var held: TrailWidgetEntry
        private let written: TrailWidgetEntry?
        private(set) var accesses: [Access] = []

        init(holding entry: TrailWidgetEntry, afterSample written: TrailWidgetEntry? = nil) {
            held = entry
            self.written = written
        }

        func read() -> TrailWidgetEntry {
            accesses.append(.read)
            return held
        }

        func sample(_ sessionID: UUID) {
            accesses.append(.sample(sessionID))
            if let written { held = written }
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

    /// The sample writes a fix, so the timeline is the read made after the
    /// sample returned, not the one that asked for it nor one made before the
    /// sample finished: either of those still holds `before`.
    @Test("a recording capturing fixes is sampled, then read again for the timeline")
    @MainActor
    func capturingRecordingReadsAfterTheSample() async {
        let readDate = Date(timeIntervalSince1970: 1_750_000_000)
        let session = UUID()
        let before = Self.recordingSnapshot(sessionID: session)
        var after = before
        after.pointCount += 1
        let afterDate = readDate.addingTimeInterval(30)
        let store = StandInStore(
            holding: TrailWidgetEntry(date: readDate, snapshot: nil, recordingSnapshot: before),
            afterSample: TrailWidgetEntry(date: afterDate, snapshot: nil, recordingSnapshot: after)
        )

        let timeline = await TrailWidgetProvider.timeline(reading: store.read, sampling: store.sample)

        #expect(store.accesses == [.read, .sample(session), .read])
        #expect(timeline.entries.first?.recordingSnapshot == after)
        #expect(timeline.policy == .after(TrailWidgetProvider.nextReload(after: afterDate, recording: true)))
    }
}
