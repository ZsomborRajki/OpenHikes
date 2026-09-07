//
//  WeatherBadgeStateTests.swift
//  OpenHikesTests
//
//  That a badge with something to say always says it.
//
//  The complaint these come from is "I rarely see the weather badge", and the
//  cause was that ``WeatherManager`` published `WeatherSnapshot?` set only on
//  success: a missing entitlement, a token failure, a rate limit, a walker out
//  of signal and a launch that had not asked yet were one value — `nil` — and
//  the overlay drew nothing for all five. There was no way, from outside the
//  process, to tell a broken forecast from a feature that did not exist.
//
//  So the assertion running through all of these is the same one: once there
//  is a subject, there is a badge. What kind of badge is the second question.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Weather badge state")
struct WeatherBadgeStateTests {
    private let budapest = CLLocationCoordinate2D(latitude: 47.4979, longitude: 19.0402)
    private let vienna = CLLocationCoordinate2D(latitude: 48.2082, longitude: 16.3738)

    private func snapshot(
        celsius: Double,
        capturedAt: Date = .now
    ) -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "cloud.sun.fill",
            temperature: Measurement(value: celsius, unit: UnitTemperature.celsius),
            conditionDescription: "Partly Cloudy",
            capturedAt: capturedAt
        )
    }

    @Test("a manager with nothing to show is idle, and only then")
    func startsIdle() {
        #expect(WeatherManager().state == .idle)
    }

    /// The spinner case. A subject with a request on its way is a badge, not
    /// an absence.
    @Test("focusing a subject with a request coming shows it loading")
    func focusWithRequestLoads() {
        let manager = WeatherManager()
        manager.focus(on: .place(budapest, name: "Budapest"), willRequest: true)
        #expect(manager.state == .loading(.place(budapest, name: "Budapest")))
    }

    /// The case that used to be invisible: the poll has decided it may not ask
    /// — a backoff is outstanding — and there is nothing cached. Before, that
    /// was `nil` and drew nothing.
    @Test("a subject the poll cannot ask about reads as unavailable")
    func focusWithoutRequestIsUnavailable() {
        let manager = WeatherManager()
        manager.focus(on: .place(budapest, name: "Budapest"), willRequest: false)
        #expect(manager.state == .unavailable(.place(budapest, name: "Budapest")))
        #expect(manager.current == nil, "and there is genuinely no reading to show")
    }

    /// Going back to a subject looked at moments ago shows its reading at
    /// once rather than spinning. This is the half of the cache that faces the
    /// user; the other half is that ``WeatherRequestState`` will decline to
    /// re-request it, and without this the two would disagree and the badge
    /// would sit empty on a subject the poll thought was fresh.
    @Test("returning to a cached subject shows its reading immediately")
    func cachedSubjectIsShownAtOnce() {
        let manager = WeatherManager()
        let reading = snapshot(celsius: 12)
        manager.applyUITestSnapshot(reading, subject: .place(budapest, name: "Budapest"))

        manager.focus(on: .place(vienna, name: "Vienna"), willRequest: true)
        #expect(manager.state == .loading(.place(vienna, name: "Vienna")))

        manager.focus(on: .place(budapest, name: "Budapest"), willRequest: false)
        #expect(manager.state == .reading(reading, subject: .place(budapest, name: "Budapest")))
    }

    /// The walker is one subject however far they walk, so a `me` reading
    /// survives a move — the badge should not blank between a step and the
    /// response to it.
    @Test("a reading for the walker survives them moving")
    func walkerReadingSurvivesMovement() {
        let manager = WeatherManager()
        let reading = snapshot(celsius: 8)
        manager.applyUITestSnapshot(reading, subject: .me(budapest))

        manager.focus(on: .me(vienna), willRequest: true)

        #expect(manager.state == .reading(reading, subject: .me(vienna)))
    }

    @Test("only a reading answers `current`")
    func currentFollowsTheReading() {
        let manager = WeatherManager()
        #expect(manager.current == nil)

        let reading = snapshot(celsius: 3)
        manager.applyUITestSnapshot(reading, subject: .me(budapest))
        #expect(manager.current == reading)

        manager.focus(on: .place(vienna, name: "Vienna"), willRequest: true)
        #expect(manager.current == nil, "a subject being loaded has no reading yet")
    }
}

/// The other half of "I rarely see the badge": a cold launch used to draw
/// nothing until a location arrived *and* a network round trip returned.
@MainActor
@Suite("Weather reading store")
struct WeatherReadingStoreTests {
    private let budapest = CLLocationCoordinate2D(latitude: 47.4979, longitude: 19.0402)
    private let capturedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "weather-store-\(UUID().uuidString)"))
    }

    private func snapshot(celsius: Double) -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "cloud.rain.fill",
            temperature: Measurement(value: celsius, unit: UnitTemperature.celsius),
            conditionDescription: "Rain",
            capturedAt: capturedAt
        )
    }

    @Test("nothing stored restores nothing")
    func emptyStoreRestoresNothing() throws {
        #expect(WeatherReadingStore(defaults: try makeDefaults()).load() == nil)
    }

    @Test("a saved reading comes back whole")
    func roundTripsAReading() throws {
        let defaults = try makeDefaults()
        let store = WeatherReadingStore(defaults: defaults)
        let saved = snapshot(celsius: 4)
        store.save(snapshot: saved, subject: .place(budapest, name: "Budapest"))

        let restored = try #require(WeatherReadingStore(defaults: defaults).load())
        #expect(restored.snapshot == saved)
        #expect(restored.subject == .place(budapest, name: "Budapest"))
    }

    /// The age is what makes a restored reading honest — it is drawn dimmed by
    /// the same rule a live one is — so the capture time has to survive the
    /// round trip exactly. Stamping it on load would present last night's
    /// weather as current.
    @Test("a restored reading keeps its original age")
    func keepsCaptureTime() throws {
        let defaults = try makeDefaults()
        WeatherReadingStore(defaults: defaults).save(
            snapshot: snapshot(celsius: 4),
            subject: .me(budapest)
        )

        let restored = try #require(WeatherReadingStore(defaults: defaults).load())
        #expect(restored.snapshot.capturedAt == capturedAt)
        #expect(restored.snapshot.isStale(asOf: .now), "a reading this old is not current")
    }

    /// A reading about the walker comes back as one, not as a place with no
    /// name — the badge draws its "here" form off exactly this.
    @Test("a reading about the walker restores without a place name")
    func restoresTheWalkerWithoutAName() throws {
        let defaults = try makeDefaults()
        WeatherReadingStore(defaults: defaults).save(
            snapshot: snapshot(celsius: 4),
            subject: .me(budapest)
        )

        let restored = try #require(WeatherReadingStore(defaults: defaults).load())
        #expect(restored.subject.placeName == nil)
    }

    /// A manager built on a store that has something restores straight into a
    /// reading, which is the whole point: the badge is on screen before the
    /// first network call rather than half a minute after it.
    @Test("a manager restores its badge from the store at launch")
    func managerRestoresAtLaunch() throws {
        let defaults = try makeDefaults()
        let saved = snapshot(celsius: 4)
        WeatherReadingStore(defaults: defaults).save(
            snapshot: saved,
            subject: .place(budapest, name: "Budapest")
        )

        let manager = WeatherManager(store: WeatherReadingStore(defaults: defaults))
        #expect(manager.state == .reading(saved, subject: .place(budapest, name: "Budapest")))
    }
}
