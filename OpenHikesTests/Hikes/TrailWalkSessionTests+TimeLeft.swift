//
//  TrailWalkSessionTests+TimeLeft.swift
//  OpenHikesTests
//
//  The walk under way's time left, as the session hands it to the readout,
//  the widget and the Lock Screen — and the after-dark reminder it drives.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
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
            daylight: { _, _ in WeatherDaylight(civilDusk: dusk) }
        )
    }

    /// A session whose light comes from a real weather manager, through the
    /// same rule the app composes it with.
    private func weatherSession(
        _ harness: MovementReminderHarness.Harness,
        weather: WeatherManager
    ) -> TrailWalkSession {
        TrailWalkSession(
            context: context,
            reminders: harness.controller,
            clock: clock.read,
            daylight: { hikeID, position in weather.daylight(forWalkOn: hikeID, at: position) }
        )
    }

    /// Dusk in eight minutes by default, which the rest of the fixture trail
    /// outlasts.
    private func reading(duskIn seconds: TimeInterval = 8 * 60) -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "sun.max.fill",
            temperature: Measurement(value: 12, unit: UnitTemperature.celsius),
            conditionDescription: "Clear",
            capturedAt: clock.read(),
            conditions: .preview,
            daylight: WeatherDaylight(civilDusk: clock.read().addingTimeInterval(seconds))
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

    /// A walk forgotten because its hike was deleted ends as surely as one
    /// that was ended, and the next walk is owed its own warning.
    @Test("deleting the walked hike takes the warning down and re-arms it")
    func deletingTheHikeRearmsTheWarning() async {
        let harness = MovementReminderHarness.harness()
        let session = daylightSession(harness, dusk: clock.read().addingTimeInterval(8 * 60))
        let first = hike()
        walk(session, hike: first, profile: RouteProfile(route: first.route), from: 0, through: 3)
        session.discardWalk(forDeletedHike: first.id)

        let second = hike(title: "Valley Path")
        walk(session, hike: second, profile: RouteProfile(route: second.route), from: 0, through: 3)
        await harness.controller.settle()

        #expect(harness.notifier.withdrawn.contains(.afterDark))
        #expect(harness.notifier.postedKinds == [.afterDark, .afterDark])
    }

    @Test("the light is asked about the walked hike, where the hiker matched on it")
    func daylightIsAskedAboutTheWalk() throws {
        let harness = MovementReminderHarness.harness()
        var asked: [(UUID, CLLocationCoordinate2D?)] = []
        let session = TrailWalkSession(
            context: context,
            reminders: harness.controller,
            clock: clock.read,
            daylight: { hikeID, position in
                asked.append((hikeID, position))
                return nil
            }
        )
        let walked = hike()
        let profile = RouteProfile(route: walked.route)
        walk(session, hike: walked, profile: profile, from: 0, through: 3)

        let last = try #require(asked.last)
        let matched = try #require(profile.coordinate(atDistance: profile.distances[3]))
        let position = try #require(last.1)
        #expect(last.0 == walked.id)
        #expect(position.latitude == matched.latitude && position.longitude == matched.longitude)
    }

    /// #874. Browsing another trail mid-walk moves the badge to it; a dusk
    /// that trail reads a long way off is not this walk's, and neither posts
    /// the warning nor spends it.
    @Test("a distant trail on the badge mid-walk neither warns nor spends the warning")
    func aBrowsedTrailsDuskIsNotTheWalks() async throws {
        let harness = MovementReminderHarness.harness()
        let walked = hike()
        let start = try #require(walked.route.first)
        let farAway = CLLocationCoordinate2D(latitude: start.latitude + 2, longitude: start.longitude)
        let browsedID = UUID()
        let weather = WeatherManager(widgetPublisher: .inert)
        weather.applyUITestSnapshot(
            reading(),
            subject: .trail(farAway, hikeID: browsedID, name: "Elsewhere")
        )
        let session = weatherSession(harness, weather: weather)
        let profile = RouteProfile(route: walked.route)

        walk(session, hike: walked, profile: profile, from: 0, through: 3)
        await harness.controller.settle()
        #expect(harness.notifier.posted.isEmpty)

        // Back on the walked trail: its own dusk is the one that counts.
        weather.applyUITestSnapshot(
            reading(),
            subject: .trail(farAway, hikeID: walked.id, name: walked.title)
        )
        walk(session, hike: walked, profile: profile, from: 3, through: 3)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [.afterDark])
    }

    /// The other half of #874: the badge left on a distant trail must not
    /// silence the walk either, while the walked trail's own reading is still
    /// cached. A hiker who glances at another trail and pockets the phone
    /// leaves the badge there for the rest of the walk.
    @Test("a distant trail on the badge mid-walk leaves the walked trail's dusk in force")
    func browsingAwayKeepsTheWalksDusk() async throws {
        let harness = MovementReminderHarness.harness()
        let walked = hike()
        let start = try #require(walked.route.first)
        let here = CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)
        let farAway = CLLocationCoordinate2D(latitude: here.latitude + 2, longitude: here.longitude)
        let weather = WeatherManager(widgetPublisher: .inert)
        weather.applyUITestSnapshot(reading(), subject: .trail(here, hikeID: walked.id, name: walked.title))
        weather.applyUITestSnapshot(
            reading(duskIn: 10 * 3600),
            subject: .trail(farAway, hikeID: UUID(), name: "Elsewhere")
        )
        let session = weatherSession(harness, weather: weather)

        walk(session, hike: walked, profile: RouteProfile(route: walked.route), from: 0, through: 3)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [.afterDark])
    }

    @Test("moving focus cannot spend the dusk warning on a distant cached reading", arguments: [false, true])
    func aCachedDuskStaysWhereItWasRead(isTrail: Bool) async throws {
        let harness = MovementReminderHarness.harness()
        let walked = hike()
        let start = try #require(walked.route.first)
        let here = CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)
        let farAway = CLLocationCoordinate2D(latitude: here.latitude + 2, longitude: here.longitude)
        let subject: WeatherSubject = isTrail ? .trail(farAway, hikeID: UUID(), name: "Nearby") : .me(farAway)
        let weather = WeatherManager(widgetPublisher: .inert)
        weather.applyUITestSnapshot(reading(), subject: subject)
        weather.focus(on: subject.moved(to: here), willRequest: true)
        let session = weatherSession(harness, weather: weather)
        let profile = RouteProfile(route: walked.route)

        walk(session, hike: walked, profile: profile, from: 0, through: 3)
        await harness.controller.settle()
        #expect(harness.notifier.posted.isEmpty)

        weather.applyUITestSnapshot(reading(), subject: subject.moved(to: here))
        walk(session, hike: walked, profile: profile, from: 3, through: 4)
        await harness.controller.settle()
        #expect(harness.notifier.postedKinds == [.afterDark])
    }
}
