//
//  MovementWarningAuthorizationTests+RefusedPost.swift
//  OpenHikesTests
//
//  A once-only warning the notification centre refuses after permission was
//  given (#1682). The watch is committed before the post, which is what keeps
//  overlapping attempts to one banner, so a refusal has to take that back:
//  nobody heard the banner, and the departure, the late finish or the stop
//  it was about is still under way, so the warning is pending again, for the
//  next observation that qualifies and for the way back into the app. A
//  refusal that lands after its condition ended leaves the next one's warning
//  to it.
//

import Foundation
@testable import OpenHikes
import Testing

extension MovementWarningAuthorizationTests {
    /// The issue's reproduction, for each warning: refused once, then the next
    /// observation that still qualifies says it, and only once.
    @Test("a warning the system refuses is posted by the next observation that qualifies", arguments: Warning.allCases)
    func aRefusedWarningIsSaidAgain(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.refusesPosts = 1
        makeEligible(warning, in: harness)
        await harness.controller.settle()
        #expect(harness.notifier.refusedPosts == 1)
        #expect(harness.notifier.posted.isEmpty)

        observeAgain(warning, in: harness, after: 60)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [warning.kind])

        observeAgain(warning, in: harness, after: 120)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [warning.kind], "and once said, it is said once")
    }

    /// A refusal that arrives after the walk or the recording it was about
    /// has ended, and another has become eligible behind it. The new one's
    /// banner goes out, and the old refusal does not un-say it.
    @Test("a refusal that lands after its subject ended leaves the next warning", arguments: Warning.allCases)
    func aLateRefusalLeavesTheNextWarning(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePost = true
        makeEligible(warning, in: harness)
        guard await harness.notifier.awaitPost() else { return }

        if warning == .stillness {
            harness.controller.recordingDidEnd()
        } else {
            harness.controller.walkDidStopFollowing()
        }
        let later: TimeInterval = 3600
        makeEligible(warning, in: harness, after: later, trailTitle: "New Walk")
        harness.notifier.answerPost(taken: false)
        await harness.controller.settle()
        #expect(harness.notifier.refusedPosts == 1)
        #expect(harness.notifier.postedKinds == [warning.kind])
        if warning != .stillness {
            #expect(harness.notifier.posted.first?.body.contains("New Walk") == true)
        }

        observeAgain(warning, in: harness, after: later + 60)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [warning.kind], "the new warning stays said")
    }

    /// Owed as a warning held back by a refused permission is owed, so the
    /// way back into the app says it.
    @Test("a warning the system refuses is still owed on the way back to the app", arguments: Warning.allCases)
    func aRefusedWarningIsStillOwed(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.refusesPosts = 1
        makeEligible(warning, in: harness)
        await harness.controller.settle()

        harness.controller.reconcileWithAuthorization(prompting: false)
        await harness.controller.settle()

        #expect(harness.notifier.refusedPosts == 1)
        #expect(harness.notifier.postedKinds == [warning.kind])
    }

    /// Back inside the band that holds a departure without maturing one. The
    /// departure is still under way, so its refused warning still stands.
    @Test("a refused Left the Trail warning stands while the hiker is in the band")
    func aRefusedDepartureStandsInTheBand() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.refusesPosts = 1
        makeEligible(.offTrail, in: harness)
        await harness.controller.settle()

        harness.controller.walkObserved(
            offRouteMeters: inBandMeters,
            trailTitle: "Ridge Loop",
            at: MovementReminderHarness.start.addingTimeInterval(MovementReminderPolicy.offTrailDwell + 60)
        )
        await harness.controller.settle()
        #expect(harness.notifier.posted.isEmpty, "the band matures nothing by itself")

        harness.controller.reconcileWithAuthorization(prompting: false)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [.leftTheTrail])
    }

    /// The app came to the front while the banner was on its way, and the
    /// system then refused it. The check runs after that answer, and says
    /// the warning the refusal left pending.
    @Test("coming back to the app while a refused warning is out says it", arguments: Warning.allCases)
    func aForegroundCheckDuringARefusedWarning(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePost = true
        makeEligible(warning, in: harness)
        guard await harness.notifier.awaitPost() else { return }

        harness.controller.reconcileWithAuthorization(prompting: false)
        harness.notifier.answerPost(taken: false)
        await harness.controller.settle()

        #expect(harness.notifier.refusedPosts == 1)
        #expect(harness.notifier.postedKinds == [warning.kind])
    }

    /// The walk was paused while the banner was out, which cancels what was
    /// pending. The refusal leaves the warning unsaid, as that cancel left
    /// it, but not pending: after the walk resumes, only a new observation
    /// that qualifies says it, never the way back into the app alone.
    @Test("a refusal after the walk was paused leaves nothing pending", arguments: [Warning.offTrail, .dusk])
    func aRefusalAfterAPauseLeavesNothingPending(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePost = true
        makeEligible(warning, in: harness)
        guard await harness.notifier.awaitPost() else { return }

        harness.controller.walkDidPause(trailTitle: "Ridge Loop", atDistance: 0, on: MovementReminderHarness.start)
        harness.notifier.answerPost(taken: false)
        await harness.controller.settle()
        harness.controller.walkDidResumeOrEnd()
        harness.controller.reconcileWithAuthorization(prompting: false)
        await harness.controller.settle()
        #expect(harness.notifier.posted.isEmpty)

        observeAgain(warning, in: harness, after: 60)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [warning.kind])
    }

    /// The condition cleared while the banner was out: a rejoin, an estimate
    /// back before dusk, moving again. Nothing it was about is true any
    /// more, so the refusal leaves nothing for the way back into the app.
    @Test("a refusal after its condition cleared leaves nothing pending", arguments: Warning.allCases)
    func aRefusalAfterTheConditionClearedLeavesNothingPending(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePost = true
        makeEligible(warning, in: harness)
        guard await harness.notifier.awaitPost() else { return }

        clearCondition(warning, in: harness)
        harness.notifier.answerPost(taken: false)
        await harness.controller.settle()
        harness.controller.reconcileWithAuthorization(prompting: false)
        await harness.controller.settle()

        #expect(harness.notifier.refusedPosts == 1)
        #expect(harness.notifier.posted.isEmpty)
    }

    /// Between the distance that rejoins the line and the one that leaves it.
    private var inBandMeters: Double {
        (MovementReminderPolicy.onTrailAgainMeters + MovementReminderPolicy.offTrailMeters) / 2
    }

    /// Further off the line than the walk ``makeEligible(_:in:after:trailTitle:)``
    /// left, so a fix there is still off it.
    private var stillOffTrailMeters: Double { MovementReminderPolicy.offTrailMeters + 100 }

    /// Another observation of the condition ``makeEligible(_:in:after:trailTitle:)``
    /// set up, `seconds` after the moment it first became worth saying.
    private func observeAgain(
        _ warning: Warning,
        in harness: MovementReminderHarness.Harness,
        after seconds: TimeInterval
    ) {
        switch warning {
        case .offTrail:
            harness.controller.walkObserved(
                offRouteMeters: stillOffTrailMeters,
                trailTitle: "Ridge Loop",
                at: MovementReminderHarness.start.addingTimeInterval(MovementReminderPolicy.offTrailDwell + seconds)
            )
        case .dusk:
            makeEligible(.dusk, in: harness, after: seconds)
        case .stillness:
            harness.controller.recordingObserved(
                isStationary: true,
                at: MovementReminderHarness.start.addingTimeInterval(MovementReminderPolicy.stillFor + seconds)
            )
        }
    }
}
