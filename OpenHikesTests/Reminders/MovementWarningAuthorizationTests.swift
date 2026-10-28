//
//  MovementWarningAuthorizationTests.swift
//  OpenHikesTests
//
//  Permission can change while a departure, a late finish or a rest is still
//  under way. A refusal must leave the warning unsaid, and an answer that
//  arrives after its condition ended must not describe the old condition.
//

import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Movement warnings across notification authorization")
struct MovementWarningAuthorizationTests {
    private final class RecordingState {
        var isActive = false
    }

    nonisolated enum Warning: CaseIterable, Sendable {
        case offTrail, dusk, stillness

        var kind: MovementReminderKind {
            switch self {
            case .offTrail: .leftTheTrail
            case .dusk: .afterDark
            case .stillness: .pauseRecording
            }
        }
    }

    private let start = MovementReminderHarness.start

    @Test("a refused warning is delivered once after permission is allowed", arguments: Warning.allCases)
    func deniedThenAllowed(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.isAuthorized = false
        makeEligible(warning, in: harness)
        await harness.controller.settle()
        #expect(harness.notifier.posted.isEmpty)

        harness.notifier.isAuthorized = true
        harness.postDidBecomeActive()
        await harness.controller.settle()
        refresh(warning, in: harness)
        refresh(warning, in: harness)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [warning.kind])
    }

    @Test("returning from Settings retries a still-current warning", arguments: Warning.allCases)
    func foregroundRetriesAnEligibleWarning(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.isAuthorized = false
        makeEligible(warning, in: harness)
        await harness.controller.settle()
        #expect(harness.notifier.posted.isEmpty)

        harness.notifier.isAuthorized = true
        harness.postDidBecomeActive()
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [warning.kind])
    }

    @Test("a changed condition cancels a warning awaiting permission", arguments: Warning.allCases)
    func changedConditionCancelsThePendingWarning(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        makeEligible(warning, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }

        clearCondition(warning, in: harness)
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
        makeEligible(warning, in: harness, after: 3600)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [warning.kind], "a canceled warning spent no allowance")
    }

    @Test("ending the subject cancels a warning awaiting permission", arguments: Warning.allCases)
    func endingTheSubjectCancelsThePendingWarning(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        makeEligible(warning, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }

        endSubject(warning, in: harness)
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    @Test("overlapping eligible observations post once", arguments: Warning.allCases)
    func overlappingObservationsPostOnce(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        makeEligible(warning, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }
        refresh(warning, in: harness)
        refresh(warning, in: harness)

        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [warning.kind])
    }

    @Test("an old permission answer cannot post for a new subject", arguments: Warning.allCases)
    func aNewSubjectHasItsOwnWarning(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        makeEligible(warning, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }

        endSubject(warning, in: harness)
        makeEligible(warning, in: harness, trailTitle: "New Walk")
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [warning.kind])
        if warning != .stillness {
            #expect(harness.notifier.posted.first?.body.contains("New Walk") == true)
        }
    }

    @Test("turning reminders off cancels a warning awaiting permission", arguments: Warning.allCases)
    func disabledRemindersCancelThePendingWarning(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        harness.notifier.holdsThePrompt = true
        makeEligible(warning, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }

        harness.defaults.set(false, forKey: SettingsKey.movementRemindersEnabled)
        harness.controller.reconcileWithPreferences()
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    @Test("a recording takeover silences a walk warning awaiting permission", arguments: [Warning.offTrail, .dusk])
    func recordingTakeoverSilencesThePendingWarning(_ warning: Warning) async {
        let harness = MovementReminderHarness.harness()
        let recording = RecordingState()
        harness.controller.hasActiveRecording = { recording.isActive }
        harness.notifier.holdsThePrompt = true
        makeEligible(warning, in: harness)
        guard await harness.notifier.awaitPrompt() else { return }

        recording.isActive = true
        harness.notifier.answerPrompt(allowing: true)
        await harness.controller.settle()
        #expect(harness.notifier.posted.isEmpty)

        recording.isActive = false
        refresh(warning, in: harness)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [warning.kind])
    }

    func makeEligible(
        _ warning: Warning,
        in harness: MovementReminderHarness.Harness,
        after seconds: TimeInterval = 0,
        trailTitle: String = "Ridge Loop"
    ) {
        let now = start.addingTimeInterval(seconds)
        switch warning {
        case .offTrail:
            harness.controller.walkObserved(offRouteMeters: 400, trailTitle: trailTitle, at: now)
            harness.controller.walkObserved(
                offRouteMeters: 400,
                trailTitle: trailTitle,
                at: now.addingTimeInterval(MovementReminderPolicy.offTrailDwell)
            )
        case .dusk:
            harness.controller.walkFinishEstimated(
                finishAt: now.addingTimeInterval(3 * 3600),
                civilDusk: now.addingTimeInterval(2 * 3600),
                trailTitle: trailTitle,
                at: now
            )
        case .stillness:
            harness.controller.recordingObserved(isStationary: true, at: now)
            harness.controller.recordingObserved(
                isStationary: true,
                at: now.addingTimeInterval(MovementReminderPolicy.stillFor)
            )
        }
    }

    private func refresh(_ warning: Warning, in harness: MovementReminderHarness.Harness) {
        switch warning {
        case .offTrail:
            harness.controller.walkObserved(
                offRouteMeters: 450,
                trailTitle: "Ridge Loop",
                at: start.addingTimeInterval(MovementReminderPolicy.offTrailDwell + 60)
            )
        case .dusk:
            makeEligible(.dusk, in: harness, after: 60)
        case .stillness:
            harness.controller.recordingObserved(
                isStationary: true,
                at: start.addingTimeInterval(MovementReminderPolicy.stillFor + 60)
            )
        }
    }

    func clearCondition(_ warning: Warning, in harness: MovementReminderHarness.Harness) {
        switch warning {
        case .offTrail:
            harness.controller.walkObserved(
                offRouteMeters: 20,
                trailTitle: "Ridge Loop",
                at: start.addingTimeInterval(MovementReminderPolicy.offTrailDwell + 60)
            )
        case .dusk:
            harness.controller.walkFinishEstimated(
                finishAt: start.addingTimeInterval(3600),
                civilDusk: start.addingTimeInterval(2 * 3600),
                trailTitle: "Ridge Loop",
                at: start.addingTimeInterval(60)
            )
        case .stillness:
            harness.controller.recordingObserved(
                isStationary: false,
                at: start.addingTimeInterval(MovementReminderPolicy.stillFor + 60)
            )
        }
    }

    private func endSubject(_ warning: Warning, in harness: MovementReminderHarness.Harness) {
        if warning == .stillness {
            harness.controller.recordingDidEnd()
        } else {
            harness.controller.walkDidStopFollowing()
        }
    }
}
