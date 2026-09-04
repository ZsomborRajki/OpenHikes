//
//  WalkPresentationTests.swift
//  OpenHikesSharedTests
//
//  What a followed trail's Live Activity says once a walk is under way along
//  it — and that a plain follow, with no walk, still says what it always did.
//

import Foundation
@testable import OpenHikesShared
import Testing

@Suite("Walk presentation")
struct WalkPresentationTests {
    private static let locale = Locale(identifier: "en_GB")
    private static let attributes = HikeActivityAttributes(
        subject: .following(hikeID: UUID()),
        title: "Thumsee Loop",
        tintHex: "#34C759",
        startedAt: Date(timeIntervalSince1970: 1_000_000),
        routeDistanceMeters: 10_000
    )

    /// On the return leg of an out-and-back: position says 62%, coverage says
    /// half. The panel has to show the half, and say which it is showing.
    private static let walking = HikeActivityAttributes.ContentState(
        distanceMeters: 6200,
        offRouteMeters: 4,
        coveredFractionComplete: 0.5,
        runState: .running,
        elapsedSeconds: 2700
    )

    private static func presentation(
        _ state: HikeActivityAttributes.ContentState
    ) -> HikeActivityPresentation {
        attributes.presentation(for: state, locale: locale)
    }

    /// A follow without a walk is exactly what it was before walks existed:
    /// position, captioned *Complete*, no clock and the distance left beside
    /// it.
    @Test("a plain follow keeps its position, its caption and no clock")
    func plainFollowIsUnchanged() {
        let plain = Self.presentation(.init(distanceMeters: 6200, offRouteMeters: 4))
        #expect(plain.primaryValue == "62%")
        #expect(plain.primaryCaption == "Complete")
        #expect(!plain.showsElapsedTimer)
        #expect(plain.secondaryCaption == "Remaining")
        #expect(plain.secondaryValue != nil)
        #expect(plain.statusLabel == nil)
        #expect(!plain.metrics.contains { $0.kind == .remaining })
        #expect(plain.accessibilityValue.contains("percent complete"))
    }

    @Test("a running walk shows coverage, says walked, and ticks its clock")
    func runningWalkShowsCoverageAndTicks() {
        let presentation = Self.presentation(Self.walking)
        #expect(presentation.primaryValue == "50%")
        #expect(presentation.primaryCaption == "Walked")
        #expect(presentation.progress == 0.5)
        #expect(presentation.showsElapsedTimer)
        #expect(presentation.secondaryValue == nil, "the live timer takes the second slot")
        #expect(presentation.statusLabel == nil)
        #expect(
            presentation.metrics.first?.kind == .remaining,
            "the distance left moves into the chips so the clock does not cost it"
        )
        #expect(presentation.accessibilityValue.contains("50 percent walked"))
    }

    /// Pausing has to reach the panel as a word and as a stopped clock — a
    /// `Text(timerInterval:)` cannot be told to stop once drawn.
    @Test("a paused walk says paused and freezes its clock")
    func pausedWalkFreezesTheClock() {
        var paused = Self.walking
        paused.runState = .paused
        let presentation = Self.presentation(paused)
        #expect(!presentation.showsElapsedTimer)
        #expect(presentation.statusLabel == "Paused")
        #expect(presentation.symbolName == "pause.circle.fill")
        #expect(presentation.secondaryValue == presentation.elapsedText)
        #expect(presentation.elapsedText == "0:45:00")
        #expect(presentation.accessibilityLabel.contains("paused"))
    }

    /// The card an ended walk leaves behind for a few minutes.
    @Test("a finished walk says finished with its final coverage")
    func finishedWalkSaysFinished() {
        let presentation = Self.presentation(Self.walking.finished())
        #expect(!presentation.showsElapsedTimer)
        #expect(presentation.statusLabel == "Finished")
        #expect(presentation.symbolName == "checkmark.circle.fill")
        #expect(presentation.primaryValue == "50%")
        #expect(presentation.primaryCaption == "Walked")
    }

    /// Standing still off the trail while paused is still paused: the walk's
    /// own state is the more useful word, and the position is withheld
    /// rather than described.
    @Test("paused outranks off trail for the status word")
    func pausedOutranksOffTrail() {
        var paused = Self.walking
        paused.runState = .paused
        paused.offRouteMeters = nil
        let presentation = Self.presentation(paused)
        #expect(presentation.statusLabel == "Paused")
        #expect(presentation.progress == 0.5, "coverage does not need a fix to be reported")
        #expect(!presentation.metrics.contains { $0.kind == .remaining })
    }
}
