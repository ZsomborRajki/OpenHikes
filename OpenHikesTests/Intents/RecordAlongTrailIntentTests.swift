//
//  RecordAlongTrailIntentTests.swift
//  OpenHikesTests
//
//  The sentence #481 was actually about.
//
//  The recording half is `HikeIntentCoordinatorTests`' and is not repeated
//  here: this intent calls the same `startRecording()` every other path does.
//  What is new is the confirmation, and the confirmation *is* the decision —
//  three ways out were weighed on that issue and the one taken is "say it
//  back", so an intent that started a recording and said nothing about the
//  trail would be a different decision wearing this one's name.
//
//  Reached through a seam rather than through `perform()`, which only the
//  system can run — the same split every intent in this folder is built
//  around.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Recording along a named trail")
struct RecordAlongTrailIntentTests {
    private static func report(trailName: String? = nil) -> LiveRecordingReport {
        LiveRecordingReport(
            distance: Measurement(value: 0, unit: UnitLength.meters),
            elapsed: 0,
            isPaused: false,
            trailName: trailName,
            isTrailNameStale: false
        )
    }

    /// The whole point. A hiker who names a trail is told it is being
    /// followed, because the widget is about to show the recording instead.
    @Test("the dialog names the trail the hiker asked for")
    func speaksTheTrailBack() {
        let spoken = RecordAlongTrailIntent.confirmation(
            following: "Rennsteig",
            recording: Self.report()
        )

        #expect(spoken.contains("Rennsteig"))
    }

    /// **The trail asked for, not the one matched.** `LiveRecordingReport`'s
    /// own `trailName` is whatever OpenStreetMap way the live matcher has
    /// snapped to, which at the moment a recording starts is usually nothing
    /// and is never guaranteed to be the route the hiker named. Speaking that
    /// one would answer a question nobody asked.
    @Test("the matched OSM way does not displace the trail that was named")
    func prefersTheNamedTrailOverTheMatchedOne() {
        let spoken = RecordAlongTrailIntent.confirmation(
            following: "Rennsteig",
            recording: Self.report(trailName: "Unnamed Path")
        )

        #expect(spoken.contains("Rennsteig"))
        #expect(!spoken.contains("Unnamed Path"))
    }

    /// An entity with no name to speak falls back to exactly what
    /// `StartHikeRecordingIntent` would have said, because that is what this
    /// has become.
    @Test("an unnamed trail falls back to the plain recording confirmation")
    func fallsBackWhenThereIsNoNameToSpeak() {
        let spoken = RecordAlongTrailIntent.confirmation(
            following: "",
            recording: Self.report()
        )

        #expect(spoken == "Recording your hike.")
    }

    @Test("an unnamed trail still speaks a matched way when there is one")
    func usesTheMatchedWayOnlyAsAFallback() {
        let spoken = RecordAlongTrailIntent.confirmation(
            following: "",
            recording: Self.report(trailName: "Rennsteig")
        )

        #expect(spoken == "Recording your hike on Rennsteig.")
    }
}
