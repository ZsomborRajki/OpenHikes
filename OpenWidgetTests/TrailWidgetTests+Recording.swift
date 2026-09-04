//
//  TrailWidgetTests+Recording.swift
//  OpenWidgetTests
//
//  The one contention this widget has, and the decision that settles it: a
//  live recording always outranks the trail the walker selected, and takes the
//  whole widget rather than a badge or a secondary line.
//
//  The rule is the same one `HikeLiveActivityController.accepts(_:)` applies
//  to the Lock Screen, and it is applied here so the two surfaces cannot
//  disagree about which walk is under way. It is also *total* — a paused
//  recording keeps the widget — which is the half a future reader is most
//  likely to mistake for an oversight, because two neighbouring decisions in
//  the same provider genuinely do turn on `isCapturingFixes`. These tests are
//  where that difference is written down as policy.
//
//  An extension rather than more of `TrailWidgetTests` only because the suite
//  had reached its body-length limit; `init()` there still resets the App
//  Group before every test below, and the parent suite is what serializes them
//  against the one payload they all write.
//

import Foundation
import OpenHikesShared
import Testing
import WidgetKit

extension TrailWidgetTests {
    @Test("a live recording takes over the widget and deep links back to it")
    func recordingTakesOver() throws {
        defer { try? SharedStore.clearRecording() }
        let trail = Self.snapshot(title: "Selected Trail")
        let recording = Self.recordingSnapshot()
        SharedStore.save(trail)
        try SharedStore.saveRecording(recording)

        let entry = TrailWidgetProvider.currentEntry()

        #expect(entry.recordingSnapshot == recording)
        #expect(entry.snapshot == nil)
        #expect(entry.basemaps == nil)
        let url = try #require(entry.deepLinkURL)
        #expect(
            TrailWidgetDeepLink.destination(from: url) == .recording
        )
    }

    /// The takeover is on the recording's *existence*, not on whether it is
    /// still capturing fixes. A walker who pauses for lunch is still on the
    /// walk, and handing the screen back to the trail underneath them —
    /// then taking it away again on the resume — would be the rule flickering
    /// rather than holding.
    @Test("a paused recording keeps the widget rather than handing it back")
    func pausedRecordingKeepsTheWidget() throws {
        defer { try? SharedStore.clearRecording() }
        SharedStore.save(Self.snapshot(title: "Selected Trail"))
        try SharedStore.saveRecording(
            Self.recordingSnapshot(isCapturingFixes: false)
        )

        let entry = TrailWidgetProvider.currentEntry()

        #expect(entry.snapshot == nil, "a pause is not the end of the walk")
        #expect(entry.recordingSnapshot?.isCapturingFixes == false)
        let url = try #require(entry.deepLinkURL)
        #expect(TrailWidgetDeepLink.destination(from: url) == .recording)
    }

    /// The takeover is a projection and nothing else: the entry drops the
    /// trail, the store keeps it.
    ///
    /// This is what lets the app go on writing the trail feed throughout a
    /// recording while spending no reloads on it — see `TrailWidgetReload` in
    /// the app target. If the takeover ever *cleared* the selection instead,
    /// that gating would silently cost the walker their trail at the end of
    /// every walk, and this is the test that says so.
    @Test("the selected trail survives the takeover and returns when the walk ends")
    func selectionReturnsAfterTheRecordingClears() throws {
        let trail = Self.snapshot(title: "Selected Trail")
        SharedStore.save(trail)
        SharedStore.saveBasemapSet(Self.basemapSet(for: trail.hikeID))
        try SharedStore.saveRecording(Self.recordingSnapshot())
        #expect(
            TrailWidgetProvider.currentEntry().snapshot == nil,
            "precondition: the recording has the widget"
        )

        try SharedStore.clearRecording()

        let entry = TrailWidgetProvider.currentEntry()
        #expect(entry.recordingSnapshot == nil)
        #expect(entry.snapshot?.hikeID == trail.hikeID)
        #expect(entry.snapshot?.title == "Selected Trail")
        #expect(entry.basemaps?.hikeID == trail.hikeID, "the rendered map came back with it")
        let url = try #require(entry.deepLinkURL)
        #expect(TrailWidgetDeepLink.destination(from: url) == .hike(trail.hikeID))
    }

    /// The widget and the Control Center button read the same payload and must
    /// name the same owner: a button offering "Start Hike" over a widget
    /// drawing a live trace is the two surfaces disagreeing about whether the
    /// walker is out walking.
    @Test("the widget and the recording control agree on who owns the walk")
    func controlAgreesWithTheWidget() throws {
        defer { try? SharedStore.clearRecording() }
        SharedStore.save(Self.snapshot(title: "Selected Trail"))

        #expect(TrailWidgetProvider.currentEntry().recordingSnapshot == nil)
        #expect(HikeRecordingControlState(snapshot: SharedStore.loadRecording()) == .idle)

        for isCapturingFixes in [true, false] {
            try SharedStore.saveRecording(
                Self.recordingSnapshot(isCapturingFixes: isCapturingFixes)
            )
            #expect(
                TrailWidgetProvider.currentEntry().recordingSnapshot != nil,
                "\(isCapturingFixes)"
            )
            #expect(
                HikeRecordingControlState(snapshot: SharedStore.loadRecording()) == .recording,
                "\(isCapturingFixes)"
            )
        }
    }

    @Test("recordings ask WidgetKit for a sparse gap-filling refresh")
    func recordingUsesShorterRefresh() throws {
        defer { try? SharedStore.clearRecording() }
        try SharedStore.saveRecording(Self.recordingSnapshot())
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let timeline = TrailWidgetProvider.currentTimeline(date: now)
        let reload = TrailWidgetProvider.nextReload(
            after: now,
            recording: true
        )

        #expect(timeline.policy == .after(reload))
        #expect(
            reload.timeIntervalSince(now)
                == Double(TrailWidgetProvider.recordingRefreshMinutes * 60)
        )
    }

    @Test("a paused recording does not spend the location refresh budget")
    func pausedRecordingUsesSafetyNetRefresh() throws {
        defer { try? SharedStore.clearRecording() }
        try SharedStore.saveRecording(
            Self.recordingSnapshot(isCapturingFixes: false)
        )
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let timeline = TrailWidgetProvider.currentTimeline(date: now)

        #expect(
            timeline.policy
                == .after(TrailWidgetProvider.nextReload(after: now))
        )
    }
}
