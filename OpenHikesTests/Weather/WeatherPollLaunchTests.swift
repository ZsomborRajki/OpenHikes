//
//  WeatherPollLaunchTests.swift
//  OpenHikesTests
//
//  What a launch does with the weather before anybody has focused anything,
//  driven through the real poll loop (``OpenHikesModel/pollWeather(policy:)``).
//
//  A launch puts the stored reading back on the badge with no subject behind
//  it, and the loop starts with nothing to be about. Its first pass used to
//  treat that as a subject taken away: it cleared the badge and the widget's
//  temperature, and then waited for significant-change delivery to say where
//  the hiker is, which a hiker who has not moved may never hear. So a launch
//  drew no weather until a hike was opened.
//
//  What is held here: the stored reading stays where it is, the first fix of
//  the feed the map already runs makes the hiker the subject and asks, and a
//  recording that began before any fix still takes the old place off the
//  badge.
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

/// What reached the widget, in order: a temperature, or a `nil` for a clear.
nonisolated private final class LaunchWidgetLog: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [Double?] = []

    var all: [Double?] {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    private func record(_ write: Double?) {
        lock.lock()
        defer { lock.unlock() }
        written.append(write)
    }

    var seam: WeatherWidgetPublisher.Store {
        WeatherWidgetPublisher.Store(
            load: { nil },
            save: { self.record($0.temperatureCelsius) },
            clear: { self.record(nil) }
        )
    }
}

@MainActor
@Suite("Weather poll launch", .timeLimit(.minutes(1)))
struct WeatherPollLaunchTests {
    private static let lastNightCelsius = 4.0
    /// How many main-actor round trips the loop is given to take its first
    /// passes — see ``letTheLoopStart()``.
    private static let startingRoundTrips = 20

    private let home = CLLocationCoordinate2D(latitude: 47.4979, longitude: 19.0402)
    private let trailhead = CLLocationCoordinate2D(latitude: 47.6300, longitude: 12.8600)
    private let chamonix = WeatherSubject.place(
        CLLocationCoordinate2D(latitude: 45.8326, longitude: 6.8652),
        name: "Chamonix"
    )

    private let forecasts = PromptForecasts()
    private let widget = LaunchWidgetLog()
    private let store: WeatherReadingStore
    private let manager: WeatherManager
    private let model: OpenHikesModel
    private let container: ModelContainer
    private let sandbox: TileSandbox

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "weather-launch-\(UUID().uuidString)"))
        store = WeatherReadingStore(defaults: defaults)
        manager = WeatherManager(
            store: store,
            widgetPublisher: WeatherWidgetPublisher(reload: { /* no widget to redraw */ }, store: widget.seam),
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

    /// Last night's reading about `subject`, stored as a launch finds it and
    /// put back on the badge as a launch puts it.
    private func restoreLastNight(about subject: WeatherSubject) -> WeatherSnapshot {
        let lastNight = WeatherSnapshot(
            symbolName: "moon.fill",
            temperature: Measurement(value: Self.lastNightCelsius, unit: UnitTemperature.celsius),
            conditionDescription: "Clear",
            capturedAt: Date(timeIntervalSinceNow: -8 * 3600),
            conditions: .preview
        )
        store.save(snapshot: lastNight, subject: subject)
        manager.restoreLastReading()
        return lastNight
    }

    /// The foreground feed's fix at `coordinate`, delivered as Core Location
    /// delivers one.
    private func deliverFix(at coordinate: CLLocationCoordinate2D) {
        let fix = CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: -1,
            course: -1,
            speed: -1,
            timestamp: .now
        )
        model.locationManager.locationManager(CLLocationManager(), didUpdateLocations: [fix])
    }

    /// Hands the loop the main actor until it has taken what each of its
    /// streams says first.
    ///
    /// Barriers rather than a condition, because the pass being waited for
    /// has no effect to name once it is right: leaving the badge alone is the
    /// behaviour. Too few would only cost a case its point, never its result,
    /// and before the fix these were enough to find the badge cleared.
    private func letTheLoopStart() async {
        for _ in 0..<Self.startingRoundTrips { await settleDelegateHop() }
    }

    private func end(_ poll: Task<Void, Never>) async {
        poll.cancel()
        await poll.value
    }

    @Test("a launch nobody has focused keeps the stored reading on the badge and the widget")
    func theStoredReadingStays() async {
        #expect(model.weatherFocus.subject == nil, "precondition: a launch starts with nothing focused")
        let lastNight = restoreLastNight(about: .me(home))
        let poll = Task { await model.pollWeather() }

        await letTheLoopStart()

        await manager.settleWidgetPublishing()
        #expect(manager.state == .reading(lastNight, subject: .me(home)))
        #expect(widget.all == [Self.lastNightCelsius], "put back once, and never cleared")
        await end(poll)
    }

    @Test("the first fix of a launch makes the hiker the subject, and asks about where they are")
    func theFirstFixAsksAboutHere() async {
        _ = restoreLastNight(about: chamonix)
        let poll = Task { await model.pollWeather() }
        await letTheLoopStart()

        deliverFix(at: trailhead)

        await settleDelegateHop(until: "today's reading about the hiker is on the badge") {
            manager.state.subject == .me(trailhead)
                && manager.state.snapshot?.temperature.value == PromptForecasts.celsius
        }
        await manager.settleWidgetPublishing()
        #expect(forecasts.timesAsked(about: trailhead) == 1)
        #expect(!widget.all.contains(nil), "the widget kept a temperature throughout")
        #expect(widget.all.last == PromptForecasts.celsius)
        await end(poll)
    }

    /// The other way to have no subject, which must still clear the badge:
    /// see ``WeatherFocus/pinToHiker(at:)``.
    @Test("a recording that began before any fix takes the old place off the badge")
    func aRecordingWithNoFixClearsTheBadge() async {
        _ = restoreLastNight(about: chamonix)
        model.weatherFocus.pinToHiker(at: nil)
        let poll = Task { await model.pollWeather() }

        await settleDelegateHop(until: "the badge has stopped drawing the searched place") {
            manager.state == .idle
        }

        // And the recording's first fix is the hiker's weather.
        deliverFix(at: trailhead)
        await settleDelegateHop(until: "the recording's reading is on the badge") {
            manager.state.subject == .me(trailhead) && manager.state.snapshot != nil
        }
        await end(poll)
    }
}
