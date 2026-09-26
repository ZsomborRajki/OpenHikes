//
//  WeatherWidgetPublisherTests.swift
//  OpenHikesTests
//
//  The badge's reading on its way to the home screen. Two decisions live here
//  and they are separate on purpose: what gets written, and what is worth a
//  redraw. WidgetKit gives an app a finite number of reloads a day and quietly
//  throttles one that overruns, so a feed that redraws on every successful
//  fetch is the trail feed's eighty-an-hour mistake in a second place — and at
//  whole degrees most fetches produce the string that is already on screen.
//
//  Both halves are injected. The reload sink for the reason `TrailWidgetReload`
//  injects one — `WidgetCenter` neither reports a reload nor replays it — and
//  the store because the bundle runs in one process against the real App Group
//  container, so a suite asserting on that file is a suite every other suite's
//  `WeatherManager` can walk into. See `WeatherWidgetPublisher.Store`.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesShared
import RealModule
import Testing

@Suite("Weather widget publishing")
struct WeatherWidgetPublisherTests {
    private static let now = Date(timeIntervalSince1970: 1_750_000_000)
    private static let locale = Locale(identifier: "de_DE")

    /// The App Group, in memory. Nothing here needs the container — what is
    /// being asserted is which of the two writes happened and whether a redraw
    /// followed, and a real file would only add a shared resource to a suite
    /// that could then not run beside anything.
    nonisolated private final class MemoryStore: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: SharedWeatherReading?
        private var written: [Double?] = []

        var reading: SharedWeatherReading? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        /// Every write in the order it arrived — a `nil` for a clear. What the
        /// burst test asks: the App Group cannot be left holding an older
        /// reading than the badge is showing.
        var writes: [Double?] {
            lock.lock()
            defer { lock.unlock() }
            return written
        }

        func seed(_ reading: SharedWeatherReading?) {
            lock.lock()
            defer { lock.unlock() }
            stored = reading
        }

        private func record(_ reading: SharedWeatherReading?) {
            seed(reading)
            lock.lock()
            defer { lock.unlock() }
            written.append(reading?.temperatureCelsius)
        }

