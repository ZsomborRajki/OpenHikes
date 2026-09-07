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

    @Test("same-named places have independent readings and request histories")
    func sameNameDifferentLocations() {
        let france = WeatherSubject.place(.init(latitude: 48.8566, longitude: 2.3522), name: "Paris")
        let texas = WeatherSubject.place(.init(latitude: 33.6609, longitude: -95.5555), name: "Paris")
        let manager = WeatherManager()
        var requests = WeatherRequestState()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let reading = snapshot(celsius: 12, capturedAt: now)
        manager.applyUITestSnapshot(reading, subject: france)
        requests.recordSuccess(key: france.key, at: now)

        #expect(france.key != texas.key)
        let willRequest = requests.shouldRequest(key: texas.key, reason: .focus, at: now.addingTimeInterval(1))
        #expect(willRequest)
        manager.focus(on: texas, willRequest: willRequest)
        #expect(manager.state == .loading(texas))

        manager.focus(on: france, willRequest: false)
        #expect(manager.state == .reading(reading, subject: france))
    }

    @Test("revisiting a fresh reading keeps it through cache eviction")
    func cacheRecencyMatchesRequestRecency() {
        let manager = WeatherManager()
        var requests = WeatherRequestState()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let reading = snapshot(celsius: 12, capturedAt: now)
        let subjects = (0...WeatherRequestState.trackedSubjectLimit).map { index in
            WeatherSubject.place(budapest, name: "Place \(index)")
        }
        for subject in subjects.dropLast() {
            manager.applyUITestSnapshot(reading, subject: subject)
            requests.recordSuccess(key: subject.key, at: now)
        }

        let revisited = subjects[0]
        let firstRequest = requests.shouldRequest(key: revisited.key, reason: .focus, at: now)
        #expect(!firstRequest)
        manager.focus(on: revisited, willRequest: firstRequest)
        let newcomer = subjects[WeatherRequestState.trackedSubjectLimit]
        manager.applyUITestSnapshot(reading, subject: newcomer)
        requests.recordSuccess(key: newcomer.key, at: now)

        let secondRequest = requests.shouldRequest(key: revisited.key, reason: .focus, at: now)
        #expect(!secondRequest)
        manager.focus(on: revisited, willRequest: secondRequest)
        #expect(manager.state == .reading(reading, subject: revisited))
        manager.focus(on: subjects[1], willRequest: true)
        #expect(manager.state == .loading(subjects[1]), "the least recently used reading was evicted")
    }

    @Test("waiting for a recording's first fix clears the previous place's badge")
    func noSubjectClearsPreviousReading() {
        let manager = WeatherManager()
        manager.applyUITestSnapshot(snapshot(celsius: 12), subject: .place(budapest, name: "Budapest"))
        manager.focus(on: nil, willRequest: false)
        #expect(manager.state == .idle)
    }
}
