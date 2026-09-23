//
//  MovementReminderUrgencyTests.swift
//  OpenHikesTests
//
//  Which reminders may break through a Focus, and how a Notification Summary
//  orders them against each other.
//
//  Both are pure functions of ``MovementReminderKind``, which is the whole
//  reason they are assertable at all: a delivered banner is not something a
//  hosted test can read — see ``MovementReminderNotifying`` for why — while
//  the level and the score are the entire decision, taken once and spent at
//  one call site.
//
//  So the tests are written against the *set* rather than case by case
//  wherever they can be. A new ``MovementReminderKind`` compiles against an
//  exhaustive switch without anybody choosing which side of the line it
//  belongs on, and "every kind that breaks through a Focus is one of these
//  two" is the assertion that notices.
//

import Foundation
@testable import OpenHikes
import Testing
import UserNotifications

@Suite("Movement reminder urgency")
struct MovementReminderUrgencyTests {
    /// The two that are not bookkeeping: an agency's warning about the ground
    /// the hiker is standing on, and a fork taken wrong.
    private static let warnings: Set<MovementReminderKind> = [.severeWeather, .leftTheTrail]

    @Test("a warning about the weather or the route breaks through a Focus")
    func warningsAreTimeSensitive() {
        let raised = MovementReminderKind.allCases
            .filter { $0.interruptionLevel == .timeSensitive }

        #expect(
            Set(raised) == Self.warnings,
            "only a warning is worth interrupting a Focus, and both of them must"
        )
    }

    /// The other half of the same line, stated positively: the three
    /// bookkeeping reminders stay where a Focus can hold them.
    @Test("bookkeeping waits for the Focus to end", arguments: [
        MovementReminderKind.pauseRecording,
        MovementReminderKind.resumeRecording,
        MovementReminderKind.resumeWalk,
        MovementReminderKind.walkNearby,
    ])
    func conveniencesStayActive(kind: MovementReminderKind) {
        #expect(kind.interruptionLevel == .active)
    }

    /// `.critical` overrides the ringer switch and is granted by request;
    /// `.passive` would keep the banner off the Lock Screen entirely, which
    /// is where every one of these is read. Neither is reachable today and
    /// neither should become reachable by accident.
    @Test("no kind asks for a level this app has not argued for", arguments: MovementReminderKind.allCases)
    func levelsStayInsideTheTwoChosen(kind: MovementReminderKind) {
        #expect(kind.interruptionLevel == .timeSensitive || kind.interruptionLevel == .active)
    }

    // MARK: - What a summary leads with

    @Test("the storm warning leads the summary")
    func theWeatherWarningOutranksEverything() {
        let others = MovementReminderKind.allCases.filter { $0 != .severeWeather }

        #expect(others.allSatisfy { $0.relevanceScore < MovementReminderKind.severeWeather.relevanceScore })
    }

    /// The finer half of the same argument the level makes, and the one that
    /// matters when several are waiting together: a summary that led with
    /// "Taking a break?" and buried the warning under it would be ordering
    /// them by arrival, which is what an unset score does.
    @Test("nothing a Focus may hold outranks something that breaks through one")
    func relevanceAgreesWithTheInterruptionLevel() throws {
        let raised = MovementReminderKind.allCases.filter { $0.interruptionLevel == .timeSensitive }
        let held = MovementReminderKind.allCases.filter { $0.interruptionLevel == .active }
        let lowestRaised = try #require(raised.map(\.relevanceScore).min())
        let highestHeld = try #require(held.map(\.relevanceScore).max())

        #expect(lowestRaised > highestHeld)
    }

    /// Losing track of a walk outranks spoiling a moving-time average: the
    /// first costs a hiker a kilometre of track they cannot get back, the
    /// second costs them a number they can still correct afterwards.
    @Test("a walk going unrecorded outranks a stop being counted as moving", arguments: [
        MovementReminderKind.resumeRecording,
        MovementReminderKind.resumeWalk,
    ])
    func resumingOutranksPausing(kind: MovementReminderKind) {
        #expect(kind.relevanceScore > MovementReminderKind.pauseRecording.relevanceScore)
    }

    /// The system reads the score as a fraction and clamps what it is given;
    /// a score outside the range is a ladder that no longer says what it
    /// looks like it says.
    @Test("every score is inside the range the system reads", arguments: MovementReminderKind.allCases)
    func scoresAreFractions(kind: MovementReminderKind) {
        #expect((0.0...1.0).contains(kind.relevanceScore))
    }
}
