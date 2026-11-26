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

    /// A reading the caller kept from the watch while the banner was out, as
    /// a recording keeps a paused walk's, let go of what was owed. The refund
    /// gives the allowance back and lets go of it again where it fell among
    /// the readings: one before it cannot bring the reminder back, and one
    /// after it decides afresh.
    @Test("a refund lets go of what was owed where a drop since the spend did")
    func refundKeepsADropSinceTheSpend() throws {
        let later = refundStart.addingTimeInterval(MovementReminderPolicy.quietFor + 60)

        var droppedOnly = try spentWatch(earning: 600)
        droppedOnly.watch.dropOwedReminder()
        droppedOnly.watch.refund(droppedOnly.spending)
        #expect(droppedOnly.watch.owedMeters == nil)
        #expect(droppedOnly.watch.remindersSent == 0)

        var readingBefore = try spentWatch(earning: 600)
        _ = readingBefore.watch.observe(awayMeters: 1300, at: later)
        readingBefore.watch.dropOwedReminder()
        readingBefore.watch.refund(readingBefore.spending)
        #expect(readingBefore.watch.owedMeters == nil)

        var readingAfter = try spentWatch(earning: 600)
        readingAfter.watch.dropOwedReminder()
        _ = readingAfter.watch.observe(awayMeters: 1300, at: later)
        readingAfter.watch.refund(readingAfter.spending)
        let owed = readingAfter.watch.owedMeters
        #expect(owed.map { $0.isApproximatelyEqual(to: 1300, absoluteTolerance: 0.001) } == true)
        #expect(readingAfter.watch.remindersSent == 0)
    }

    /// A watch that earned a reminder `meters` from its anchor and spent it.
    private func spentWatch(earning meters: Double) throws -> (watch: MovementWatch, spending: MovementWatch.Spending) {
        var watch = MovementWatch()
        _ = watch.observe(awayMeters: meters, at: refundStart)
        let spent = watch.spend(at: refundStart)
        return (watch, try #require(spent))
    }
}
