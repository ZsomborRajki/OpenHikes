//
//  MovementWarningAuthorizationTests+RefusedPost.swift
//  OpenHikesTests
//
//  A once-only warning the notification centre refuses after permission was
//  given (#1682). The watch is committed before the post, which is what keeps
//  overlapping attempts to one banner, so a refusal has to take that back:
//  nobody heard the banner, and the departure, the late finish or the stop
//  it was about is still under way. A refusal that lands after its condition
//  ended leaves the next one's warning to it.
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
