//
//  WeatherPollAskTests.swift
//  OpenHikesTests
//
//  The map's location button, heard by the real poll loop
//  (``OpenHikesModel/pollWeather(policy:)``).
//
//  The press that matters most changes nothing the loop could see: the badge
//  is about the hiker already, standing where they stood, with a reading a
//  few minutes old. So what is held here is that the press is a wake of its
//  own, with a floor of its own, and that it takes the badge from a place the
//  map has left.
//
//  How long the floor is belongs to ``WeatherRequestStateTests``, which has a
//  clock. This loop reads the wall clock, so the floor is set to nothing, and
//  a second request is then the press being held to its own floor and not to
//  a focus's.
//
//  The services are the case's own, for the reason the repository's
//  *Deliberate test seams* section gives.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

private extension WeatherPollingPolicy {
    /// The standard policy with no floor under a press, so one made a moment
    /// after a reading is already past it.
    static let noFloorUnderAnAsk = Self(freshnessInterval: 15 * 60, minimumRequestInterval: 0, retryDelays: [5])
}

@MainActor
@Suite("Weather poll asks", .timeLimit(.minutes(1)))
struct WeatherPollAskTests {
    private let here = CLLocationCoordinate2D(latitude: 47.4979, longitude: 19.0402)
    private let chamonix = WeatherSubject.place(
        CLLocationCoordinate2D(latitude: 45.8326, longitude: 6.8652),
        name: "Chamonix"
    )

    private let forecasts = PromptForecasts()
    private let manager: WeatherManager
    private let model: OpenHikesModel
    private let container: ModelContainer
    private let sandbox: TileSandbox

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "weather-ask-\(UUID().uuidString)"))
        manager = WeatherManager(
            store: WeatherReadingStore(defaults: defaults),
            widgetPublisher: WeatherWidgetPublisher(
                reload: { /* no widget to redraw */ },
                store: WeatherWidgetPublisher.Store(
                    load: { nil },
                    save: { _ in /* no widget to tell */ },
                    clear: { /* nothing kept */ }
                )
            ),
            readings: forecasts
        )
        container = try Fixture.modelContainer()
        sandbox = TileSandbox()
        model = OpenHikesModel(
            container: container,
            backgroundTracker: BackgroundTrailTracker(
                container: container,
                monitor: StubLocationMonitor(),
                defaults: defaults
            ),
            autoSaveController: AutoSaveController(store: sandbox.store, drainInterval: nil),
            hikeRecorder: HikeRecorder(container: container),
            locationManager: LocationManager(),
            weatherManager: manager,
            significantLocations: SignificantLocationFeed(monitor: DormantLocationSource()),
            defaults: defaults
        )
    }

    /// Whether the badge draws a reading about `subject`.
    private func isReading(_ subject: WeatherSubject) -> Bool {
        manager.state.snapshot != nil && manager.state.subject == subject
    }

    /// The badge already about the hiker at ``here``, by a focus alone, with
    /// its one reading in.
    private func startAboutTheHiker(policy: WeatherPollingPolicy) async -> Task<Void, Never> {
        let poll = Task { await model.pollWeather(policy: policy) }
        model.weatherFocus.focus(on: .me(here))
        await settleDelegateHop(until: "the hiker's first reading is on the badge") { isReading(.me(here)) }
        return poll
    }

    private func end(_ poll: Task<Void, Never>) async {
        poll.cancel()
        await poll.value
    }

    /// A focus would call this reading fresh for a quarter of an hour. The
    /// press is not a focus: it is held to the floor the policy gives it,
    /// which here is none.
    @Test("a press with the badge already about the hiker asks again")
    func aPressThatChangesNothingAsksAgain() async {
        let poll = await startAboutTheHiker(policy: .noFloorUnderAnAsk)
        #expect(forecasts.timesAsked(about: here) == 1)

        model.weatherFocus.focusOnHiker(at: here)

        await settleDelegateHop(until: "the press was answered with a second request") {
            forecasts.timesAsked(about: here) == 2
        }
        await end(poll)
    }

    /// The control: the same reading, focused again, is still fresh.
    @Test("a focus on the hiker already on the badge asks nothing")
    func aFocusThatChangesNothingAsksNothing() async {
        let poll = await startAboutTheHiker(policy: .noFloorUnderAnAsk)

        // Somewhere else and back, so the loop has taken two more focuses by
        // the time the hiker is on the badge again.
        model.weatherFocus.focus(on: chamonix)
        await settleDelegateHop(until: "the searched place's reading is on the badge") { isReading(chamonix) }
        model.weatherFocus.focus(on: .me(here))
        await settleDelegateHop(until: "the hiker is on the badge again") { isReading(.me(here)) }

        #expect(forecasts.timesAsked(about: here) == 1)
        await end(poll)
    }

    @Test("a press takes the badge from a searched place, and asks about here")
    func aPressTakesTheBadgeFromASearch() async {
        let poll = Task { await model.pollWeather() }
        model.weatherFocus.focus(on: chamonix)
        await settleDelegateHop(until: "the searched place's reading is on the badge") { isReading(chamonix) }

        model.weatherFocus.focusOnHiker(at: here)

        await settleDelegateHop(until: "the hiker's reading is on the badge") { isReading(.me(here)) }
        #expect(forecasts.timesAsked(about: here) == 1, "one press is one request, though it woke the loop twice")
        await end(poll)
    }
}
