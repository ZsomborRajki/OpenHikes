//
//  TrailWalkSessionTests+TimeLeft.swift
//  OpenHikesTests
//
//  The walk under way's time left, as the session hands it to the readout,
//  the widget and the Lock Screen — and the after-dark reminder it drives.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

extension TrailWalkSessionTests {
    private func daylightSession(
        _ harness: MovementReminderHarness.Harness,
        dusk: Date?
    ) -> TrailWalkSession {
        TrailWalkSession(
            context: context,
            reminders: harness.controller,
            clock: clock.read,
            daylight: { WeatherDaylight(civilDusk: dusk) }
        )
    }

    @Test("a walk under way knows how long it has left, and says so in its payload")
    func aWalkHasTimeLeft() throws {
        let session = session()
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 3)

        let left = try #require(session.secondsLeft())
        #expect(left > 0)
        #expect(session.payload(for: walked.id)?.secondsLeft == left)
    }

    @Test("no walk, no time left")
    func noWalkNoTimeLeft() {
        let session = session()
        #expect(session.secondsLeft() == nil)
    }

    @Test("a walk that will end after dusk posts the reminder")
    func aLateWalkIsWarned() async {
        let harness = MovementReminderHarness.harness()
        // Dusk in five minutes: the rest of this trail takes far longer.
        let session = daylightSession(harness, dusk: clock.read().addingTimeInterval(5 * 60 + 3 * 60))
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 3)
        await harness.controller.settle()

        #expect(harness.notifier.postedKinds == [.afterDark])
    }

    @Test("a walk that ends in daylight says nothing")
    func anEarlyWalkIsQuiet() async {
        let harness = MovementReminderHarness.harness()
        let session = daylightSession(harness, dusk: clock.read().addingTimeInterval(24 * 3600))
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 3)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }

    /// Polar summer: `WeatherDaylight` carries no dusk, and nothing is said.
    @Test("with no dusk to cross, nothing is said")
    func noDuskIsQuiet() async {
        let harness = MovementReminderHarness.harness()
        let session = daylightSession(harness, dusk: nil)
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 3)
        await harness.controller.settle()

        #expect(harness.notifier.posted.isEmpty)
    }
}
