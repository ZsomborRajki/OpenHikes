//
//  HikeActivityTests.swift
//  OpenHikesSharedTests
//
//  The Live Activity's payload and everything it says, pinned here because
//  this is the widest surface a test can reach: `ActivityConfiguration` is a
//  view tree the system renders out of process, and `Activity` and
//  `ActivityContent` are `@available(macOS, unavailable)` — so the presentation
//  is deliberately a plain value, and this is what checks it.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Hike activity payload")
struct HikeActivityPayloadTests {
    private static func recordingSnapshot(
        distance: Double = 4200,
        points: Int = 812,
        capturing: Bool = true,
        startedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_003_600)
    ) -> SharedRecordingSnapshot {
        SharedRecordingSnapshot(
            sessionID: UUID(),
            startedAt: startedAt,
            distanceMeters: distance,
            pointCount: points,
            polyline: [],
            elevationGainMeters: 320,
            averageSpeedMetersPerSecond: 1.17,
            isCapturingFixes: capturing,
            updatedAt: updatedAt
        )
    }

    private static func trailSnapshot(
        liveFix: SharedTrailSnapshot.LiveFix? = nil
    ) -> SharedTrailSnapshot {
        SharedTrailSnapshot(
            hikeID: UUID(),
            title: "Thumsee Loop",
            tintHex: "#FF9500",
            totalDistanceMeters: 10_000,
            polyline: [.init(latitude: 47.7, longitude: 12.8)],
            elevationGainMeters: 540,
            liveFix: liveFix
        )
    }

    private static func liveFix(
        distance: Double = 6200,
        offRoute: Double = 8,
        elevation: Double? = 780
    ) -> SharedTrailSnapshot.LiveFix {
        SharedTrailSnapshot.LiveFix(
            coordinate: .init(latitude: 47.7, longitude: 12.8),
            distanceAlongRouteMeters: distance,
            offRouteMeters: offRoute,
            timestamp: .now,
            elevationMeters: elevation
        )
    }

    @Test("a recording's activity is built from the widget's own snapshot")
    func recordingIsBuiltFromTheWidgetSnapshot() {
        let snapshot = Self.recordingSnapshot()
        let attributes = HikeActivityAttributes.recording(
            from: snapshot,
            title: "Morning walk",
            tintHex: "#34C759"
        )

        #expect(attributes.subject == .recording(sessionID: snapshot.sessionID))
        #expect(attributes.startedAt == snapshot.startedAt)
        // No end to measure against; the presentation's whole shape follows.
        #expect(attributes.routeDistanceMeters == nil)

        let state = HikeActivityAttributes.ContentState(recording: snapshot)
        #expect(state.distanceMeters == snapshot.distanceMeters)
        #expect(state.elevationGainMeters == snapshot.elevationGainMeters)
        #expect(state.pointCount == snapshot.pointCount)
        #expect(state.averageSpeedMetersPerSecond == snapshot.averageSpeedMetersPerSecond)
        #expect(!state.isPaused)
    }

    /// `isCapturingFixes` is the recorder's own word for it, and the activity
    /// must not invent a second definition of paused.
    @Test("a recording that stopped capturing reads as paused")
    func pausedFollowsIsCapturingFixes() {
        let state = HikeActivityAttributes.ContentState(
            recording: Self.recordingSnapshot(capturing: false)
        )
        #expect(state.isPaused)
    }

    /// The elapsed figure is carried as a duration precisely so this holds:
    /// the view anchors a self-ticking timer at `timerStart`, and it has to
    /// read back the number the recorder measured.
    @Test("the timer anchor reproduces the elapsed time at the update instant")
    func timerAnchorReproducesElapsed() {
        let updatedAt = Date(timeIntervalSince1970: 1_003_600)
        let state = HikeActivityAttributes.ContentState(
            distanceMeters: 100,
            elapsedSeconds: 3600,
            updatedAt: updatedAt
        )
        #expect(state.timerStart == updatedAt.addingTimeInterval(-3600))
        #expect(updatedAt.timeIntervalSince(state.timerStart) == 3600)
    }

    /// The recorder measures from system uptime so a clock correction can't
    /// make the Lock Screen jump; passing it in is what preserves that.
    @Test("an explicit elapsed time wins over wall-clock arithmetic")
    func explicitElapsedWins() {
        let snapshot = Self.recordingSnapshot()
        let derived = HikeActivityAttributes.ContentState(recording: snapshot)
        #expect(derived.elapsedSeconds == 3600)

        let measured = HikeActivityAttributes.ContentState(
            recording: snapshot,
            elapsedSeconds: 2950
        )
        #expect(measured.elapsedSeconds == 2950)
    }

    @Test("a followed trail's activity is built from the widget's own snapshot")
    func followingIsBuiltFromTheWidgetSnapshot() {
        let snapshot = Self.trailSnapshot(liveFix: Self.liveFix())
        let attributes = HikeActivityAttributes.following(from: snapshot)

        #expect(attributes.subject == .following(hikeID: snapshot.hikeID))
        #expect(attributes.title == snapshot.title)
        #expect(attributes.tintHex == snapshot.tintHex)
        #expect(attributes.routeDistanceMeters == snapshot.totalDistanceMeters)

        let state = HikeActivityAttributes.ContentState(following: snapshot)
        #expect(state.distanceMeters == 6200)
        #expect(state.offRouteMeters == 8)
        #expect(state.currentElevationMeters == 780)
        #expect(state.elevationGainMeters == 540)
    }

    /// A walker who has stepped off the trail is not an error state and not a
    /// reason to end the activity — the trail's own numbers stay, and only the
    /// position is withheld.
    @Test("no live fix withholds the position rather than reporting zero")
    func noLiveFixWithholdsPosition() {
        let state = HikeActivityAttributes.ContentState(
            following: Self.trailSnapshot(liveFix: nil)
        )
        #expect(state.offRouteMeters == nil)
        #expect(state.currentElevationMeters == nil)
        // Still the trail's ascent: that fact doesn't depend on where the
        // walker is.
        #expect(state.elevationGainMeters == 540)
    }

    /// The progress arithmetic has to agree with the widget's, which is what
    /// this compares it against rather than against a hand-computed constant.
    @Test("progress agrees with the widget snapshot it was built from")
    func progressAgreesWithTheWidget() {
        let snapshot = Self.trailSnapshot(liveFix: Self.liveFix())
        let attributes = HikeActivityAttributes.following(from: snapshot)
        let state = HikeActivityAttributes.ContentState(following: snapshot)

        #expect(attributes.fractionComplete(for: state) == snapshot.fractionComplete)
        #expect(
            attributes.remainingDistanceMeters(for: state)
                == snapshot.remainingDistanceMeters
        )
    }

    @Test("progress is absent without a fix and clamped past the end")
    func progressIsAbsentOrClamped() {
        let attributes = HikeActivityAttributes.following(
            from: Self.trailSnapshot()
        )
        #expect(attributes.fractionComplete(for: .init(distanceMeters: 0)) == nil)

        let overshot = HikeActivityAttributes.ContentState(
            distanceMeters: 12_000,
            offRouteMeters: 4
        )
        #expect(attributes.fractionComplete(for: overshot) == 1)
        #expect(attributes.remainingDistanceMeters(for: overshot) == 0)
    }

    /// A recording deep-links to the recording screen and a follow to its
    /// hike, through the very functions the widget uses — so a tap lands in
    /// the same place from either surface.
    @Test("the tap target matches the widget's")
    func deepLinksMatchTheWidget() {
        let hikeID = UUID()
        let following = HikeActivityAttributes(
            subject: .following(hikeID: hikeID),
            title: "Ridge",
            tintHex: "#000000",
            startedAt: .now
        )
        #expect(following.deepLink == TrailWidgetDeepLink.url(hikeID: hikeID))
        #expect(following.subject.hikeID == hikeID)
        #expect(!following.subject.isRecording)

        let recording = HikeActivityAttributes(
            subject: .recording(sessionID: UUID()),
            title: "Recording",
            tintHex: "#000000",
            startedAt: .now
        )
        #expect(recording.deepLink == TrailWidgetDeepLink.recordingURL())
        #expect(recording.subject.hikeID == nil)
        #expect(recording.subject.isRecording)
    }

    /// ActivityKit gives an activity's attributes and content state a combined
    /// 4 KB. That budget is the reason the route polyline was left out, and a
    /// budget nothing checks is a budget that gets spent — a future field that
    /// carries geometry would fail here rather than on a device.
    @Test("the encoded payload stays inside ActivityKit's 4 KB budget")
    func payloadFitsTheActivityBudget() throws {
        let snapshot = Self.trailSnapshot(liveFix: Self.liveFix())
        let attributes = HikeActivityAttributes.following(from: snapshot)
        let state = HikeActivityAttributes.ContentState(following: snapshot)
        let encoder = JSONEncoder()
        let total = try encoder.encode(attributes).count
            + encoder.encode(state).count
        #expect(total < 4096)
    }

    @Test("the payload survives a round trip")
    func payloadRoundTrips() throws {
        let snapshot = Self.trailSnapshot(liveFix: Self.liveFix())
        let attributes = HikeActivityAttributes.following(from: snapshot)
        let state = HikeActivityAttributes.ContentState(following: snapshot)

        let decodedAttributes = try JSONDecoder().decode(
            HikeActivityAttributes.self,
            from: JSONEncoder().encode(attributes)
        )
        let decodedState = try JSONDecoder().decode(
            HikeActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(state)
        )
        #expect(decodedAttributes == attributes)
        #expect(decodedState == state)
    }
}

