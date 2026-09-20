//
//  TrailWidgetWeatherTests.swift
//  OpenWidgetTests
//
//  The temperature in the widget's top-left corner is the one figure it draws
//  that the app does not compute per trail: it belongs to whatever the weather
//  badge is pointed at, arrives through a file of its own, and is the only
//  thing both the trail and the recording states draw the same way.
//
//  Two things about it can only be asked here rather than of the payload.
//  Whether the entry drops a reading that has gone off — the entry is built
//  for a date, and the drop has to be measured against *that* date rather than
//  against whenever the store happened to be read. And whether the timeline
//  wakes up to do the dropping, which is the difference between a corner that
//  empties on time and one that carries a breakfast reading into the evening.
//

import Foundation
import OpenHikesShared
import Testing
import WidgetKit

extension TrailWidgetStoreSuites {
@Suite("Trail widget weather", .serialized)
struct TrailWidgetWeatherTests {
    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// Optional because the initializer is — it refuses a non-finite
    /// temperature, which `12` is not. Unwrapped at each call site rather than
    /// forced here, so a change that made it refuse this too would fail one
    /// test with a name rather than crash the bundle.
    private static func reading(ageMinutes: Double) -> SharedWeatherReading? {
        SharedWeatherReading(
            temperatureCelsius: 12,
            capturedAt: now.addingTimeInterval(-ageMinutes * 60)
        )
    }

    init() {
        SharedStore.clearWeatherReading()
        SharedStore.clear()
        try? SharedStore.clearRecording()
    }

    // MARK: What the entry carries

    @Test("a fresh reading reaches the entry")
    func freshReadingReachesTheEntry() throws {
        SharedStore.save(TrailWidgetTests.snapshot())
        SharedStore.saveWeatherReading(try #require(Self.reading(ageMinutes: 20)))

        let entry = TrailWidgetProvider.currentEntry(date: Self.now)

        #expect(try #require(entry.weather).temperatureCelsius == 12)
    }

    /// Past ``SharedWeatherReading/maximumAge`` the widget says nothing rather
    /// than something stale — a temperature is safety information on a hike.
    @Test("a reading past its age is dropped rather than drawn")
    func staleReadingIsDropped() throws {
        SharedStore.save(TrailWidgetTests.snapshot())
        SharedStore.saveWeatherReading(try #require(Self.reading(ageMinutes: 3 * 60 + 1)))

        #expect(TrailWidgetProvider.currentEntry(date: Self.now).weather == nil)
    }

    /// Against the entry's own date, not the clock. A timeline entry built for
    /// an hour from now has to know what the corner will say then.
    @Test("the age is measured against the entry's date")
    func ageIsMeasuredAgainstTheEntryDate() throws {
        SharedStore.save(TrailWidgetTests.snapshot())
        SharedStore.saveWeatherReading(try #require(Self.reading(ageMinutes: 170)))

        #expect(TrailWidgetProvider.currentEntry(date: Self.now).weather != nil)
        #expect(
            TrailWidgetProvider
                .currentEntry(date: Self.now.addingTimeInterval(20 * 60))
                .weather == nil
        )
    }

    /// The reading belongs to the badge rather than to the trail, so the
    /// recording taking the widget does not take the temperature with it —
    /// unlike the trail snapshot and its basemaps, which it discards outright.
    @Test("a recording keeps the temperature it does not own")
    func recordingKeepsTheTemperature() throws {
        SharedStore.save(TrailWidgetTests.snapshot())
        SharedStore.saveWeatherReading(try #require(Self.reading(ageMinutes: 5)))
        try SharedStore.saveRecording(
            SharedRecordingSnapshot(
                sessionID: UUID(),
                startedAt: Self.now.addingTimeInterval(-600),
                distanceMeters: 900,
                pointCount: 40,
                polyline: [.init(latitude: 47.63, longitude: 12.86)]
            )
        )

        let entry = TrailWidgetProvider.currentEntry(date: Self.now)

        #expect(entry.snapshot == nil, "the recording takes the trail")
        #expect(entry.weather != nil, "but not the conditions")
    }

    // MARK: When the timeline comes back

    @Test("the timeline wakes when the reading goes off")
    func timelineWakesAtExpiry() {
        let expiry = Self.now.addingTimeInterval(40 * 60)

        let next = TrailWidgetProvider.nextReload(after: Self.now, weatherExpiresAt: expiry)

        #expect(next == expiry)
    }

    /// It may only ever bring the date forward. A reading that expires next
    /// week does not buy the widget a week of silence, and one that expired
    /// before this entry was built is not a date to schedule into the past.
    @Test("a distant or past expiry leaves the schedule alone")
    func expiryOnlyMovesTheDateEarlier() {
        let scheduled = TrailWidgetProvider.nextReload(after: Self.now)

        #expect(
            TrailWidgetProvider.nextReload(
                after: Self.now,
                weatherExpiresAt: Self.now.addingTimeInterval(7 * 24 * 3600)
            ) == scheduled
        )
        #expect(
            TrailWidgetProvider.nextReload(
                after: Self.now,
                weatherExpiresAt: Self.now.addingTimeInterval(-60)
            ) == scheduled
        )
    }

    /// A recording is on a twenty-minute timeline of its own, which is already
    /// sooner than most expiries — but not all of them, and the shorter of the
    /// two is what keeps both figures honest.
    @Test("the recording cadence and the expiry take whichever is sooner")
    func recordingTakesTheSooner() {
        let soon = Self.now.addingTimeInterval(5 * 60)

        #expect(
            TrailWidgetProvider.nextReload(
                after: Self.now,
                recording: true,
                weatherExpiresAt: soon
            ) == soon
        )
        #expect(
            TrailWidgetProvider.nextReload(
                after: Self.now,
                recording: true,
                weatherExpiresAt: Self.now.addingTimeInterval(60 * 60)
            ) == TrailWidgetProvider.nextReload(after: Self.now, recording: true)
        )
    }

