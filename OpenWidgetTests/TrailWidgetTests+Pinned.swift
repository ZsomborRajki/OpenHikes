//
//  TrailWidgetTests+Pinned.swift
//  OpenWidgetTests
//
//  A widget configured for a trail of its own, rather than following whatever
//  the app has selected (#468).
//
//  Two placed widgets could only ever show one trail, and the subject of a
//  placed widget moved for reasons off-screen: opening a hike to check its
//  length re-pointed every widget on the Home Screen. The recording takeover
//  is a deliberate, documented exception to selection ownership; that was not.
//
//  What matters here is the three things that had to stay true while it
//  changed. An **unconfigured** widget keeps doing exactly what it did — which
//  is what every already-placed widget will decode as, and what
//  `AppIntentConfiguration`'s migration argument is worth nothing without. A
//  pinned widget with **no snapshot yet** draws its empty state rather than
//  the selected trail, because showing a different hike from the one its own
//  settings name is wrong without saying so. And the **recording still wins**:
//  pinning a trail does not buy a widget an exemption from the rule.
//
//  An extension rather than a suite of its own, for the reason
//  `TrailWidgetTests+Recording.swift` is one: `init()` there resets the App
//  Group before every test below, and the parent suite is what serializes them
//  against the one container they all write.
//

import Foundation
import OpenHikesShared
import Testing
import WidgetKit

extension TrailWidgetTests {
    // MARK: Two widgets, two trails

    /// The whole point of the issue, read off the provider: the same store
    /// answers two widgets with two different trails.
    @Test("a pinned widget draws its own trail while another follows the selection")
    func twoWidgetsShowTwoTrails() {
        let selected = Self.snapshot(hikeID: UUID(), title: "Selected Trail")
        let pinned = Self.snapshot(hikeID: UUID(), title: "Rennsteig")
        SharedStore.save(selected)
        SharedStore.saveTrailSnapshot(pinned)

        let following = TrailWidgetProvider.currentEntry()
        let configured = TrailWidgetProvider.currentEntry(pinnedTo: pinned.hikeID)

        #expect(following.snapshot?.title == "Selected Trail")
        #expect(configured.snapshot?.title == "Rennsteig")
    }

    /// `nil` is what every widget placed before this change decodes as, so it
    /// has to mean exactly what it meant before.
    @Test("an unconfigured widget still follows the selection")
    func anUnconfiguredWidgetFollowsTheSelection() {
        let selected = Self.snapshot(title: "Selected Trail")
        SharedStore.save(selected)

        #expect(TrailWidgetProvider.currentEntry(pinnedTo: nil).snapshot?.title == "Selected Trail")
    }

    /// Changing the selection moves the unconfigured widget and leaves the
    /// pinned one where it is — which is the complaint the issue opens with.
    @Test("a selection change does not move a pinned widget's trail")
    func aSelectionChangeLeavesAPinnedTrailAlone() {
        let pinned = Self.snapshot(hikeID: UUID(), title: "Rennsteig")
        SharedStore.saveTrailSnapshot(pinned)
        SharedStore.save(Self.snapshot(hikeID: UUID(), title: "First Selection"))

        SharedStore.save(Self.snapshot(hikeID: UUID(), title: "Second Selection"))

        #expect(TrailWidgetProvider.currentEntry().snapshot?.title == "Second Selection")
        #expect(
            TrailWidgetProvider.currentEntry(pinnedTo: pinned.hikeID).snapshot?.title
                == "Rennsteig"
        )
    }

    // MARK: A pinned trail with nothing published for it

    /// **Not the selected trail.** Falling back would be the widget quietly
    /// showing a different hike from the one its own settings name, which is
    /// worse than an empty state: it is wrong without saying so.
    @Test("a pinned widget with no snapshot draws nothing rather than the selection")
    func aPinnedWidgetWithNoSnapshotDrawsNothing() {
        SharedStore.save(Self.snapshot(title: "Selected Trail"))

        let entry = TrailWidgetProvider.currentEntry(pinnedTo: UUID())

        #expect(entry.snapshot == nil)
    }

    // MARK: The static route, which is the case that did not exist before

    /// The one the issue calls out by name. `BackgroundTrailTracker` publishes
    /// a live fix for the **tracked** hike only — one hike is being walked —
    /// so a widget pinned to a different trail has no live position to draw
    /// and must render the static route rather than an empty one.
    @Test("a pinned trail with no live fix still draws its route")
    func aPinnedTrailWithoutALiveFixStillDrawsItsRoute() throws {
        let walked = Self.snapshot(
            hikeID: UUID(),
            title: "Selected Trail",
            liveFix: SharedTrailSnapshot.LiveFix(
                coordinate: .init(latitude: 47.6300, longitude: 12.8600),
                distanceAlongRouteMeters: 1200,
                offRouteMeters: 12,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let pinned = Self.snapshot(hikeID: UUID(), title: "Rennsteig")
        SharedStore.save(walked)
        SharedStore.saveTrailSnapshot(pinned)

        let entry = TrailWidgetProvider.currentEntry(pinnedTo: pinned.hikeID)

        let snapshot = try #require(entry.snapshot)
        #expect(snapshot.liveFix == nil, "only the tracked hike has a live position")
        #expect(!snapshot.polyline.isEmpty, "the static route is what there is to draw")
    }

    // MARK: The rule a pin does not exempt it from

    /// *A live recording outranks the selected trail, on every surface,
    /// without qualification.* A pinned widget is a surface.
    @Test("a live recording takes a pinned widget too")
    func aRecordingTakesAPinnedWidgetToo() throws {
        defer { try? SharedStore.clearRecording() }
        let pinned = Self.snapshot(hikeID: UUID(), title: "Rennsteig")
        SharedStore.saveTrailSnapshot(pinned)
        let recording = Self.recordingSnapshot()
        try SharedStore.saveRecording(recording)

        let entry = TrailWidgetProvider.currentEntry(pinnedTo: pinned.hikeID)

        #expect(entry.recordingSnapshot == recording)
        #expect(entry.snapshot == nil, "the takeover is total, pinned or not")
    }

    /// And the timeline a pinned widget gets is the pinned one, so the
    /// self-healing reload does not quietly re-point it at the selection.
    @Test("a pinned widget's timeline carries its own trail")
    func aPinnedTimelineCarriesItsOwnTrail() {
        SharedStore.save(Self.snapshot(title: "Selected Trail"))
        let pinned = Self.snapshot(hikeID: UUID(), title: "Rennsteig")
        SharedStore.saveTrailSnapshot(pinned)

        let timeline = TrailWidgetProvider.currentTimeline(pinnedTo: pinned.hikeID)

        #expect(timeline.entries.first?.snapshot?.title == "Rennsteig")
    }
}
