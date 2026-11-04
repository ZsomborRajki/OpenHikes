//
//  MovementReminderPolicyTests.swift
//  OpenHikesTests
//
//  The two cases from the issue, written as tests: a hiker who steps out of a
//  restaurant to find the toilets is not hiking, and a hiker who covers half
//  a kilometre — or a quarter of one at cycling pace — is.
//
//  Everything here is a value type fed by hand, which is the point of the
//  policy being one: a suite that had to wait out the quarter of an hour
//  between reminders would be measuring `Task.sleep`.
//
//  Every observation is taken into a `let` before it is asserted on, and has
//  to be: `#expect` captures its expression in an escaping closure, so a
//  `mutating` call inside one does not compile.
//

import Foundation
@testable import OpenHikes
import RealModule
import Testing

@Suite("Movement reminder policy")
struct MovementReminderPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    /// The case the issue names outright, and the one the whole design is bent
    /// around: a stop that includes some walking is still a stop.
    @Test("a short walk around the same place is not a resumed hike")
    func toiletTripIsNotAHike() {
        var watch = MovementWatch()
        var reminded = false

        for step in 1...10 {
            let wander = Double(step % 4) * 20
            let says = watch.observe(
                awayMeters: wander,
                at: start.addingTimeInterval(Double(step) * 60)
            )
            reminded = reminded || says
        }

        #expect(!reminded, "eighty metres of wandering is a lunch stop, not a hike")
    }

    @Test("half a kilometre from the pause is a reminder")
    func distanceCrossingReminds() {
        var watch = MovementWatch()

        let halfway = watch.observe(awayMeters: 300, at: start)
        let crossing = watch.observe(
            awayMeters: MovementReminderPolicy.awayMeters,
            at: start.addingTimeInterval(600)
        )

        #expect(!halfway)
        #expect(crossing)
    }

    /// The bicycle clause. The same distance, arriving inside two minutes
    /// rather than over half an hour, is what makes the reminder land while the
    /// hiker is still near the trailhead.
    @Test("cycling pace reminds before the distance rule would")
    func paceCrossingReminds() {
        var watch = MovementWatch()

        let atThePause = watch.observe(awayMeters: 0, at: start)
        let burst = watch.observe(
            awayMeters: MovementReminderPolicy.paceMeters,
            at: start.addingTimeInterval(MovementReminderPolicy.paceWindow - 1)
        )

        #expect(!atThePause)
        #expect(burst, "two hundred and fifty metres in under two minutes is a bike or a bus")
    }

    /// The same ground covered slowly is not the pace rule — it is a walk
    /// around a car park, and only the distance rule may speak for it.
    @Test("the pace rule ignores what arrives outside its window")
    func slowerThanTheWindowDoesNotRemind() {
        var watch = MovementWatch()

        let atThePause = watch.observe(awayMeters: 0, at: start)
        let slow = watch.observe(
            awayMeters: MovementReminderPolicy.paceMeters,
            at: start.addingTimeInterval(MovementReminderPolicy.paceWindow * 3)
        )

        #expect(!atThePause)
        #expect(!slow)
    }

    /// Both bounds apply to a second reminder, and this is the one that is easy
    /// to lose: without re-anchoring, the same five hundred metres would argue
    /// for every reminder after the quiet period.
    @Test("a second reminder needs another crossing as well as the quiet period")
    func repeatsNeedNewGroundAndTime() {
        var watch = MovementWatch()
        let first = watch.observe(awayMeters: 600, at: start)
        _ = watch.spendReminder(at: start)
        let afterQuiet = start.addingTimeInterval(MovementReminderPolicy.quietFor + 60)

        let nearby = watch.observe(awayMeters: 700, at: afterQuiet)
        let further = watch.observe(awayMeters: 1200, at: afterQuiet.addingTimeInterval(60))

        #expect(first)
        #expect(!nearby, "a hundred metres further on is not a second departure")
        #expect(further)
    }

    @Test("the quiet period holds even when the hiker keeps going")
    func quietPeriodHolds() {
        var watch = MovementWatch()
        let first = watch.observe(awayMeters: 600, at: start)
        _ = watch.spendReminder(at: start)

        let tooSoon = watch.observe(
            awayMeters: 2000,
            at: start.addingTimeInterval(MovementReminderPolicy.quietFor - 60)
        )

        #expect(first)
        #expect(!tooSoon)
    }

    /// A hiker who ignored three banners is not going to read a fourth.
    @Test("one pause is worth three reminders at most")
    func remindersAreCapped() {
        var watch = MovementWatch()
        var sent = 0
        var away = 0.0
        var now = start

        for _ in 1...10 {
            away += MovementReminderPolicy.awayMeters * 2
            now = now.addingTimeInterval(MovementReminderPolicy.quietFor + 60)
            if watch.observe(awayMeters: away, at: now), watch.spendReminder(at: now) != nil { sent += 1 }
        }

        #expect(sent == MovementReminderPolicy.maximumReminders)
        #expect(watch.isSpent)
        #expect(watch.remindersSent == MovementReminderPolicy.maximumReminders)
    }

    // MARK: Earning and spending

    /// Permission sits between the two, so a reminder that has only been
    /// earned has cost the pause nothing yet.
    @Test("an attempt spends nothing until its reminder goes out")
    func anAttemptSpendsNothing() {
        var watch = MovementWatch()

        let attempt = watch.observe(awayMeters: 600, at: start)

        #expect(attempt)
        #expect(watch.remindersSent == 0)
        #expect(600.0.isApproximatelyEqual(to: watch.owedMeters ?? .nan, absoluteTolerance: 0.001))
    }

    /// The baseline did not move, because nothing has told the hiker about
    /// the first six hundred metres.
    @Test("a refused attempt keeps its ground for the next one")
    func aRefusedAttemptKeepsItsGround() {
        var watch = MovementWatch()
        _ = watch.observe(awayMeters: 600, at: start)

        let again = watch.observe(
            awayMeters: 650,
            at: start.addingTimeInterval(MovementReminderPolicy.quietFor + 60)
        )

        #expect(again, "fifty metres further on, and all six hundred are still unreported")
    }

    /// What stops a refusal being asked about again on every fix: past the
    /// distance rule, each one earns the same reminder.
    @Test("a refused attempt holds the next one off for the quiet period")
    func aRefusedAttemptStartsTheQuietPeriod() {
        var watch = MovementWatch()
        _ = watch.observe(awayMeters: 600, at: start)

        let tooSoon = watch.observe(
            awayMeters: 2000,
            at: start.addingTimeInterval(MovementReminderPolicy.quietFor - 60)
        )

        #expect(!tooSoon)
        #expect(
            2000.0.isApproximatelyEqual(to: watch.owedMeters ?? .nan, absoluteTolerance: 0.001),
            "the reminder waiting moves with the hiker"
        )
    }

    @Test("refused attempts never reach the cap")
    func refusedAttemptsDoNotCount() {
        var watch = MovementWatch()
        var attempts = 0
        var now = start

        for step in 1...10 {
            now = now.addingTimeInterval(MovementReminderPolicy.quietFor + 60)
            if watch.observe(awayMeters: 600 * Double(step), at: now) { attempts += 1 }
        }

        #expect(attempts == 10)
        #expect(!watch.isSpent)
    }

    @Test("a reading that no longer earns a reminder takes the waiting one away")
    func aReturnLeavesNothingOwed() {
        var watch = MovementWatch()
        _ = watch.observe(awayMeters: 600, at: start)

        _ = watch.observe(awayMeters: 100, at: start.addingTimeInterval(300))
        let spent = watch.spendReminder(at: start.addingTimeInterval(360))

        #expect(watch.owedMeters == nil)
        #expect(spent == nil)
        #expect(watch.remindersSent == 0)
    }

    /// The other way a quiet period can hold a reading back, and the one that
    /// must not leave anything behind: a return to the app would post it.
    @Test("a reminder that went out leaves nothing owed through its quiet period")
    func aSentReminderLeavesNothingOwed() {
        var watch = MovementWatch()
        _ = watch.observe(awayMeters: 600, at: start)
        _ = watch.spendReminder(at: start)

        let tooSoon = watch.observe(awayMeters: 1200, at: start.addingTimeInterval(60))

        #expect(!tooSoon)
        #expect(watch.owedMeters == nil)
    }

    /// Overlapping attempts are what this answers: the second finds nothing
    /// left to post.
    @Test("a reminder is spent once")
    func aReminderIsSpentOnce() {
        var watch = MovementWatch()
        _ = watch.observe(awayMeters: 600, at: start)

        let first = watch.spendReminder(at: start)
        let second = watch.spendReminder(at: start)

        #expect(first != nil)
        #expect(second == nil)
        #expect(watch.remindersSent == 1)
    }

    /// A reminder held back by a refusal goes out long after the fix that
    /// earned it, and the quiet period separates banners, not fixes.
    @Test("the quiet period runs from a reminder that went out late")
    func aLateReminderRestartsTheQuietPeriod() {
        var watch = MovementWatch()
        _ = watch.observe(awayMeters: 600, at: start)
        let postedAt = start.addingTimeInterval(MovementReminderPolicy.quietFor * 3)
        _ = watch.spendReminder(at: postedAt)

        let tooSoon = watch.observe(awayMeters: 1200, at: postedAt.addingTimeInterval(60))
        let afterQuiet = watch.observe(
            awayMeters: 1300,
            at: postedAt.addingTimeInterval(MovementReminderPolicy.quietFor + 60)
        )

        #expect(!tooSoon)
        #expect(afterQuiet)
    }

    /// Fixes are stamped when they were taken and a post by the wall clock, so
    /// neither can be assumed to be the later of the two.
    @Test("a reminder never moves the quiet period back")
    func aReminderNeverShortensTheQuietPeriod() {
        var watch = MovementWatch()
        _ = watch.observe(awayMeters: 600, at: start)
        _ = watch.spendReminder(at: start.addingTimeInterval(-3600))

        let tooSoon = watch.observe(awayMeters: 1200, at: start.addingTimeInterval(60))

        #expect(!tooSoon)
    }

    // MARK: Stillness

    @Test("a quarter of an hour without moving suggests a pause")
    func stillnessReminds() {
        var watch = StillnessWatch()

        let atTheStop = watch.observe(isStationary: true, at: start)
        let shortly = watch.observe(
            isStationary: true,
            at: start.addingTimeInterval(MovementReminderPolicy.stillFor - 60)
        )
        let atTheThreshold = watch.observe(
            isStationary: true,
            at: start.addingTimeInterval(MovementReminderPolicy.stillFor)
        )

        #expect(!atTheStop)
        #expect(!shortly)
        #expect(atTheThreshold)
    }

    /// Once per stop. The recorder feeds this on every accepted fix, so a watch
    /// that kept saying yes would be a banner per fix for the rest of the
    /// lunch.
    @Test("the pause suggestion is made once per stop and rearmed by moving")
    func stillnessRemindsOncePerStop() {
        var watch = StillnessWatch()
        let stopped = start.addingTimeInterval(MovementReminderPolicy.stillFor)
        _ = watch.observe(isStationary: true, at: start)
        let first = watch.observe(isStationary: true, at: stopped)

        let again = watch.observe(isStationary: true, at: stopped.addingTimeInterval(60))

        let movedOn = stopped.addingTimeInterval(120)
        let walking = watch.observe(isStationary: false, at: movedOn)
        let stoppedAgain = watch.observe(isStationary: true, at: movedOn.addingTimeInterval(60))
        let secondStop = watch.observe(
            isStationary: true,
            at: movedOn.addingTimeInterval(60 + MovementReminderPolicy.stillFor)
        )

        #expect(first)
        #expect(!again)
        #expect(!walking)
        #expect(!stoppedAgain)
        #expect(secondStop, "the next stop is a stop of its own")
    }
}
