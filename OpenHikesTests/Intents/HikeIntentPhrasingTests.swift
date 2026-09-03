//
//  HikeIntentPhrasingTests.swift
//  OpenHikesTests
//
//  What the walker is actually told.
//
//  Nothing here asserts a rendered length or duration *literally*. These
//  sentences are read out in the reader's own units and their own language, so
//  a test spelling "1h 15m" would be asserting the region the machine happens
//  to be set to. What is pinned instead is the shape: that the sentence is
//  built out of the app's own formatting, that a paused hike says so, and that
//  a fact the walker doesn't have — an unnamed trail, a route with no clock —
//  is left out rather than read back blank.
//

import Foundation
@testable import OpenHikes
import Testing

@Suite("Hike intent phrasing")
struct HikeIntentPhrasingTests {
    @Test("a running recording says how far and how long")
    func aRunningRecordingReadsBackItsProgress() {
        let summary = LiveRecordingReport(
            distance: Measurement(value: 5200, unit: .meters),
            elapsed: 4500,
            isPaused: false,
            trailName: nil,
            isTrailNameStale: false
        ).spokenSummary

        #expect(summary.contains("You're"))
        // The *spoken* duration: `HikeFormat.duration` is narrow because a stat
        // tile has room for "1h 25m" and a synthesiser handed it is guessing,
        // which is the same reason the distance beside it is `.wide`.
        #expect(summary.contains(HikeFormat.spokenDuration(4500)))
        #expect(!summary.contains(HikeFormat.duration(4500)))
    }

    @Test("a paused recording says it is paused")
    func aPausedRecordingSaysSo() {
        let summary = LiveRecordingReport(
            distance: Measurement(value: 1000, unit: .meters),
            elapsed: 600,
            isPaused: true,
            trailName: nil,
            isTrailNameStale: false
        ).spokenSummary

        #expect(summary.contains("paused"))
    }

    @Test("a matched trail is named")
    func aMatchedTrailIsNamed() {
        let summary = LiveRecordingReport(
            distance: Measurement(value: 2400, unit: .meters),
            elapsed: 1800,
            isPaused: false,
            trailName: "Kalvarienberg",
            isTrailNameStale: false
        ).spokenSummary

        #expect(summary.contains("on Kalvarienberg"))
        #expect(!summary.contains("last on"))
    }

    /// The recording screen dims this same card when newer fixes have
    /// overtaken the match. This surface is the one used when the walker
    /// cannot look at that screen, so it is the last place to drop the hedge:
    /// somebody who stepped off the path a minute ago must not hear that they
    /// are still on it.
    @Test("a match newer fixes have overtaken is hedged rather than stated")
    func aStaleTrailIsHedged() {
        let summary = LiveRecordingReport(
            distance: Measurement(value: 2400, unit: .meters),
            elapsed: 1800,
            isPaused: false,
            trailName: "Kalvarienberg",
            isTrailNameStale: true
        ).spokenSummary

        #expect(summary.contains("last on Kalvarienberg"))
    }

    @Test("a trail matched to an unnamed way is left out rather than read as blank")
    func anEmptyTrailNameIsOmitted() {
        let summary = LiveRecordingReport(
            distance: Measurement(value: 2400, unit: .meters),
            elapsed: 1800,
            isPaused: false,
            trailName: "",
            isTrailNameStale: false
        ).spokenSummary

        #expect(!summary.contains(" on "))
    }

    @Test("a finished hike is named, measured and dated")
    func aFinishedHikeReadsBackInFull() {
        let summary = FinishedHikeReport(
            id: UUID(),
            title: "Ridge Loop",
            date: Date(timeIntervalSince1970: 1_750_000_000),
            distance: Measurement(value: 8000, unit: .meters),
            duration: 7200
        ).spokenSummary

        #expect(summary.hasPrefix("Ridge Loop:"))
        #expect(summary.contains(HikeFormat.spokenDuration(7200)))
    }

    @Test("an imported route with no clock reports distance without a duration")
    func aHikeWithoutAClockOmitsItsDuration() {
        let summary = FinishedHikeReport(
            id: UUID(),
            title: "Imported Track",
            date: Date(timeIntervalSince1970: 1_750_000_000),
            distance: Measurement(value: 8000, unit: .meters),
            duration: nil
        ).spokenSummary

        #expect(summary.hasPrefix("Imported Track:"))
        #expect(!summary.contains(" in "))
    }

    @Test("a day with nothing on it says so instead of reading out a zero")
    func anEmptyDayIsSaidPlainly() {
        let summary = HikeTotalsReport(
            hikeCount: 0,
            distance: Measurement(value: 0, unit: .meters)
        ).spokenSummary(for: "today")

        #expect(summary == "You haven't recorded a hike today.")
    }

    @Test("one hike is singular and several are not")
    func theHikeCountAgreesWithItself() {
        let one = HikeTotalsReport(
            hikeCount: 1,
            distance: Measurement(value: 4000, unit: .meters)
        ).spokenSummary(for: "today")
        let several = HikeTotalsReport(
            hikeCount: 3,
            distance: Measurement(value: 12_000, unit: .meters)
        ).spokenSummary(for: "today")

        #expect(one.contains("1 hike "))
        #expect(several.contains("3 hikes"))
    }

    @Test("a refusal carries both what went wrong and what to do about it")
    func aRefusalCarriesItsRecovery() {
        let failure = HikeIntentFailure.awaitingRouteReview

        #expect(failure.errorDescription?.contains("pick which trail") == true)
        #expect(failure.recoverySuggestion?.contains("Open OpenHikes") == true)
    }

    /// `.storage` is read aloud as its description *and* its recovery
    /// suggestion in one breath, so a suggestion carrying SwiftData's own
    /// words would have Siri say "Your hikes couldn't be read." followed by a
    /// developer's error string. And the calendar failure is not a store
    /// failure at all — reusing `.storage` for it claimed something false
    /// before saying something unrelated.
    @Test("a store failure is spoken in the app's words rather than the store's")
    func aStoreFailureDoesNotReadOutItsOwnDiagnostics() {
        let storage = HikeIntentFailure.storage
        let day = HikeIntentFailure.unknownDay

        #expect(storage.recoverySuggestion == "Open OpenHikes to check on your hikes.")
        #expect(day.errorDescription?.contains("couldn't be read") == false)
        #expect(day.recoverySuggestion == nil)
    }

    @Test("a recorder failure is passed through in the recorder's own words")
    func aRecorderFailureKeepsItsWording() {
        let failure = HikeIntentFailure.recording(.locationDenied)

        #expect(
            failure.errorDescription == RecordingFailure.locationDenied.errorDescription
        )
        #expect(
            failure.recoverySuggestion
                == RecordingFailure.locationDenied.recoverySuggestion
        )
    }
}
