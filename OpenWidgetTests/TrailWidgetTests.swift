//
//  TrailWidgetTests.swift
//  OpenWidgetTests
//
//  The widget target had no tests at all: only the shared payload underneath
//  it was covered, which says what the app *wrote* and nothing about what the
//  widget makes of it.
//
//  What's checkable here is everything except the pixels. `TimelineProvider`'s
//  own methods take a `TimelineProviderContext` that cannot be constructed
//  outside WidgetKit, so the provider's decisions are reached through the
//  static entry points those methods delegate to — which is why they exist.
//
//  This bundle is hosted by OpenTrails.app so it inherits the App Group
//  entitlement the widget reads through; without it there is no container and
//  nothing to read.
//

import CoreLocation
import Foundation
import OpenTrailsShared
import Testing
import WidgetKit

/// Whether this process can reach the App Group container. Mirrors the app
/// test target's probe: absent capability skips rather than fails for the
/// wrong reason, and the precondition test below is what makes the skip
/// visible.
enum WidgetStoreProbe {
    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroupID) != nil
    }

    /// See `SuitePrecondition` in the app test target: the compilation
    /// condition is the half that can be set from a command line, the
    /// environment variable the half that can be set from Xcode.
    static var isStrict: Bool {
        #if REQUIRE_ALL_SUITES
        return true
        #else
        return ProcessInfo.processInfo.environment["OPENTRAILS_REQUIRE_ALL_SUITES"] == "1"
        #endif
    }
}

@Suite("Widget preconditions")
struct WidgetPreconditionTests {
    @Test("the App Group the widget reads from is reachable")
    func appGroupIsReachable() {
        guard !WidgetStoreProbe.isAvailable else { return }
        let message = "the App Group container \(SharedStore.appGroupID) is unreachable, so the widget suites were skipped"
        if WidgetStoreProbe.isStrict {
            Issue.record(Comment(rawValue: "Precondition not met: \(message)."))
        } else {
            print("⚠︎ Skipped coverage — precondition not met: \(message). Set OPENTRAILS_REQUIRE_ALL_SUITES=1 to make this a failure.")
        }
    }
}

@Suite("Widget recording requests")
struct WidgetRecordingRequestTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func location(
        age: TimeInterval,
        accuracy: CLLocationAccuracy
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: 47.63,
                longitude: 12.86
            ),
            altitude: 600,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            course: 0,
            speed: 1,
            timestamp: now.addingTimeInterval(-age)
        )
    }

    @Test("age and accuracy boundaries are inclusive")
    func acceptanceBoundariesAreInclusive() {
        #expect(
            WidgetRecordingFixPolicy.accepts(
                location(age: 0, accuracy: 0),
                now: now
            )
        )
        #expect(
            WidgetRecordingFixPolicy.accepts(
                location(
                    age: WidgetRecordingFixPolicy.maximumAge,
                    accuracy:
                        WidgetRecordingFixPolicy
                            .maximumHorizontalAccuracy
                ),
                now: now
            )
        )
        #expect(
            !WidgetRecordingFixPolicy.accepts(
                location(
                    age: WidgetRecordingFixPolicy.maximumAge + 0.001,
                    accuracy: 50
                ),
                now: now
            )
        )
        #expect(
            !WidgetRecordingFixPolicy.accepts(
                location(
                    age: 1,
                    accuracy:
                        WidgetRecordingFixPolicy
                            .maximumHorizontalAccuracy + 0.001
                ),
                now: now
            )
        )
        #expect(
            !WidgetRecordingFixPolicy.accepts(
                location(age: -0.001, accuracy: 50),
                now: now
            )
        )
    }

    @MainActor
    @Test("a timeout completion cannot fire again for a late fix")
    func completionIsOneShot() {
        let sessionID = UUID()
        var completionCount = 0
        let request = WidgetRecordingRequest(sessionID: sessionID) {
            completionCount += 1
        }

        let timeout = request.consume()
        timeout?.completion()
        let lateFix = request.consume()
        lateFix?.completion()

        #expect(timeout?.sessionID == sessionID)
        #expect(lateFix == nil)
        #expect(completionCount == 1)
    }
}

/// Everything below writes the one App Group payload, so it runs serialized.
@Suite("Trail widget", .serialized, .enabled(if: WidgetStoreProbe.isAvailable))
struct TrailWidgetTests {

    private static func snapshot(
        hikeID: UUID = UUID(),
        title: String = "Ridge Loop",
        liveFix: SharedTrailSnapshot.LiveFix? = nil
    ) -> SharedTrailSnapshot {
        SharedTrailSnapshot(
            hikeID: hikeID,
            title: title,
            tintHex: "#34C759FF",
            totalDistanceMeters: 4_200,
            elevationLowMeters: 600,
            elevationHighMeters: 900,
            polyline: [
                .init(latitude: 47.6300, longitude: 12.8600),
                .init(latitude: 47.6320, longitude: 12.8620),
                .init(latitude: 47.6340, longitude: 12.8600)
            ],
            liveFix: liveFix
        )
    }

