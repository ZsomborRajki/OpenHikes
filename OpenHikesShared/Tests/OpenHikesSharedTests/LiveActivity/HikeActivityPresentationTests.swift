//
//  HikeActivityPresentationTests.swift
//  OpenHikesSharedTests
//
//  "Hike activity presentation", split out of HikeActivityTests.swift, which had outgrown the
//  500-line file limit. That file's header still holds the context the three
//  share.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Hike activity presentation")
struct HikeActivityPresentationTests {
    private static let locale = Locale(identifier: "en_GB")

    private static let recordingAttributes = HikeActivityAttributes.recording(
        sessionID: UUID(),
        title: "Morning walk",
        tintHex: "#34C759",
        startedAt: Date(timeIntervalSince1970: 1_000_000)
    )

    private static let followingAttributes = HikeActivityAttributes(
        subject: .following(hikeID: UUID()),
        title: "Thumsee Loop",
        tintHex: "#FF9500",
        startedAt: Date(timeIntervalSince1970: 1_000_000),
        routeDistanceMeters: 10_000
    )

    private static let runningRecording = HikeActivityAttributes.ContentState(
        distanceMeters: 4200,
        elevationGainMeters: 320,
        averageSpeedMetersPerSecond: 1.17,
        pointCount: 812,
        elapsedSeconds: 3600
    )

    /// A recording has no end, so a progress bar would be a decoration and the
    /// clock has to run without the app sending anything.
    @Test("a running recording ticks its own clock and shows no progress")
    func runningRecordingTicksItsOwnClock() {
        let presentation = Self.recordingAttributes.presentation(
            for: Self.runningRecording,
            locale: Self.locale
        )
        #expect(presentation.showsElapsedTimer)
        #expect(presentation.progress == nil)
        #expect(presentation.statusLabel == nil)
        #expect(presentation.secondaryValue == nil)
        #expect(presentation.primaryCaption == "Distance")
        #expect(presentation.symbolName == "figure.hiking")
    }

    /// A paused clock must not tick, which is the one thing
    /// `Text(timerInterval:)` cannot be told to do.
    @Test("a paused recording stops the clock and says so")
    func pausedRecordingStopsTheClock() {
        var paused = Self.runningRecording
        paused.runState = .paused
        let presentation = Self.recordingAttributes.presentation(
            for: paused,
            locale: Self.locale
        )
        #expect(!presentation.showsElapsedTimer)
        #expect(presentation.statusLabel == "Paused")
        #expect(presentation.secondaryValue == presentation.elapsedText)
        #expect(presentation.elapsedText == "1:00:00")
        #expect(presentation.accessibilityLabel.contains("paused"))
    }

    /// The panel a saved hike leaves behind. It has to be distinguishable
    /// from a paused one — the walk is over, and a final card reading
    /// "Paused" would say the opposite.
    @Test("a finished recording says finished, not paused")
    func finishedRecordingIsNotPaused() {
        let finished = Self.runningRecording.finished()
        let presentation = Self.recordingAttributes.presentation(
            for: finished,
            locale: Self.locale
        )
        #expect(!finished.isPaused)
        #expect(!finished.isTicking)
        #expect(!presentation.showsElapsedTimer)
        #expect(presentation.statusLabel == "Finished")
        #expect(presentation.secondaryValue == presentation.elapsedText)
        #expect(presentation.symbolName == "checkmark.circle.fill")
        #expect(presentation.accessibilityLabel.contains("finished"))
    }

    /// `finished()` marks, it does not recompute — the figures on the final
    /// card are the ones the hiker was looking at when they hit Stop.
    @Test("finishing keeps every figure it was handed")
    func finishingChangesNothingElse() {
        let finished = Self.runningRecording.finished()
        #expect(finished.distanceMeters == Self.runningRecording.distanceMeters)
        #expect(finished.elapsedSeconds == Self.runningRecording.elapsedSeconds)
        #expect(finished.elevationGainMeters == Self.runningRecording.elevationGainMeters)
        #expect(finished.updatedAt == Self.runningRecording.updatedAt)
    }

