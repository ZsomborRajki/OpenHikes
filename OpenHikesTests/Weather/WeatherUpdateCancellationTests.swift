//
//  WeatherUpdateCancellationTests.swift
//  OpenHikesTests
//
//  What a request may still say once the loop that made it has gone.
//
//  The poll is a SwiftUI `.task`, and ``WeatherManager`` outlives it. So the
//  request a torn-down loop was waiting on can come back after the loop that
//  replaced it has moved the badge, and it comes back with the subject the
//  hiker has left. Held rather than simulated: the stub answers only when
//  told to, and cancellation does not end the wait, because a framework
//  request need not notice either.
//
//  The other half is what must not change. An ordinary failure keeps its
//  cached reading, and a request nobody cancelled still lands, so both are
//  held here to the same stub.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import Testing

/// A WeatherKit that answers when it is told to, and not before.
@MainActor
private final class HeldWeatherReadings: WeatherReadingFetching {
    private var held: CheckedContinuation<WeatherSnapshot, any Error>?

    var isHolding: Bool { held != nil }

    func reading(at coordinate: CLLocationCoordinate2D) async throws -> WeatherSnapshot {
        try await withCheckedThrowingContinuation { held = $0 }
    }

    func answer(_ result: Result<WeatherSnapshot, any Error>) {
        held?.resume(with: result)
        held = nil
    }
}

/// The App Group, in memory, as a list of what was written to it: a
/// temperature, or a `nil` for a clear.
nonisolated private final class WidgetWrites: @unchecked Sendable {
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

private struct UpdateFailure: Error {}

@MainActor
@Suite("Weather update cancellation")
struct WeatherUpdateCancellationTests {
    private let oldTrail = WeatherSubject.place(
        CLLocationCoordinate2D(latitude: 45.8326, longitude: 6.8652),
        name: "Chamonix"
    )
    private let newTrail = WeatherSubject.place(
        CLLocationCoordinate2D(latitude: 47.5553, longitude: 12.9225),
        name: "Watzmann"
    )
    private let answer = Self.reading(celsius: 21)
    private let cached = Self.reading(celsius: 4)

    private let held = HeldWeatherReadings()
    private let widget = WidgetWrites()
    private let store: WeatherReadingStore
    private let manager: WeatherManager

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "weather-update-\(UUID().uuidString)"))
        store = WeatherReadingStore(defaults: defaults)
        manager = WeatherManager(
            store: store,
            widgetPublisher: WeatherWidgetPublisher(reload: { /* no widget to redraw */ }, store: widget.seam),
            readings: held
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

    /// Focuses `subject` and starts its update, as one pass of the poll does,
    /// and returns once the request is waiting on the service.
    private func request(_ subject: WeatherSubject) async -> Task<Bool, Never> {
        manager.focus(on: subject, willRequest: true)
        let attempt = Task { await manager.update(for: subject) }
        await settleDelegateHop(until: "the request to reach the service") { held.isHolding }
        return attempt
    }

    /// Puts `cached` in the manager for `oldTrail`, and returns how many
    /// widget writes that took, for an assertion to count from.
    @discardableResult private func prime() async -> Int {
        manager.applyUITestSnapshot(cached, subject: oldTrail)
        await manager.settleWidgetPublishing()
        return widget.all.count
    }

    // MARK: - Cancelled

    @Test("a cancelled request's answer reaches nothing")
    func cancelledSuccessIsDropped() async {
        let attempt = await request(oldTrail)
        attempt.cancel()
        manager.focus(on: newTrail, willRequest: true)

        held.answer(.success(answer))

        #expect(await attempt.value == false)
        await manager.settleWidgetPublishing()
        #expect(manager.state == .loading(newTrail))
        #expect(store.load() == nil)
        #expect(widget.all.isEmpty)
        // Nor the cache: without a reading held for it, a subject that may
        // not request draws as unavailable.
        manager.focus(on: oldTrail, willRequest: false)
        #expect(manager.state == .unavailable(oldTrail))
    }

    /// Both spellings, because a framework need not surface a cancelled
    /// request as Swift's own error.
    @Test(
        "a cancelled request's error moves nothing",
        arguments: [CancellationError() as any Error, URLError(.cancelled)]
    )
    func cancelledFailureIsDropped(error: any Error) async {
        let attempt = await request(oldTrail)
        attempt.cancel()
        manager.focus(on: newTrail, willRequest: true)

        held.answer(.failure(error))

        #expect(await attempt.value == false)
        await manager.settleWidgetPublishing()
        #expect(manager.state == .loading(newTrail))
        #expect(widget.all.isEmpty)
    }

    @Test("a cancelled request does not put its cached reading back")
    func cancelledFailureKeepsTheCacheOffTheBadge() async {
        let writes = await prime()
        let attempt = await request(oldTrail)
        attempt.cancel()
        manager.focus(on: newTrail, willRequest: true)

        held.answer(.failure(CancellationError()))

        #expect(await attempt.value == false)
        await manager.settleWidgetPublishing()
        #expect(manager.state == .loading(newTrail))
        #expect(widget.all.count == writes)
    }

    /// With no newer focus the spinner stays, for the loop that replaces the
    /// cancelled one: its first pass asks again, and that answer lands.
    @Test("a cancelled request leaves the next one to answer")
    func cancelledRequestLeavesTheBadgeForTheNext() async {
        let cancelled = await request(oldTrail)
        cancelled.cancel()
        held.answer(.failure(CancellationError()))
        #expect(await cancelled.value == false)
        #expect(manager.state == .loading(oldTrail))

        let next = await request(oldTrail)
        held.answer(.success(answer))

        #expect(await next.value)
        #expect(manager.state == .reading(answer, subject: oldTrail))
    }

    // MARK: - Not cancelled

    @Test("a request nobody cancelled reaches the badge, the store and the widget")
    func successLands() async {
        let attempt = await request(oldTrail)

        held.answer(.success(answer))

        #expect(await attempt.value)
        await manager.settleWidgetPublishing()
        #expect(manager.state == .reading(answer, subject: oldTrail))
        #expect(store.load()?.snapshot == answer)
        #expect(widget.all == [21])
    }

    @Test("an ordinary failure falls back to the cached reading")
    func failureKeepsTheCachedReading() async {
        await prime()
        let attempt = await request(oldTrail)

        held.answer(.failure(UpdateFailure()))

        #expect(await attempt.value == false)
        #expect(manager.state == .reading(cached, subject: oldTrail))
    }

    /// Cancellation is the task's to say. An error of that type from a loop
    /// still running is a request that got no answer, and the loop is still
    /// there to back off and to need a badge that stops spinning.
    @Test(
        "an ordinary failure with nothing cached reads as unavailable",
        arguments: [UpdateFailure() as any Error, CancellationError()]
    )
    func failureWithNothingCachedIsUnavailable(error: any Error) async {
        let attempt = await request(oldTrail)

        held.answer(.failure(error))

        #expect(await attempt.value == false)
        await manager.settleWidgetPublishing()
        #expect(manager.state == .unavailable(oldTrail))
        #expect(widget.all == [nil])
    }
}
