//
//  WeatherPollFocusTests.swift
//  OpenHikesTests
//
//  A trail opened while another's forecast is still out takes the badge at
//  once, driven through the real poll loop (``OpenHikesModel/pollWeather(policy:)``).
//  The first trail's request is held, as a stalled WeatherKit request is, and
//  answers only when told to: the second trail's cached reading is on the
//  badge before it does, and its late answer, a success or a failure, leaves
//  the second trail's badge alone. Its answer still counts for its own trail:
//  a success is kept and fresh, and a failure backs off.
//
//  The services are the case's own, for the reason the repository's
//  *Deliberate test seams* section gives.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import RealModule
import SwiftData
import Testing

/// A WeatherKit that answers each place only when it is told to.
@MainActor
private final class HeldForecasts: WeatherReadingFetching {
    private static let tolerance = 1e-9

    private var held: [(latitude: Double, continuation: CheckedContinuation<WeatherSnapshot, any Error>)] = []
    private var asked: [Double] = []

    func reading(at coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot {
        asked.append(coordinate.latitude)
        return try await withCheckedThrowingContinuation { held.append((coordinate.latitude, $0)) }
    }

    func isHolding(_ subject: WeatherSubject) -> Bool {
        index(of: subject) != nil
    }

    func timesAsked(about subject: WeatherSubject) -> Int {
        asked.count { $0.isApproximatelyEqual(to: subject.coordinate.latitude, absoluteTolerance: Self.tolerance) }
    }

    func answer(_ subject: WeatherSubject, with result: Result<WeatherSnapshot, any Error>) {
        guard let index = index(of: subject) else {
            Issue.record("No forecast is out for \(subject.key)")
            return
        }
        held.remove(at: index).continuation.resume(with: result)
    }

    /// Lets every forecast still out go, so no continuation outlives a case.
    func release() {
        for forecast in held { forecast.continuation.resume(throwing: CancellationError()) }
        held = []
    }

    private func index(of subject: WeatherSubject) -> Int? {
        held.firstIndex { forecast in
            forecast.latitude.isApproximatelyEqual(to: subject.coordinate.latitude, absoluteTolerance: Self.tolerance)
        }
    }
}

/// What reached the widget, in order: a temperature, or a `nil` for a clear.
nonisolated private final class WidgetLog: @unchecked Sendable {
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

private struct ForecastFailure: Error {}

@MainActor
@Suite("Weather poll focus", .timeLimit(.minutes(1)))
struct WeatherPollFocusTests {
    private enum Celsius {
        static let firstAnswer = 21.0
        static let secondCached = 4.0
        static let secondAnswer = 9.0
    }

    private let first = WeatherSubject.place(
        CLLocationCoordinate2D(latitude: 45.8326, longitude: 6.8652),
        name: "Chamonix"
    )
    private let second = WeatherSubject.place(
        CLLocationCoordinate2D(latitude: 47.5553, longitude: 12.9225),
        name: "Watzmann"
    )

    private let forecasts = HeldForecasts()
    private let widget = WidgetLog()
    private let manager: WeatherManager
    private let model: OpenHikesModel
    private let container: ModelContainer
    private let sandbox: TileSandbox

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "weather-poll-\(UUID().uuidString)"))
        manager = WeatherManager(
            store: WeatherReadingStore(defaults: defaults),
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

    private static func reading(celsius: Double) -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "sun.max.fill",
            temperature: Measurement(value: celsius, unit: UnitTemperature.celsius),
            conditionDescription: "Clear",
            capturedAt: Date(timeIntervalSinceReferenceDate: 1_000_000),
            conditions: .preview
        )
    }

    /// Starts the poll with the second trail's reading cached, opens the
    /// first, and then the second while the first's forecast is out. Returns
    /// the poll, and how many widget writes there were by then.
    private func openTheSecondWhileTheFirstIsOut() async -> (poll: Task<Void, Never>, writes: Int) {
        manager.applyUITestSnapshot(Self.reading(celsius: Celsius.secondCached), subject: second)
        let poll = Task { await model.pollWeather() }
        model.weatherFocus.focus(on: first)
        await settleDelegateHop(until: "the first trail's forecast is out") { forecasts.isHolding(first) }

        model.weatherFocus.focus(on: second)
        await settleDelegateHop(until: "the second trail's cached reading is on the badge") {
            manager.state == .reading(Self.reading(celsius: Celsius.secondCached), subject: second)
        }
        await settleDelegateHop(until: "the second trail's own forecast is out") { forecasts.isHolding(second) }
        await manager.settleWidgetPublishing()
        return (poll, widget.all.count)
    }

    /// Lands the second trail's forecast, which the first's answered before,
    /// so the first's has been handled by the time this returns.
    private func landTheSecond() async {
        let answer = Self.reading(celsius: Celsius.secondAnswer)
        forecasts.answer(second, with: .success(answer))
        await settleDelegateHop(until: "the second trail's forecast is on the badge") {
            manager.state == .reading(answer, subject: second)
        }
        await manager.settleWidgetPublishing()
    }

    private func end(_ poll: Task<Void, Never>) async {
        poll.cancel()
        forecasts.release()
        await poll.value
    }

    @Test("a trail opened while another's forecast is out has the badge, and the late answer is kept for its own")
    func aLateSuccessIsKept() async {
        let (poll, writes) = await openTheSecondWhileTheFirstIsOut()
        #expect(forecasts.isHolding(first), "the first trail's forecast is still out")

        let firstAnswer = Self.reading(celsius: Celsius.firstAnswer)
        forecasts.answer(first, with: .success(firstAnswer))
        await landTheSecond()
        #expect(Array(widget.all.dropFirst(writes)) == [Celsius.secondAnswer], "the first's answer reached nothing")

        // Kept for the first trail, and fresh: going back shows it unasked.
        model.weatherFocus.focus(on: first)
        await settleDelegateHop(until: "the first trail's answer is on the badge") {
            manager.state == .reading(firstAnswer, subject: first)
        }
        #expect(forecasts.timesAsked(about: first) == 1)
        await end(poll)
    }

    @Test("a late failure for the trail the hiker left leaves the badge, and backs off for that trail")
    func aLateFailureBacksOff() async {
        let (poll, writes) = await openTheSecondWhileTheFirstIsOut()

        forecasts.answer(first, with: .failure(ForecastFailure()))
        await landTheSecond()
        #expect(Array(widget.all.dropFirst(writes)) == [Celsius.secondAnswer], "the first's failure cleared nothing")

        // The failure counts for the first trail: going back is no new ask.
        model.weatherFocus.focus(on: first)
        await settleDelegateHop(until: "the first trail reads as unavailable") {
            manager.state == .unavailable(first)
        }
        #expect(forecasts.timesAsked(about: first) == 1)
        await end(poll)
    }

    @Test("going back to a trail whose forecast is still out asks once, and its answer lands")
    func goingBackWhileOut() async {
        let (poll, _) = await openTheSecondWhileTheFirstIsOut()

        model.weatherFocus.focus(on: first)
        await settleDelegateHop(until: "the first trail is loading again") { manager.state == .loading(first) }
        let firstAnswer = Self.reading(celsius: Celsius.firstAnswer)
        forecasts.answer(first, with: .success(firstAnswer))

        await settleDelegateHop(until: "the first trail's answer is on the badge") {
            manager.state == .reading(firstAnswer, subject: first)
        }
        #expect(forecasts.timesAsked(about: first) == 1)
        await end(poll)
    }
}
