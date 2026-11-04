//
//  ResumeReminderAuthorizationTests+Allowance.swift
//  OpenHikesTests
//
//  A pause may say three things, and only something the hiker could have heard
//  counts as one of them. A refused attempt leaves all of it where it was: the
//  allowance, the ground still unreported, and a reminder that can go out the
//  moment permission is given. So does one dropped after its answer, which
//  the suite's own file shows posting nothing.
//
//  Both subjects, because they share the post path. Each pauses while allowed
//  and then loses permission behind the app's back: a recording paused under
//  a refusal gives its watch back, so taking permission away in Settings is
//  the only way a recording ever meets one. A walk keeps its pause through a
//  refusal, which ``walkPausedUnderARefusalCanStillRemind()`` pins by itself.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

extension ResumeReminderAuthorizationTests {
    private typealias Harness = MovementReminderHarness.Harness

    /// Just past the quiet period, so every step below is a fresh attempt.
    private var apart: TimeInterval { MovementReminderPolicy.quietFor + 1 }
    /// Past the distance rule, so every step below is new ground as well.
    private var leg: Double { MovementReminderPolicy.awayMeters + 100 }

    @Test("refused attempts leave the pause all its reminders", arguments: Subject.allCases)
    func refusedAttemptsSpendNothing(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        await settledPause(subject, in: harness)
        harness.notifier.isAuthorized = false

        await refusedSteps(subject, in: harness)
        #expect(harness.notifier.posted.isEmpty)

        await returnFromSettings(in: harness, allowed: true)
        #expect(harness.notifier.postedKinds == [subject.kind], "the reminder that was owed goes out")

        for step in 4...6 {
            await move(subject, meters: leg * Double(step), after: apart * Double(step), in: harness)
        }
        #expect(
            harness.notifier.postedKinds == Array(repeating: subject.kind, count: 3),
            "the cap counts what could reach the hiker, and it still holds"
        )
    }

    /// The issue's reproduction. A paused walk keeps its pause through a
    /// refusal, because there is no sensor to give back, so this is the case
    /// that could always run out of reminders nobody heard.
    @Test("a walk paused under a refusal can still remind")
    func walkPausedUnderARefusalCanStillRemind() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.isAuthorized = false
        await settledPause(.walk, in: harness)

        await refusedSteps(.walk, in: harness)
        await returnFromSettings(in: harness, allowed: true)
        await move(.walk, meters: leg * 4, after: apart * 4, in: harness)

        #expect(harness.notifier.postedKinds == [.resumeWalk, .resumeWalk])
    }

    /// Permission given in Settings by a hiker who then locks the phone. The
    /// app never comes to the front, so only the next fix can notice.
    @Test("the next attempt notices a permission the app never came back for", arguments: Subject.allCases)
    func aLaterAttemptPostsWithoutTheForeground(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        await settledPause(subject, in: harness)
        harness.notifier.isAuthorized = false
        await refusedSteps(subject, in: harness)

        harness.notifier.isAuthorized = true
        await move(subject, meters: leg * 4, after: apart * 4, in: harness)

        #expect(harness.notifier.postedKinds == [subject.kind])
    }

    /// No prompt loop. A refusal is an answer, and the fixes that keep arriving
    /// are not a reason to ask again; only the quiet period running out is.
    @Test("a refusal is asked about once per quiet period, not once per fix", arguments: Subject.allCases)
    func aRefusalIsNotAskedAboutPerFix(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        await settledPause(subject, in: harness)
        harness.notifier.isAuthorized = false
        let asked = harness.notifier.authorizationRequests

        await move(subject, meters: leg, after: apart, in: harness)
        for minute in 1...14 {
            let meters = leg + Double(minute) * 50
            await move(subject, meters: meters, after: apart + Double(minute) * 60, in: harness)
        }
        #expect(harness.notifier.authorizationRequests == asked + 1)

        await move(subject, meters: leg * 3, after: apart * 2, in: harness)
        #expect(harness.notifier.authorizationRequests == asked + 2)
    }

    /// Coming back to the app is never a moment to put a prompt in front of
    /// anybody, and a walk that still cannot notify keeps what it is owed.
    @Test("returning while still refused checks silently and keeps the walk's reminder")
    func aSilentCheckKeepsTheWalkReminder() async {
        let harness = MovementReminderHarness.harness()
        await settledPause(.walk, in: harness)
        harness.notifier.isAuthorized = false
        await move(.walk, meters: leg, after: apart, in: harness)
        let asked = harness.notifier.authorizationRequests

        await returnFromSettings(in: harness, allowed: false)
        #expect(harness.notifier.posted.isEmpty)
        #expect(harness.notifier.silentChecks == 1)
        #expect(harness.notifier.authorizationRequests == asked)

        await returnFromSettings(in: harness, allowed: true)
        #expect(harness.notifier.postedKinds == [.resumeWalk])
    }

    /// The recording's half differs, and on purpose: a feed spent on a question
    /// with no audience is the one thing a refusal is not allowed to keep. See
    /// ``MovementReminderController/reconcileWithAuthorization(prompting:)``.
    @Test("returning while still refused gives the recording's watch back, reminder and all")
    func aSilentCheckStillEndsTheRecordingWatch() async {
        let harness = MovementReminderHarness.harness()
        var endedWatches = 0
        harness.controller.watchingDidEnd = { endedWatches += 1 }
        await settledPause(.recording, in: harness)
        harness.notifier.isAuthorized = false
        await move(.recording, meters: leg, after: apart, in: harness)
        #expect(endedWatches == 0, "only the foreground check gives it back")

        await returnFromSettings(in: harness, allowed: false)
        #expect(endedWatches == 1)

        await returnFromSettings(in: harness, allowed: true)
        #expect(harness.notifier.posted.isEmpty)
    }

    /// A held-back reminder can go out long after the fix that earned it, with
    /// nothing heard from the feeds in between, so the quiet period has to run
    /// from the banner. From the fix, the very next one could post a second.
    @Test("a reminder held back by a refusal starts the quiet period when it goes out", arguments: Subject.allCases)
    func aHeldBackReminderStartsTheQuietPeriod(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        await settledPause(subject, in: harness)
        harness.notifier.isAuthorized = false
        await move(subject, meters: leg, after: apart, in: harness)

        let returnedAfter = apart * 4
        harness.clock.advance(by: returnedAfter)
        await returnFromSettings(in: harness, allowed: true)
        #expect(harness.notifier.posted.count == 1)

        await move(subject, meters: leg * 2, after: returnedAfter + 60, in: harness)
        #expect(harness.notifier.posted.count == 1, "another crossing, a minute after the banner")

        await move(subject, meters: leg * 3, after: returnedAfter + apart, in: harness)
        #expect(harness.notifier.posted.count == 2)
    }

    /// What is on the banner is what the watch knows when it goes out, not what
    /// it knew at the first refused attempt.
    @Test("a held-back reminder says how far the hiker has come by now", arguments: Subject.allCases)
    func aHeldBackReminderUsesTheLatestReading(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        await settledPause(subject, in: harness)
        harness.notifier.isAuthorized = false
        await move(subject, meters: leg, after: apart, in: harness)
        await move(subject, meters: 2000, after: apart + 60, in: harness)

        await returnFromSettings(in: harness, allowed: true)

        let body = harness.notifier.posted.first?.body ?? ""
        #expect(body.contains(MovementReminderWording.distance(2000)), "\(body)")
    }

    /// The recording's banner gives a time as well as a distance, and that is
    /// read when it goes out for the same reason.
    @Test("a held-back recording reminder says how long it has been paused by now")
    func aHeldBackReminderUsesTheCurrentPause() async {
        let harness = MovementReminderHarness.harness()
        await settledPause(.recording, in: harness)
        harness.notifier.isAuthorized = false
        await move(.recording, meters: leg, after: apart, in: harness)

        harness.clock.advance(by: 7200)
        await returnFromSettings(in: harness, allowed: true)

        let body = harness.notifier.posted.first?.body ?? ""
        #expect(body.contains(HikeFormat.duration(7200)), "\(body)")
    }

    /// A slow prompt rather than a refused one. The fix that arrives while it
    /// is up joins the attempt already waiting, and neither posts twice nor
    /// spends twice.
    @Test("fixes during a slow prompt join the attempt that is waiting", arguments: Subject.allCases)
    func fixesDuringAPromptPostOnce(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        await settledPause(subject, in: harness)
        harness.notifier.holdsThePrompt = true
        observe(subject, meters: leg, after: apart, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }
        observe(subject, meters: 2000, after: apart + 60, in: harness)

        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [subject.kind])
        let body = harness.notifier.posted.first?.body ?? ""
        #expect(body.contains(MovementReminderWording.distance(2000)), "\(body)")
    }

    /// The hiker went for the toilets after all. A reading that no longer
    /// earns a reminder takes the waiting one down, and nothing was spent, so
    /// the allowance is there for a departure that does hold.
    @Test("a hiker who came back is owed nothing, and nothing was spent", arguments: Subject.allCases)
    func comingBackDropsTheReminder(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        await settledPause(subject, in: harness)
        harness.notifier.isAuthorized = false
        await move(subject, meters: leg, after: apart, in: harness)
        await move(subject, meters: 50, after: apart + 300, in: harness)

        await returnFromSettings(in: harness, allowed: true)
        #expect(harness.notifier.posted.isEmpty)

        await move(subject, meters: leg, after: apart * 2, in: harness)
        #expect(harness.notifier.postedKinds == [subject.kind])
    }

    /// The same precedence as everywhere else, across the wait. The walk's
    /// reminder is held back rather than lost: the recording outranks it only
    /// for as long as there is a recording.
    @Test("a recording holds back the walk's reminder without spending it")
    func aRecordingHoldsBackTheWalkReminder() async {
        let harness = MovementReminderHarness.harness()
        let recording = RecordingState()
        harness.controller.hasActiveRecording = { recording.isActive }
        await settledPause(.walk, in: harness)
        harness.notifier.isAuthorized = false
        await move(.walk, meters: leg, after: apart, in: harness)

        recording.isActive = true
        await returnFromSettings(in: harness, allowed: true)
        #expect(harness.notifier.posted.isEmpty)

        recording.isActive = false
        await returnFromSettings(in: harness, allowed: true)
        #expect(harness.notifier.postedKinds == [.resumeWalk])
    }

    /// An answer that arrives after a recording took over posts nothing, and
    /// nobody heard it, so it must cost the walk as little as a refusal does.
    @Test("a walk reminder silenced after its answer spends none of the walk's allowance")
    func aSilencedAttemptSpendsNothing() async {
        let harness = MovementReminderHarness.harness()
        let recording = RecordingState()
        harness.controller.hasActiveRecording = { recording.isActive }
        await settledPause(.walk, in: harness)
        harness.notifier.holdsThePrompt = true
        observe(.walk, meters: leg, after: apart, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }

        recording.isActive = true
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()
        #expect(harness.notifier.posted.isEmpty)

        recording.isActive = false
        for step in 2...5 {
            await move(.walk, meters: leg * Double(step), after: apart * Double(step), in: harness)
        }
        #expect(harness.notifier.postedKinds == Array(repeating: .resumeWalk, count: 3))
    }

    @Test("an ended pause takes its held-back reminder with it", arguments: Subject.allCases)
    func anEndedPauseOwesNothing(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        await settledPause(subject, in: harness)
        harness.notifier.isAuthorized = false
        await move(subject, meters: leg, after: apart, in: harness)

        resume(subject, in: harness)
        await returnFromSettings(in: harness, allowed: true)

        #expect(harness.notifier.posted.isEmpty)
    }

    /// Turning the switch off is an answer too, and it lasts: turning it back
    /// on does not bring back a reminder from the pause it ended.
    @Test("the hiker's switch takes a held-back reminder down", arguments: Subject.allCases)
    func theSwitchClearsTheReminder(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        await settledPause(subject, in: harness)
        harness.notifier.isAuthorized = false
        await move(subject, meters: leg, after: apart, in: harness)

        harness.defaults.set(false, forKey: SettingsKey.movementRemindersEnabled)
        harness.controller.reconcileWithPreferences()
        harness.defaults.set(true, forKey: SettingsKey.movementRemindersEnabled)
        await returnFromSettings(in: harness, allowed: true)

        #expect(harness.notifier.posted.isEmpty)
    }

    /// One reminder owed is one reminder, however many times the hiker comes
    /// back to the app.
    @Test("returning twice posts a held-back reminder once", arguments: Subject.allCases)
    func returningTwicePostsOnce(_ subject: Subject) async {
        let harness = MovementReminderHarness.harness()
        await settledPause(subject, in: harness)
        harness.notifier.isAuthorized = false
        await move(subject, meters: leg, after: apart, in: harness)

        await returnFromSettings(in: harness, allowed: true)
        await returnFromSettings(in: harness, allowed: true)

        #expect(harness.notifier.postedKinds == [subject.kind])
    }

    /// The other half of ``MovementReminderControllerTests/foregroundWithNothingWatchedAsksNothing()``.
    /// A paused walk is the usual state of a hiker at lunch, and with nothing
    /// owed there is no reason for an activation to cost a cross-process call.
    @Test("a paused walk with nothing held back asks nothing on the way back")
    func foregroundWithNothingOwedAsksNothing() async {
        let harness = MovementReminderHarness.harness()
        await settledPause(.walk, in: harness)

        harness.controller.reconcileWithAuthorization(prompting: false)
        await harness.controller.settle()

        #expect(harness.notifier.silentChecks == 0)
    }

    // MARK: Helpers

    private func settledPause(_ subject: Subject, in harness: Harness) async {
        pause(subject, in: harness)
        await harness.controller.settle()
    }

    /// The issue's three eligible attempts, each new ground and each past the
    /// quiet period, and each settled so its refusal has landed.
    private func refusedSteps(_ subject: Subject, in harness: Harness) async {
        for step in 1...MovementReminderPolicy.maximumReminders {
            await move(subject, meters: leg * Double(step), after: apart * Double(step), in: harness)
        }
    }

    private func move(
        _ subject: Subject,
        meters: Double,
        after seconds: TimeInterval,
        in harness: Harness
    ) async {
        observe(subject, meters: meters, after: seconds, in: harness)
        await harness.controller.settle()
    }

    private func observe(
        _ subject: Subject,
        meters: Double,
        after seconds: TimeInterval,
        in harness: Harness
    ) {
        let taken = start.addingTimeInterval(seconds)
        switch subject {
        case .walk:
            harness.controller.walkObserved(distanceAlongRoute: meters, at: taken)
        case .recording:
            harness.controller.recordingObserved(
                MovementReminderHarness.fix(northOfAnchorBy: meters, takenAt: taken)
            )
        }
    }

    private func returnFromSettings(in harness: Harness, allowed: Bool) async {
        harness.notifier.isAuthorized = allowed
        harness.controller.reconcileWithAuthorization(prompting: false)
        await harness.controller.settle()
    }
}