    @Test("a recording's chips are the widget's, most useful first")
    func recordingChipsMatchTheWidget() {
        let presentation = Self.recordingAttributes.presentation(
            for: Self.runningRecording,
            locale: Self.locale
        )
        #expect(presentation.metrics.map(\.kind) == [.ascent, .pace, .points])
    }

    /// Same truncation rule as the widget: drop the least useful, never
    /// reorder.
    @Test("a narrow family keeps the most useful chips")
    func narrowFamilyKeepsTheMostUsefulChips() {
        let presentation = Self.recordingAttributes.presentation(
            for: Self.runningRecording,
            metricLimit: 1,
            locale: Self.locale
        )
        #expect(presentation.metrics.map(\.kind) == [.ascent])
    }

    /// A recording that has just started has no pace and no points, and shows
    /// fewer chips rather than a row of zeroes.
    @Test("a recording with nothing to report omits chips rather than faking them")
    func emptyRecordingOmitsChips() {
        let presentation = Self.recordingAttributes.presentation(
            for: HikeActivityAttributes.ContentState(distanceMeters: 0),
            locale: Self.locale
        )
        #expect(presentation.metrics.isEmpty)
    }

    @Test("a followed trail leads with how much of it is done")
    func followingLeadsWithProgress() {
        let presentation = Self.followingAttributes.presentation(
            for: HikeActivityAttributes.ContentState(
                distanceMeters: 6200,
                elevationGainMeters: 540,
                currentElevationMeters: 780,
                offRouteMeters: 8
            ),
            locale: Self.locale
        )
        #expect(presentation.primaryValue == "62%")
        #expect(presentation.primaryCaption == "Complete")
        #expect(presentation.progress == 0.62)
        #expect(presentation.statusLabel == nil)
        #expect(presentation.secondaryCaption == "Remaining")
        #expect(presentation.metrics.map(\.kind) == [.currentElevation, .ascent])
        #expect(presentation.accessibilityValue.contains("62 percent complete"))
    }

    /// Claiming 0% for a hiker who has merely lost the trail would be a
    /// confident wrong answer; the trail's own length is the honest one.
    @Test("losing the trail falls back to its length rather than claiming zero")
    func losingTheTrailFallsBackToItsLength() {
        let presentation = Self.followingAttributes.presentation(
            for: HikeActivityAttributes.ContentState(
                distanceMeters: 6200,
                elevationGainMeters: 540
            ),
            locale: Self.locale
        )
        #expect(presentation.progress == nil)
        #expect(presentation.statusLabel == "Off trail")
        #expect(presentation.symbolName == "exclamationmark.triangle.fill")
        #expect(presentation.primaryCaption == "Trail length")
        #expect(presentation.secondaryValue == nil)
        #expect(presentation.accessibilityLabel.contains("off trail"))
    }

    /// A follow has no clock of its own: the trail may have been open for
    /// hours before the hiker set off.
    @Test("a followed trail never runs a clock")
    func followingNeverRunsAClock() {
        let presentation = Self.followingAttributes.presentation(
            for: HikeActivityAttributes.ContentState(
                distanceMeters: 100,
                offRouteMeters: 2
            ),
            locale: Self.locale
        )
        #expect(!presentation.showsElapsedTimer)
    }

    /// The numbers are formatted through the same functions the widget uses,
    /// which is what this compares against rather than a literal.
    @Test("the numbers are the widget's, not a second rounding of them")
    func numbersAreTheWidgets() {
        let presentation = Self.recordingAttributes.presentation(
            for: Self.runningRecording,
            locale: Self.locale
        )
        #expect(
            presentation.primaryValue
                == WidgetFormat.length(meters: 4200, locale: Self.locale)
        )
        #expect(
            presentation.metrics.first?.value
                == WidgetFormat.elevation(meters: 320, locale: Self.locale)
        )
    }

    @Test("the spoken phrase never contains an empty fragment")
    func spokenPhraseHasNoEmptyFragments() {
        let presentation = Self.recordingAttributes.presentation(
            for: HikeActivityAttributes.ContentState(distanceMeters: 0),
            locale: Self.locale
        )
        #expect(!presentation.accessibilityValue.contains(", ,"))
        #expect(!presentation.accessibilityValue.hasSuffix(", "))
    }
}