    private static func basemapSet(for hikeID: UUID) -> TrailBasemapSet {
        let rect = UnitMercatorRect(originX: 0.5, originY: 0.3, width: 0.001, height: 0.001)
        return TrailBasemapSet(
            hikeID: hikeID,
            coverage: rect,
            images: [
                TrailBasemap(
                    fileName: "test-\(hikeID.uuidString).png",
                    variant: .square,
                    appearance: .light,
                    pixelWidth: 320,
                    pixelHeight: 320,
                    visibleRect: rect
                )
            ]
        )
    }

    private static func recordingSnapshot(
        sessionID: UUID = UUID(),
        isCapturingFixes: Bool = true
    ) -> SharedRecordingSnapshot {
        SharedRecordingSnapshot(
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            distanceMeters: 1_200,
            pointCount: 240,
            polyline: [
                .init(latitude: 47.6300, longitude: 12.8600),
                .init(latitude: 47.6320, longitude: 12.8620)
            ],
            isCapturingFixes: isCapturingFixes
        )
    }

    init() {
        SharedStore.clear()
        try? SharedStore.clearRecording()
        try? SharedStore.clearPendingRecordingFixes()
    }

    // MARK: The timeline

    /// One entry, and a reload scheduled far enough out to be a safety net
    /// rather than a schedule: the app pushes every real update itself, and a
    /// widget that overruns its daily reload budget gets throttled.
    @Test("the timeline is one entry and a distant self-healing reload")
    func timelineIsOneEntryAndASafetyNet() throws {
        let stored = Self.snapshot()
        SharedStore.save(stored)

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let timeline = TrailWidgetProvider.currentTimeline(date: now)

        #expect(timeline.entries.count == 1, "there is nothing to predict — the app pushes updates")
        let entry = try #require(timeline.entries.first)
        #expect(entry.date == now)
        #expect(entry.snapshot?.hikeID == stored.hikeID)

        // `TimelineReloadPolicy` is opaque, so the policy is checked by
        // equality against the one the widget says it schedules.
        let reload = TrailWidgetProvider.nextReload(after: now)
        #expect(timeline.policy == .after(reload), "a missed push would otherwise be permanent")
        #expect(timeline.policy != .never)
        #expect(
            reload.timeIntervalSince(now) >= 5 * 3_600,
            "a near reload would spend the daily budget the pushes need"
        )
    }

    @Test("the timeline's entry carries the trail the app last wrote")
    func timelineReflectsTheStoredTrail() throws {
        let first = Self.snapshot(title: "First")
        SharedStore.save(first)
        #expect(TrailWidgetProvider.currentEntry().snapshot?.title == "First")

        let second = Self.snapshot(title: "Second")
        SharedStore.save(second)

        let entry = TrailWidgetProvider.currentEntry()
        #expect(entry.snapshot?.hikeID == second.hikeID)
        #expect(entry.snapshot?.title == "Second")
    }

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

    /// Progress along the trail is precomputed by the app; the widget only
    /// reads it. This is the line the user actually sees.
    @Test("a live fix arrives as progress, not as raw coordinates")
    func liveFixIsCarriedThrough() throws {
        let fix = SharedTrailSnapshot.LiveFix(
            coordinate: .init(latitude: 47.6320, longitude: 12.8620),
            distanceAlongRouteMeters: 2_100,
            offRouteMeters: 4,
            timestamp: Date(timeIntervalSince1970: 1_750_000_000)
        )
        SharedStore.save(Self.snapshot(liveFix: fix))

        let entry = TrailWidgetProvider.currentEntry()
        let snapshot = try #require(entry.snapshot)
        #expect(snapshot.liveFix?.distanceAlongRouteMeters == 2_100)
        #expect(snapshot.fractionComplete == 0.5)
        #expect(snapshot.statusText.contains("%"))
    }

    // MARK: The empty state

    /// Nothing selected: the widget has a trail to draw only if the app gave
    /// it one, and must not fall back to the gallery placeholder, which is not
    /// the user's data.
    @Test("with nothing stored the entry is empty rather than invented")
    func emptyStoreProducesAnEmptyEntry() {
        SharedStore.clear()
        try? SharedStore.clearRecording()

        let entry = TrailWidgetProvider.currentEntry()

        #expect(entry.snapshot == nil)
        #expect(entry.basemaps == nil)
        #expect(entry.deepLinkURL == nil, "there is no trail to open, so a tap should just launch the app")
    }

    /// Deselecting a trail in the app clears the payload, and the widget's
    /// next timeline has to reflect that rather than the trail before it.
    @Test("clearing the store empties the next timeline")
    func clearingEmptiesTheTimeline() throws {
        SharedStore.save(Self.snapshot())
        #expect(TrailWidgetProvider.currentEntry().snapshot != nil, "precondition: a trail was showing")

        SharedStore.clear()
        try? SharedStore.clearRecording()

        let timeline = TrailWidgetProvider.currentTimeline()
        #expect(try #require(timeline.entries.first).snapshot == nil, "a deselected trail must not linger")
    }

    /// The placeholder is what the widget gallery and a redacted widget show.
    /// It has to be obviously generic — never a trail the user has.
    @Test("the placeholder is generic data, not whatever is stored")
    func placeholderIsNeverRealData() throws {
        let stored = Self.snapshot(title: "Somebody's real trail")
        SharedStore.save(stored)

        let placeholder = try #require(TrailWidgetProvider.placeholderEntry().snapshot)

        #expect(placeholder.hikeID != stored.hikeID)
        #expect(placeholder.title != stored.title)
        #expect(placeholder.polyline.count > 1, "it still has to draw as a trail")
    }

    // MARK: Basemap pairing

    /// The rendered map images are only ever valid for the hike they were
    /// rendered for — pairing them with any other trail would draw one trail's
    /// line over another's ground.
    @Test("an entry picks up the basemaps rendered for its own trail")
    func basemapsArePairedWithTheirTrail() throws {
        let stored = Self.snapshot()
        SharedStore.save(stored)
        SharedStore.saveBasemapSet(Self.basemapSet(for: stored.hikeID))

        let entry = TrailWidgetProvider.currentEntry()

        let basemaps = try #require(entry.basemaps)
        #expect(basemaps.hikeID == stored.hikeID)
        #expect(basemaps.images.count == 1)
    }

    @Test("another trail's basemaps are not drawn under this one")
    func basemapsFromAnotherTrailAreRefused() {
        let stored = Self.snapshot()
        SharedStore.save(stored)
        SharedStore.saveBasemapSet(Self.basemapSet(for: UUID()))

        #expect(TrailWidgetProvider.currentEntry().basemaps == nil)
    }

    /// A trail selected offline has no images yet. The widget still draws it —
    /// the line-only glyph — rather than showing nothing.
    @Test("a trail with no rendered map still produces an entry")
    func missingBasemapsStillDrawTheTrail() throws {
        SharedStore.save(Self.snapshot())

        let entry = TrailWidgetProvider.currentEntry()

        #expect(entry.basemaps == nil)
        #expect(try #require(entry.snapshot).polyline.count > 1, "the trail is still there to draw")
    }

    /// `SharedStore.clear()` takes the images with the snapshot; a manifest
    /// left behind would pair with the next trail that happened to share an id
    /// and, more practically, waste the container.
    @Test("clearing the trail clears its rendered maps too")
    func clearingRemovesBasemaps() {
        let stored = Self.snapshot()
        SharedStore.save(stored)
        SharedStore.saveBasemapSet(Self.basemapSet(for: stored.hikeID))

        SharedStore.clear()

        #expect(SharedStore.loadBasemapSet(for: stored.hikeID) == nil)
        #expect(TrailWidgetProvider.currentEntry().basemaps == nil)
    }

    // MARK: Families

    /// Every size the widget offers has to have a layout to draw with, and the
    /// small one is the only one that drops the title.
    @Test("every supported family has a layout, and only the small one hides the title")
    func everyFamilyHasALayout() {
        #expect(TrailWidget.supportedFamilies.contains(.systemSmall))
        for family in TrailWidget.supportedFamilies {
            let layout = TrailWidgetLayout(family: family)
            #expect(layout.showsTitle == (family != .systemSmall), "\(family)")
            #expect(layout.routeLineWidth > 0, "\(family)")
            #expect(layout.padding > 0, "\(family)")
        }
    }

    /// The small widget draws a thinner line and tighter padding — it is the
    /// same trail in a quarter of the area.
    @Test("the small family is drawn more tightly than the larger ones")
    func smallFamilyIsTighter() {
        let small = TrailWidgetLayout(family: .systemSmall)
        for family in TrailWidget.supportedFamilies where family != .systemSmall {
            let larger = TrailWidgetLayout(family: family)
            #expect(small.routeLineWidth < larger.routeLineWidth, "\(family)")
            #expect(small.padding < larger.padding, "\(family)")
            #expect(larger == TrailWidgetLayout(family: .systemMedium), "the larger sizes are drawn alike")
        }
    }

    // MARK: Deep linking

    /// Tapping the widget opens the app straight to the trail it is showing —
    /// which only works if the entry's URL names that trail.
    @Test("tapping a shown trail opens that trail")
    func deepLinkNamesTheShownTrail() throws {
        let stored = Self.snapshot()
        SharedStore.save(stored)

        let url = try #require(TrailWidgetProvider.currentEntry().deepLinkURL)

        #expect(TrailWidgetDeepLink.hikeID(from: url) == stored.hikeID)
    }
}