        var seam: WeatherWidgetPublisher.Store {
            WeatherWidgetPublisher.Store(
                load: { self.reading },
                save: { self.record($0) },
                clear: { self.record(nil) }
            )
        }
    }

    /// Counts granted redraws. Locked rather than left bare because the sink
    /// is @Sendable and `publish` is `@concurrent`, so the increment happens
    /// off this test's thread.
    nonisolated private final class Reloads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private static func reading(
        celsius: Double,
        ageSeconds: TimeInterval = 0
    ) -> SharedWeatherReading? {
        SharedWeatherReading(
            temperatureCelsius: celsius,
            capturedAt: now.addingTimeInterval(-ageSeconds)
        )
    }

    private static let budapest = CLLocationCoordinate2D(latitude: 47.4979, longitude: 19.0402)
    private static let vienna = CLLocationCoordinate2D(latitude: 48.2082, longitude: 16.3738)

    /// A badge reading, for the tests that drive a whole `WeatherManager`
    /// rather than the publisher under it.
    ///
    /// Captured *now* rather than at ``now``, which is a fixed instant years
    /// behind this run: a manager publishes through the real clock, and a
    /// reading older than ``SharedWeatherReading/maximumAge`` draws nothing —
    /// so a fixture stamped in the past would be indistinguishable from no
    /// reading at all by the time the publisher asked.
    private static func snapshot(celsius: Double, capturedAt: Date = .now) -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "cloud.sun.fill",
            temperature: Measurement(value: celsius, unit: UnitTemperature.celsius),
            conditionDescription: "Partly Cloudy",
            capturedAt: capturedAt,
            conditions: .preview
        )
    }

    // MARK: What reaches the App Group

    @Test("a reading is written whether or not it redraws")
    func readingIsAlwaysWritten() async throws {
        let reloads = Reloads()
        let store = MemoryStore()
        let publisher = WeatherWidgetPublisher(reload: reloads.record, store: store.seam)
        let first = try #require(Self.reading(celsius: 12))

        await publisher.publish(first, asOf: Self.now, locale: Self.locale)
        // A tenth of a degree: a different reading, the same drawn string.
        let nudged = try #require(Self.reading(celsius: 12.1))
        let redrew = await publisher.publish(nudged, asOf: Self.now, locale: Self.locale)

        #expect(redrew == false, "the corner would read the same")
        #expect(store.reading?.temperatureCelsius == 12.1)
        #expect(reloads.value == 1, "only the first, which put a number where there was none")
    }

    @Test("a degree that changes the drawn number redraws")
    func changedDegreeRedraws() async throws {
        let reloads = Reloads()
        let store = MemoryStore()
        let publisher = WeatherWidgetPublisher(reload: reloads.record, store: store.seam)

        let first = try #require(Self.reading(celsius: 12))
        let warmer = try #require(Self.reading(celsius: 15))

        await publisher.publish(first, asOf: Self.now, locale: Self.locale)
        let redrew = await publisher.publish(warmer, asOf: Self.now, locale: Self.locale)

        #expect(redrew)
        #expect(reloads.value == 2)
    }

    /// A subject the app cannot get a forecast for leaves no number behind —
    /// see `WeatherBadgeState.sharedReading` for why the last valley's
    /// temperature must not linger over a new trail.
    @Test("a nil clears the stored reading and redraws")
    func nilClearsAndRedraws() async throws {
        let reloads = Reloads()
        let store = MemoryStore()
        let publisher = WeatherWidgetPublisher(reload: reloads.record, store: store.seam)

        let reading = try #require(Self.reading(celsius: 12))

        await publisher.publish(reading, asOf: Self.now, locale: Self.locale)
        let redrew = await publisher.publish(nil, asOf: Self.now, locale: Self.locale)

        #expect(redrew)
        #expect(store.reading == nil)
    }

    @Test("clearing nothing asks for nothing")
    func clearingNothingIsFree() async {
        let reloads = Reloads()
        let store = MemoryStore()
        let publisher = WeatherWidgetPublisher(reload: reloads.record, store: store.seam)

        let redrew = await publisher.publish(nil, asOf: Self.now, locale: Self.locale)

        #expect(redrew == false)
        #expect(reloads.value == 0)
    }

    /// The case the age check exists for: the widget is already drawing an
    /// empty corner because the stored reading expired, and a fresh one that
    /// happens to agree with it has to put the number back. Comparing the
    /// readings alone would call this "no change" and leave the corner blank
    /// until the six-hourly safety net came round.
    @Test("a fresh reading replacing an expired one redraws even at the same degree")
    func freshReadingAfterExpiryRedraws() async throws {
        let reloads = Reloads()
        let store = MemoryStore()
        let publisher = WeatherWidgetPublisher(reload: reloads.record, store: store.seam)
        let stale = try #require(
            Self.reading(celsius: 12, ageSeconds: SharedWeatherReading.maximumAge + 60)
        )
        let fresh = try #require(Self.reading(celsius: 12))
        store.seed(stale)

        let redrew = await publisher.publish(fresh, asOf: Self.now, locale: Self.locale)

        #expect(redrew)
        #expect(reloads.value == 1)
    }

    // MARK: What the badge hands over

    @Test("only a state with a reading hands one over")
    func onlyAReadingIsHandedOver() {
        let subject = WeatherSubject.me(.init(latitude: 47.5, longitude: 12.9))

        #expect(WeatherBadgeState.idle.sharedReading == nil)
        #expect(WeatherBadgeState.loading(subject).sharedReading == nil)
        #expect(WeatherBadgeState.unavailable(subject).sharedReading == nil)
    }

    /// WeatherKit hands this app Celsius, but nothing says it always will —
    /// the conversion is what makes the wire format a fact rather than a hope.
    @Test("the reading is converted to Celsius on the way out")
    func readingIsConvertedToCelsius() throws {
        let subject = WeatherSubject.me(.init(latitude: 47.5, longitude: 12.9))
        let snapshot = WeatherSnapshot(
            symbolName: "sun.max",
            temperature: Measurement(value: 68, unit: UnitTemperature.fahrenheit),
            conditionDescription: "Clear",
            capturedAt: Self.now,
            conditions: .preview
        )

        let reading = try #require(
            WeatherBadgeState.reading(snapshot, subject: subject).sharedReading
        )

        #expect(reading.temperatureCelsius.isApproximatelyEqual(to: 20, absoluteTolerance: 0.001))
        #expect(reading.capturedAt == Self.now, "the provider's clock, not this one")
    }

    /// The write is what the next timeline reads, so a write that did not
    /// happen is not a changed widget. Both App Group writers swallow their
    /// failures — an unresolvable container, a device still locked under data
    /// protection — and asking the store afterwards is what keeps that case
    /// from spending a reload on every badge move for a picture that cannot
    /// change.
    @Test("a write that does not land asks for no redraw")
    func failedWriteAsksForNothing() async throws {
        let reloads = Reloads()
        let refusing = WeatherWidgetPublisher.Store(
            load: { nil },
            save: { _ in /* the container could not be resolved */ },
            clear: { /* nor here */ }
        )
        let publisher = WeatherWidgetPublisher(reload: reloads.record, store: refusing)

        let reading = try #require(Self.reading(celsius: 12))
        let redrew = await publisher.publish(reading, asOf: Self.now, locale: Self.locale)

        #expect(redrew == false)
        #expect(reloads.value == 0)
    }

    // MARK: What the badge hands over, and when

    @Test("a fetch in flight is not news the widget can use")
    func loadingIsNotPublished() {
        let subject = WeatherSubject.me(.init(latitude: 47.5, longitude: 12.9))

        #expect(WeatherBadgeState.loading(subject).publishesToWidget == false)
        #expect(WeatherBadgeState.idle.publishesToWidget)
        #expect(WeatherBadgeState.unavailable(subject).publishesToWidget)
        #expect(
            WeatherBadgeState
                .reading(Self.snapshot(celsius: 12, capturedAt: Self.now), subject: subject)
                .publishesToWidget
        )
    }

    /// Tapping a trail the app has no cached forecast for is the commonest
    /// thing a hiker does, and it moves the badge twice: to `loading`, then to
    /// the answer. Publishing the first of those would blank the widget's
    /// corner and spend a reload doing it, then fill it and spend another.
    @MainActor
    @Test("a fetch in flight leaves the corner as it was")
    func loadingLeavesTheCornerAlone() async {
        let store = MemoryStore()
        let reloads = Reloads()
        let manager = WeatherManager(
            widgetPublisher: WeatherWidgetPublisher(reload: reloads.record, store: store.seam)
        )

        manager.applyUITestSnapshot(
            Self.snapshot(celsius: 12),
            subject: .place(Self.budapest, name: "Budapest")
        )
        await manager.settleWidgetPublishing()
        manager.focus(on: .place(Self.vienna, name: "Vienna"), willRequest: true)
        await manager.settleWidgetPublishing()

        #expect(manager.state == .loading(.place(Self.vienna, name: "Vienna")))
        #expect(store.reading?.temperatureCelsius == 12, "the last number stands until the next")
        #expect(reloads.value == 1, "and the fetch costs nothing")
    }

    /// Every publish reads the App Group file and rewrites it, and the badge
    /// moves in bursts — a focus, the fetch that answers it, sometimes a
    /// second subject on top. Unstructured tasks would land in whatever order
    /// the executor gave them, which leaves the widget holding an older
    /// reading than the badge is showing for up to
    /// `SharedWeatherReading.maximumAge`.
    @MainActor
    @Test("a burst of badge moves reaches the widget in the order it happened")
    func burstArrivesInOrder() async {
        let store = MemoryStore()
        let manager = WeatherManager(
            widgetPublisher: WeatherWidgetPublisher(
                reload: { /* the order of the writes is the whole question here */ },
                store: store.seam
            )
        )
        let degrees: [Double] = [4, 9, 14, 19, 24, 29]

        for celsius in degrees {
            manager.applyUITestSnapshot(
                Self.snapshot(celsius: celsius),
                subject: .place(Self.budapest, name: "Budapest")
            )
        }
        await manager.settleWidgetPublishing()

        #expect(store.writes == degrees.map { Optional($0) })
        #expect(store.reading?.temperatureCelsius == 29)
    }
}
