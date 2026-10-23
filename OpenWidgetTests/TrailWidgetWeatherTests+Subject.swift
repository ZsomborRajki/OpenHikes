//
//  TrailWidgetWeatherTests+Subject.swift
//  OpenWidgetTests
//
//  Which widget the temperature is drawn on (#1000).
//
//  There is one reading and there can be several widgets: one following the
//  selection, others pinned to trails of their own (#468). The reading is
//  whatever the app's badge last showed, which follows the hiker's browsing —
//  so before it said what it was about, a widget pinned to an Alpine ridge
//  drew the temperature of whichever city the hiker had last searched, with
//  no name beside it, and said it aloud as the ridge's.
//
//  So each entry keeps the reading only when it describes what that entry
//  draws: the trail it was taken for, or the hiker a recording is following.
//  Everything here is asserted twice, because a sighted reader and a VoiceOver
//  reader are told by different halves of the widget: the corner the entry's
//  `weather` puts a number in, and the single spoken value built from the
//  same field.
//
//  An extension rather than a suite of its own, for the reason
//  `TrailWidgetTests+Pinned.swift` is one: `init()` there resets the App
//  Group before every test below, and the parent suite is what serializes
//  them against the one container they all write.
//

import Foundation
import OpenHikesShared
import Testing
import WidgetKit

extension TrailWidgetStoreSuites.TrailWidgetWeatherTests {
    private static let ridge = TrailWidgetStoreSuites.TrailWidgetTests.snapshot(
        hikeID: UUID(),
        title: "Watzmann Ridge"
    )
    private static let cityTrail = TrailWidgetStoreSuites.TrailWidgetTests.snapshot(
        hikeID: UUID(),
        title: "Gellért Hill"
    )

    /// Both trails pinned, which is the arrangement the issue describes: two
    /// widgets, one file.
    private static func pinBothTrails() {
        SharedStore.saveTrailSnapshot(ridge)
        SharedStore.saveTrailSnapshot(cityTrail)
    }

    @discardableResult private static func publish(
        about subject: SharedWeatherReading.Subject,
        celsius: Double = 12
    ) throws -> SharedWeatherReading {
        let reading = try #require(Self.reading(ageMinutes: 5, about: subject, celsius: celsius))
        SharedStore.saveWeatherReading(reading)
        return reading
    }

    /// What VoiceOver reads for `entry`, built the way `TrailWidgetContent`
    /// builds it: from the entry's own `weather`, so a reading the entry
    /// dropped is a reading nobody hears either.
    private static func spoken(_ entry: TrailWidgetEntry) throws -> String {
        let snapshot = try #require(entry.snapshot)
        return TrailWidgetSpeech.value(
            status: snapshot.progressStatusText,
            metrics: snapshot.metricsAccessibilityText(limit: 2),
            weather: entry.weather
        )
    }

    // MARK: Two pinned trails, one reading

    @Test("a reading is drawn beside the trail it was taken for and no other")
    func aReadingIsDrawnOnlyBesideItsOwnTrail() throws {
        Self.pinBothTrails()
        let reading = try Self.publish(about: .trail(hikeID: Self.ridge.hikeID))

        let ridgeEntry = TrailWidgetProvider.currentEntry(date: Self.now, pinnedTo: Self.ridge.hikeID)
        let cityEntry = TrailWidgetProvider.currentEntry(date: Self.now, pinnedTo: Self.cityTrail.hikeID)

        #expect(ridgeEntry.weather?.formatted() == reading.formatted())
        #expect(try Self.spoken(ridgeEntry).contains(reading.spoken()))
        #expect(cityEntry.snapshot?.title == "Gellért Hill", "the city trail is still drawn")
        #expect(cityEntry.weather == nil, "but not with the ridge's temperature in its corner")
        #expect(try !Self.spoken(cityEntry).contains(reading.spoken()))
    }

    /// The app moving on — opening the other trail — moves the number with
    /// it, and the trail it left keeps its map and loses the temperature.
    @Test("a new focus moves the temperature to the trail it is now about")
    func aNewFocusMovesTheTemperature() throws {
        Self.pinBothTrails()
        let before = try Self.publish(about: .trail(hikeID: Self.ridge.hikeID), celsius: 4)
        let after = try Self.publish(about: .trail(hikeID: Self.cityTrail.hikeID), celsius: 24)

        let ridgeEntry = TrailWidgetProvider.currentEntry(date: Self.now, pinnedTo: Self.ridge.hikeID)
        let cityEntry = TrailWidgetProvider.currentEntry(date: Self.now, pinnedTo: Self.cityTrail.hikeID)

        #expect(ridgeEntry.weather == nil)
        #expect(try !Self.spoken(ridgeEntry).contains(after.spoken()))
        #expect(try !Self.spoken(ridgeEntry).contains(before.spoken()), "and nothing remembers the old one")
        #expect(cityEntry.weather?.formatted() == after.formatted())
        #expect(try Self.spoken(cityEntry).contains(after.spoken()))
    }

    /// The issue's own case: searching for a city takes the badge there, and
    /// that is no trail's weather — neither a pinned one's nor the selected
    /// one's. Nor is a reading about the hiker, whose position the widget
    /// cannot compare with a trail; the app does, and a selected trail's
    /// reading follows the hiker along it under the trail's own name.
    @Test(
        "a searched place's reading, or the hiker's, is drawn beside no trail",
        arguments: [SharedWeatherReading.Subject.place, .hiker]
    )
    func aReadingAboutNoTrailIsDrawnBesideNone(subject: SharedWeatherReading.Subject) throws {
        Self.pinBothTrails()
        SharedStore.save(Self.ridge)
        let reading = try Self.publish(about: subject)

        let entries = [
            TrailWidgetProvider.currentEntry(date: Self.now),
            TrailWidgetProvider.currentEntry(date: Self.now, pinnedTo: Self.ridge.hikeID),
            TrailWidgetProvider.currentEntry(date: Self.now, pinnedTo: Self.cityTrail.hikeID),
        ]

        for entry in entries {
            #expect(entry.snapshot != nil)
            #expect(entry.weather == nil)
            #expect(try !Self.spoken(entry).contains(reading.spoken()))
        }
    }

    /// A widget that drops the reading has nothing to drop later, so it
    /// schedules no second entry for the moment the reading goes off.
    @Test("a reading about another trail schedules no emptying")
    func aReadingAboutAnotherTrailSchedulesNothing() throws {
        Self.pinBothTrails()
        try Self.publish(about: .trail(hikeID: Self.ridge.hikeID))

        let timeline = TrailWidgetProvider.currentTimeline(date: Self.now, pinnedTo: Self.cityTrail.hikeID)

        #expect(timeline.entries.count == 1)
        #expect(timeline.entries.first?.weather == nil)
    }

    // MARK: The recording

    /// A recording owns the badge and points it at the hiker, so a reading
    /// about a trail or a place is one browsed before it began — still in the
    /// file only because the first reading about the hiker is on its way.
    @Test("a recording drops a reading about a trail or a place")
    func aRecordingDropsAReadingAboutSomewhereElse() throws {
        SharedStore.save(Self.ridge)
        try SharedStore.saveRecording(TrailWidgetStoreSuites.TrailWidgetTests.recordingSnapshot())

        for subject in [SharedWeatherReading.Subject.trail(hikeID: Self.ridge.hikeID), .place] {
            try Self.publish(about: subject)

            let entry = TrailWidgetProvider.currentEntry(date: Self.now)

            #expect(entry.recordingSnapshot != nil)
            #expect(entry.weather == nil, "a reading about \(subject)")
        }
    }
}
