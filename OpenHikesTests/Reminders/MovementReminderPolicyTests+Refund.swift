//
//  MovementReminderPolicyTests+Refund.swift
//  OpenHikesTests
//
//  What a Resume reminder the notification centre refused gives back to its
//  pause (#1682), on the watch alone. The controller's half, with readings
//  taken while the banner was out, is
//  `ResumeReminderAuthorizationTests+RefusedPost.swift`.
//

import Foundation
@testable import OpenHikes
import RealModule
import Testing

extension MovementReminderPolicyTests {
    private var refundStart: Date { MovementReminderHarness.start }

    @Test("a refund with nothing read since leaves the watch as it stood before the spend")
    func refundUndoesTheSpend() throws {
        var watch = MovementWatch()
        let earned = watch.observe(awayMeters: 600, at: refundStart)
        let before = watch
        let spent = watch.spend(at: refundStart)
        let spending = try #require(spent)

        watch.refund(spending)

        #expect(earned)
        #expect(spending.meters.isApproximatelyEqual(to: 600, absoluteTolerance: 0.001))
        #expect(watch == before)
        #expect(watch.remindersSent == 0)
        #expect(watch.owedMeters.map { $0.isApproximatelyEqual(to: 600, absoluteTolerance: 0.001) } == true)
    }

    /// Defensive: the controller's queue lets no later reminder go out before
    /// a refusal is answered, but a refund that landed after one must not
    /// take that one's spend back as well.
    @Test("a refund after a later reminder went out takes nothing back")
    func refundAfterALaterSpend() throws {
        var watch = MovementWatch()
        _ = watch.observe(awayMeters: 600, at: refundStart)
        let first = watch.spend(at: refundStart)
        let firstSpending = try #require(first)
        let later = refundStart.addingTimeInterval(MovementReminderPolicy.quietFor + 60)
        _ = watch.observe(awayMeters: 1200, at: later)
        let second = watch.spend(at: later)
        _ = try #require(second)
        let afterBoth = watch

        watch.refund(firstSpending)

        #expect(watch == afterBoth)
        #expect(watch.remindersSent == 2)
    }
}
