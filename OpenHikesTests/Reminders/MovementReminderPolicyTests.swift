//
//  MovementReminderPolicyTests.swift
//  OpenHikesTests
//
//  The two cases from the issue, written as tests: a walker who steps out of a
//  restaurant to find the toilets is not hiking, and a walker who covers half
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
    /// walker is still near the trailhead.
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
        let afterQuiet = start.addingTimeInterval(MovementReminderPolicy.quietFor + 60)

        let nearby = watch.observe(awayMeters: 700, at: afterQuiet)
        let further = watch.observe(awayMeters: 1200, at: afterQuiet.addingTimeInterval(60))

        #expect(first)
        #expect(!nearby, "a hundred metres further on is not a second departure")
        #expect(further)
    }

    @Test("the quiet period holds even when the walker keeps going")
    func quietPeriodHolds() {
        var watch = MovementWatch()
        let first = watch.observe(awayMeters: 600, at: start)

        let tooSoon = watch.observe(
            awayMeters: 2000,
            at: start.addingTimeInterval(MovementReminderPolicy.quietFor - 60)
        )

        #expect(first)
        #expect(!tooSoon)
    }

    /// A walker who ignored three banners is not going to read a fourth.
    @Test("one pause is worth three reminders at most")
    func remindersAreCapped() {
        var watch = MovementWatch()
        var sent = 0
        var away = 0.0
        var now = start

        for _ in 1...10 {
            away += MovementReminderPolicy.awayMeters * 2
            now = now.addingTimeInterval(MovementReminderPolicy.quietFor + 60)
            if watch.observe(awayMeters: away, at: now) { sent += 1 }
        }

        #expect(sent == MovementReminderPolicy.maximumReminders)
        #expect(watch.isSpent)
        #expect(watch.remindersSent == MovementReminderPolicy.maximumReminders)
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
