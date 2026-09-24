//
//  WatchGlanceTests.swift
//  OpenHikesSharedTests
//
//  What the watch complication shows, when it stops believing a glance, and
//  when a redraw is worth spending.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Watch glance")
struct WatchGlanceTests {
    private static let now = Date(timeIntervalSince1970: 1_758_000_000)
    private static let locale = Locale(identifier: "en_GB")

    private static func glance(
        _ state: WatchGlance.State,
        meters: Double = 4200,
        seconds: TimeInterval = 3600,
        at date: Date = now
    ) -> WatchGlance {
        WatchGlance(state: state, distanceMeters: meters, activeSeconds: seconds, updatedAt: date)
    }

    // MARK: What it shows

    @Test("a running recording shows its distance and a clock anchored to its own time")
    func recordingShowsDistanceAndClock() {
        let display = WatchGlanceDisplay(Self.glance(.recording), now: Self.now, locale: Self.locale)
        #expect(display == .recording(
            distance: WidgetFormat.length(meters: 4200, locale: Self.locale),
            timerStart: Self.now.addingTimeInterval(-3600)
        ))
    }

    @Test("a paused one shows its distance and the frozen clock")
    func pausedShowsFrozenClock() {
        let display = WatchGlanceDisplay(Self.glance(.paused), now: Self.now, locale: Self.locale)
        #expect(display == .paused(
            distance: WidgetFormat.length(meters: 4200, locale: Self.locale),
            elapsed: WidgetFormat.duration(seconds: 3600)
        ))
    }

    @Test("nothing recorded, or nothing written, is the app's own glyph")
    func idleOrMissingIsIdle() {
        #expect(WatchGlanceDisplay(nil, now: Self.now) == .idle)
        #expect(WatchGlanceDisplay(.idle(at: Self.now), now: Self.now) == .idle)
    }

    /// A hiker standing still for an hour writes nothing and is still
    /// recording; an app that went away mid-walk is what this catches.
    @Test("a recording glance is believed for hours without a write, and not for ever")
    func staleGlanceIsIdle() {
        let hourOld = Self.glance(.recording, at: Self.now.addingTimeInterval(-3600))
        #expect(WatchGlanceDisplay(hourOld, now: Self.now) != .idle)

        let dayOld = Self.glance(.recording, at: Self.now.addingTimeInterval(-WatchGlanceDisplay.staleAfter))
        #expect(WatchGlanceDisplay(dayOld, now: Self.now) == .idle)
    }

    // MARK: The timeline

    /// Counted from the read, a timeline WidgetKit reloaded five hours in
    /// would believe a dead recording for eleven.
    @Test("a recording's timeline goes idle six hours after the write, not after the read")
    func timelineGoesStaleFromTheWrite() {
        let written = Self.now.addingTimeInterval(-5 * 3600)
        let entries = WatchGlanceTimeline.entries(
            for: Self.glance(.recording, at: written),
            now: Self.now,
            locale: Self.locale
        )
        #expect(entries.map(\.date) == [Self.now, written.addingTimeInterval(WatchGlanceDisplay.staleAfter)])
        #expect(entries.first?.display != .idle)
        #expect(entries.last?.display == .idle)
    }

    @Test("an idle timeline is one entry, with nothing to go stale")
    func idleTimelineIsOneEntry() {
        #expect(WatchGlanceTimeline.entries(for: nil, now: Self.now) == [.init(date: Self.now, display: .idle)])
        #expect(WatchGlanceTimeline.entries(for: .idle(at: Self.now), now: Self.now).count == 1)
    }

    // MARK: When to redraw

    @Test("every change of state redraws")
    func stateChangesReload() {
        #expect(WatchGlanceReloadPolicy.shouldReload(from: nil, to: Self.glance(.idle)))
        #expect(WatchGlanceReloadPolicy.shouldReload(from: Self.glance(.idle), to: Self.glance(.recording)))
        #expect(WatchGlanceReloadPolicy.shouldReload(from: Self.glance(.recording), to: Self.glance(.paused)))
        #expect(WatchGlanceReloadPolicy.shouldReload(from: Self.glance(.paused), to: Self.glance(.recording)))
    }

    /// A reload per fix would spend the day's budget in the first hour.
    @Test("the distance redraws only far enough and long enough after the last")
    func distanceIsThrottled() {
        let last = Self.glance(.recording, meters: 1000)
        let soonFar = Self.glance(.recording, meters: 2000, at: Self.now.addingTimeInterval(60))
        let lateNear = Self.glance(.recording, meters: 1100, at: Self.now.addingTimeInterval(3600))
        let lateFar = Self.glance(
            .recording,
            meters: 1000 + WatchGlanceReloadPolicy.minimumDistanceMeters,
            at: Self.now.addingTimeInterval(WatchGlanceReloadPolicy.minimumInterval)
        )
        #expect(!WatchGlanceReloadPolicy.shouldReload(from: last, to: soonFar))
        #expect(!WatchGlanceReloadPolicy.shouldReload(from: last, to: lateNear))
        #expect(WatchGlanceReloadPolicy.shouldReload(from: last, to: lateFar))
    }

    @Test("a paused recording's figures do not redraw")
    func pausedDoesNotReload() {
        let paused = Self.glance(.paused, meters: 1000)
        let later = Self.glance(.paused, meters: 5000, at: Self.now.addingTimeInterval(3600))
        #expect(!WatchGlanceReloadPolicy.shouldReload(from: paused, to: later))
    }

    // MARK: The store

    @Test("a glance written is the glance read back")
    func storeRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "glance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(WatchGlanceStore.load(from: directory) == nil)
        let glance = Self.glance(.recording)
        #expect(WatchGlanceStore.save(glance, to: directory))
        #expect(WatchGlanceStore.load(from: directory) == glance)
    }
}