    /// The refresh date is a *request*: WidgetKit defers a reload for a widget
    /// that has overrun its budget or a device in Low Power Mode, and a
    /// one-entry timeline would keep drawing the expired number for as long as
    /// that lasts. The second entry needs no permission to be shown.
    @Test("the timeline carries the entry that draws no temperature")
    func timelineCarriesTheEmptiedEntry() throws {
        SharedStore.save(TrailWidgetTests.snapshot())
        let reading = try #require(Self.reading(ageMinutes: 20))
        SharedStore.saveWeatherReading(reading)

        let timeline = TrailWidgetProvider.currentTimeline(date: Self.now)

        #expect(timeline.entries.count == 2)
        let dropped = try #require(timeline.entries.last)
        #expect(dropped.date == reading.expiresAt)
        #expect(dropped.weather == nil, "the corner empties on time whether or not the reload lands")
        #expect(dropped.snapshot?.hikeID == timeline.entries.first?.snapshot?.hikeID)
    }

    /// A reading already past its age is dropped by the entry itself, so there
    /// is nothing to schedule an emptying for.
    @Test("an expired reading adds no second entry")
    func expiredReadingAddsNoEntry() throws {
        SharedStore.save(TrailWidgetTests.snapshot())
        SharedStore.saveWeatherReading(
            try #require(Self.reading(ageMinutes: SharedWeatherReading.maximumAge / 60 + 10))
        )

        let timeline = TrailWidgetProvider.currentTimeline(date: Self.now)

        #expect(timeline.entries.count == 1)
    }

    // MARK: What VoiceOver gets

    /// Nothing on a Home Screen family is drawn *and* spoken any more: the
    /// status line is gone from the screen, the chips are hidden, and the
    /// temperature has no words of its own. This sentence is the whole widget
    /// for a reader who cannot take the glance.
    @Test("the spoken value carries the status, the chips and the temperature")
    func spokenValueCarriesEverything() throws {
        let reading = try #require(Self.reading(ageMinutes: 5))
        let spoken = TrailWidgetSpeech.value(
            status: "62% walked · 1.4 km left",
            metrics: "Ascent 420 m, Length 2.6 km",
            weather: reading
        )

        #expect(spoken.hasPrefix("62% walked"))
        #expect(spoken.contains("Ascent 420 m"))
        #expect(spoken.contains(reading.spoken()))
    }

    /// The figures the chips carry are not said twice. The trail's length is a
    /// chip now, and it is also what `statusText` falls back to when there is
    /// no live fix — the state a placed widget is in most of the time — so the
    /// spoken value is built from the progress half of that line rather than
    /// from the line.
    @Test("a figure that is already a chip is not spoken twice")
    func nothingIsSaidTwice() {
        let snapshot = TrailWidgetTests.snapshot()
        let length = WidgetFormat.length(meters: snapshot.totalDistanceMeters)

        let spoken = TrailWidgetSpeech.value(
            status: snapshot.progressStatusText,
            metrics: snapshot.metricsAccessibilityText(limit: 2),
            weather: nil
        )

        #expect(spoken.contains(length))
        #expect(
            spoken.components(separatedBy: length).count == 2,
            "once, from the chip — the status line's fallback is the same number"
        )
    }

    /// The same rule for a recording, whose status line is a distance and a
    /// point count and whose chips now carry that distance.
    @Test("a recording's distance is spoken once, and its point count survives")
    func recordingSaysItsDistanceOnce() {
        let recording = SharedRecordingSnapshot(
            sessionID: UUID(),
            startedAt: Self.now.addingTimeInterval(-3600),
            distanceMeters: 1400,
            pointCount: 320,
            polyline: [.init(latitude: 47.5, longitude: 12.9)],
            elevationGainMeters: 180
        )
        let walked = WidgetFormat.length(meters: 1400)

        let spoken = TrailWidgetSpeech.value(
            status: recording.pointCountText,
            metrics: recording.metricsAccessibilityText(limit: 2),
            weather: nil
        )

        #expect(spoken.contains("320 pts"))
        #expect(spoken.components(separatedBy: walked).count == 2)
    }

    /// A missing part is omitted rather than announced, which is the rule the
    /// chips already follow — "no temperature" is not something to say.
    @Test("nothing is announced for a figure that is missing")
    func missingFiguresAreOmitted() {
        #expect(
            TrailWidgetSpeech.value(status: "2.6 km", metrics: "", weather: nil) == "2.6 km"
        )
        #expect(TrailWidgetSpeech.value(status: "", metrics: "", weather: nil).isEmpty)
    }
}
}
