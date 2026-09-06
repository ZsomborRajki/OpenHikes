//
//  MovementReminderControllerTests.swift
//  OpenHikesTests
//
//  What the controller decides, given what the policy says: which subject a
//  reminder belongs to, when one is worth sending, when it is taken back down,
//  and the two switches that stop it happening at all.
//
//  The notifier is a stub, because the framework half is unreachable from a
//  hosted test and uninteresting anyway — see ``MovementReminderNotifying``.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Movement reminder controller")
struct MovementReminderControllerTests {
    private let start = MovementReminderHarness.start

    // MARK: A paused recording

    /// The recorder asks this question to decide whether to keep a location
    /// feed alive, so the answer is the whole energy argument for the feature.
    @Test("a pause with an anchor is worth watching, and asks for permission")
    func pauseArmsTheWatch() async {
        let harness = MovementReminderHarness.harness()

        let watches = harness.controller.recordingDidPause(
            at: MovementReminderHarness.anchor,
            on: start
        )
        await harness.controller.settle()

        #expect(watches)
        #expect(
            harness.notifier.authorizationRequests == 1,
            "the prompt belongs to the pause the walker just tapped"
        )
    }

    @Test("a pause with reminders off is not watched at all")
    func pauseWithRemindersOffIsNotWatched() async {
        let harness = MovementReminderHarness.harness(remindersEnabled: false)

        let watches = harness.controller.recordingDidPause(
            at: MovementReminderHarness.anchor,
            on: start
        )
        harness.controller.recordingObserved(
            MovementReminderHarness.fix(
                northOfAnchorBy: 2000,
                takenAt: start.addingTimeInterval(600)
            ),
            at: start.addingTimeInterval(600)
        )
        await harness.controller.settle()

        #expect(!watches, "a watch nobody will read is battery spent for nothing")
        #expect(harness.notifier.posted.isEmpty)
        #expect(harness.notifier.authorizationRequests == 0)
    }

    /// A pause taken before the first fix landed. There is nothing to measure
    /// a departure from, and a watch would answer a question nobody can ask.
    @Test("a pause with no anchor is not watched")
    func pauseWithoutAnAnchorIsNotWatched() {
        let harness = MovementReminderHarness.harness()

        #expect(!harness.controller.recordingDidPause(at: nil, on: start))
    }

    @Test("half a kilometre from the pause posts the resume reminder")
    func movingAwayPostsTheReminder() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start)

        harness.controller.recordingObserved(
            MovementReminderHarness.fix(
                northOfAnchorBy: 100,
                takenAt: start.addingTimeInterval(300)
            ),
            at: start.addingTimeInterval(300)
        )
        harness.controller.recordingObserved(
            MovementReminderHarness.fix(
                northOfAnchorBy: 700,
                takenAt: start.addingTimeInterval(1800)
            ),
            at: start.addingTimeInterval(1800)
        )
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.resumeRecording])
        #expect(
            harness.notifier.posted.first?.categoryIdentifier
                == MovementReminderKind.resumeRecording.categoryIdentifier,
            "the category is what carries the Resume button"
        )
    }

    /// A significant-location-change delivery can be five hundred metres wide,
    /// which is the same figure the rule is written against. Measuring one
    /// against the other would be a coin toss.
    @Test("a fix too loose to measure with is dropped")
    func looseFixesAreDropped() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start)

        harness.controller.recordingObserved(
            MovementReminderHarness.fix(
                northOfAnchorBy: 900,
                accuracy: 800,
                takenAt: start.addingTimeInterval(600)
            ),
            at: start.addingTimeInterval(600)
        )
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    /// Core Location's first significant-change event is commonly a cached
    /// one, and a cached fix from before the pause is a statement about where
    /// the walker set off from — not about anything they have done since.
    @Test("a fix taken before the pause is not evidence of leaving it")
    func cachedFixesFromBeforeThePauseAreDropped() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start)

        harness.controller.recordingObserved(
            MovementReminderHarness.fix(
                northOfAnchorBy: 800,
                takenAt: start.addingTimeInterval(-3600)
            ),
            at: start.addingTimeInterval(1)
        )
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    /// Significant-change delivery batches. Two fixes twenty minutes apart on
    /// the ground, handed over in the same breath, are not a walker moving at
    /// cycling pace — and the pace rule is the one that would say so if the
    /// watch were stamped with the delivery instead of the fix.
    @Test("a batch of delayed fixes is not a burst of speed")
    func batchedFixesAreNotAPaceBurst() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start)
        let deliveredAt = start.addingTimeInterval(1800)

        harness.controller.recordingObserved(
            MovementReminderHarness.fix(northOfAnchorBy: 0, takenAt: start),
            at: deliveredAt
        )
        harness.controller.recordingObserved(
            MovementReminderHarness.fix(
                northOfAnchorBy: 300,
                takenAt: start.addingTimeInterval(1200)
            ),
            at: deliveredAt
        )
        await harness.controller.settle()

        #expect(
            harness.notifier.posted.isEmpty,
            "three hundred metres in twenty minutes is a stroll, and short of the distance rule"
        )
    }

    @Test("an out-of-order fix is dropped rather than reordered")
    func staleOrderedFixesAreDropped() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start)
        let newest = start.addingTimeInterval(1800)

        harness.controller.recordingObserved(
            MovementReminderHarness.fix(northOfAnchorBy: 100, takenAt: newest),
            at: newest
        )
        harness.controller.recordingObserved(
            MovementReminderHarness.fix(
                northOfAnchorBy: 900,
                takenAt: start.addingTimeInterval(60)
            ),
            at: newest.addingTimeInterval(1)
        )
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    /// The walker has just said they do not want this. Everything armed goes,
    /// including whatever the recorder is spending to feed it.
    @Test("turning the switch off mid-pause disarms the watch and the banners")
    func disablingMidPauseDisarmsEverything() async {
        let harness = MovementReminderHarness.harness()
        var stopped = 0
        harness.controller.watchingDidEnd = { stopped += 1 }
        harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start)

        harness.defaults.set(false, forKey: SettingsKey.movementRemindersEnabled)
        harness.controller.recordingObserved(
            MovementReminderHarness.fix(
                northOfAnchorBy: 2000,
                takenAt: start.addingTimeInterval(600)
            ),
            at: start.addingTimeInterval(600)
        )
        await harness.controller.settle()

        #expect(stopped == 1, "the recorder has to be told to stop watching")
        #expect(harness.notifier.withdrawn.contains(.resumeRecording))
        #expect(harness.notifier.posted.isEmpty)
    }

    @Test("resuming withdraws the reminder and stops the watching")
    func resumingWithdraws() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start)

        harness.controller.recordingDidResume()
        harness.controller.recordingObserved(
            MovementReminderHarness.fix(
                northOfAnchorBy: 5000,
                takenAt: start.addingTimeInterval(600)
            ),
            at: start.addingTimeInterval(600)
        )
        await harness.controller.settle()

        #expect(harness.notifier.withdrawn.contains(.resumeRecording))
        #expect(
            harness.notifier.posted.isEmpty,
            "a resumed recording is not a paused one that happens to be moving"
        )
    }

    @Test("a refused permission is silent rather than queued")
    func refusedPermissionPostsNothing() async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.isAuthorized = false
        harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start)

        harness.controller.recordingObserved(
            MovementReminderHarness.fix(
                northOfAnchorBy: 900,
                takenAt: start.addingTimeInterval(600)
            ),
            at: start.addingTimeInterval(600)
        )
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    // MARK: A running recording

    @Test("a quarter of an hour stationary posts the pause suggestion")
    func stillnessPostsTheSuggestion() async {
        let harness = MovementReminderHarness.harness()

        harness.controller.recordingObserved(isStationary: true, at: start)
        harness.controller.recordingObserved(
            isStationary: true,
            at: start.addingTimeInterval(MovementReminderPolicy.stillFor)
        )
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.pauseRecording])
    }

    @Test("moving again takes the pause suggestion down")
    func movingWithdrawsTheSuggestion() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.recordingObserved(isStationary: true, at: start)
        harness.controller.recordingObserved(
            isStationary: true,
            at: start.addingTimeInterval(MovementReminderPolicy.stillFor)
        )

        harness.controller.recordingObserved(
            isStationary: false,
            at: start.addingTimeInterval(MovementReminderPolicy.stillFor + 60)
        )
        await harness.controller.settle()

        #expect(harness.notifier.withdrawn.contains(.pauseRecording))
    }

    /// Pausing answers the question the suggestion asked, and a suggestion
    /// left up beside a paused recording is the app contradicting itself.
    @Test("pausing takes the pause suggestion down")
    func pausingWithdrawsTheSuggestion() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.recordingObserved(isStationary: true, at: start)

        harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start)
        await harness.controller.settle()

        #expect(harness.notifier.withdrawn.contains(.pauseRecording))
    }

    @Test("a recording that ends withdraws both of its reminders")
    func endingWithdrawsBoth() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.recordingDidPause(at: MovementReminderHarness.anchor, on: start)

        harness.controller.recordingDidEnd()
        await harness.controller.settle()

        #expect(harness.notifier.withdrawn.contains(.resumeRecording))
        #expect(harness.notifier.withdrawn.contains(.pauseRecording))
    }

    // MARK: A paused walk

    @Test("covering the trail with the walk paused posts the walk reminder")
    func walkingWhilePausedPostsTheReminder() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.walkDidPause(trailTitle: "Ridge Loop", atDistance: 1200)

        harness.controller.walkObserved(distanceAlongRoute: 1400, at: start)
        harness.controller.walkObserved(
            distanceAlongRoute: 1900,
            at: start.addingTimeInterval(1800)
        )
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.resumeWalk])
        #expect(harness.notifier.posted.first?.body.contains("Ridge Loop") == true)
    }

    /// The same precedence the widget and the Lock Screen apply. A walker
    /// recording their own track along an imported route has one walk, and
    /// the recording is the half that would be lost.
    @Test("a recording suppresses the walk's reminder")
    func recordingOutranksTheWalk() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.hasActiveRecording = { true }
        harness.controller.walkDidPause(trailTitle: "Ridge Loop", atDistance: 0)

        harness.controller.walkObserved(distanceAlongRoute: 2000, at: start)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    /// Backwards along the route is movement too — a walker who turned round
    /// at the summit with the walk paused is covering ground either way.
    @Test("the walk's displacement is measured in both directions")
    func walkingBackDownAlsoReminds() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.walkDidPause(trailTitle: "Ridge Loop", atDistance: 2000)

        harness.controller.walkObserved(distanceAlongRoute: 1400, at: start)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.resumeWalk])
    }

    @Test("resuming or ending the walk withdraws its reminder")
    func walkResumeWithdraws() async {
        let harness = MovementReminderHarness.harness()
        harness.controller.walkDidPause(trailTitle: "Ridge Loop", atDistance: 0)

        harness.controller.walkDidResumeOrEnd()
        harness.controller.walkObserved(distanceAlongRoute: 3000, at: start)
        await harness.controller.settle()

        #expect(harness.notifier.withdrawn.contains(.resumeWalk))
        #expect(harness.notifier.posted.isEmpty)
    }
}