@Suite("Hike activity update policy")
struct HikeActivityUpdatePolicyTests {
    private static let base = HikeActivityAttributes.ContentState(
        distanceMeters: 1000,
        offRouteMeters: 5
    )

    /// ActivityKit throttles an app that updates too often, and a metre of
    /// drift is invisible at the width these numbers are drawn at.
    @Test("a distance change too small to see is not worth an update")
    func smallDistanceIsNotWorthAnUpdate() {
        var moved = Self.base
        moved.distanceMeters = 1010
        #expect(!moved.warrantsUpdate(comparedTo: Self.base))

        moved.distanceMeters = 1030
        #expect(moved.warrantsUpdate(comparedTo: Self.base))
    }

    /// The two changes that alter what the activity *says* rather than what it
    /// reads, and so must never be throttled away.
    @Test("pausing is always worth an update")
    func pausingIsAlwaysWorthAnUpdate() {
        var paused = Self.base
        paused.runState = .paused
        #expect(paused.warrantsUpdate(comparedTo: Self.base))
    }

    @Test("stepping off the trail is always worth an update")
    func leavingTheTrailIsAlwaysWorthAnUpdate() {
        var offRoute = Self.base
        offRoute.offRouteMeters = nil
        #expect(offRoute.warrantsUpdate(comparedTo: Self.base))
        #expect(Self.base.warrantsUpdate(comparedTo: offRoute))
    }

    /// The clock ticks by itself through `timerStart`, so spending an update
    /// on it would buy nothing at all.
    @Test("the elapsed clock alone is never worth an update")
    func elapsedAloneIsNeverWorthAnUpdate() {
        var later = Self.base
        later.elapsedSeconds += 600
        later.updatedAt = Self.base.updatedAt.addingTimeInterval(600)
        #expect(!later.warrantsUpdate(comparedTo: Self.base))
    }

    @Test("the same walk is recognised across a rename")
    func sameWalkIsRecognisedAcrossARename() {
        let hikeID = UUID()
        let original = HikeActivityAttributes(
            subject: .following(hikeID: hikeID),
            title: "Ridge",
            tintHex: "#FF0000",
            startedAt: .now
        )
        var renamed = original
        renamed.title = "Ridge Loop"
        renamed.tintHex = "#00FF00"
        #expect(original.describesSameWalk(as: renamed))

        var other = original
        other.subject = .following(hikeID: UUID())
        #expect(!original.describesSameWalk(as: other))
    }
}

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
    /// card are the ones the walker was looking at when they hit Stop.
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

    /// Claiming 0% for a walker who has merely lost the trail would be a
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
    /// hours before the walker set off.
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
