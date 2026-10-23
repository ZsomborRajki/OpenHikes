//
//  WeatherPlaceNameTests.swift
//  OpenHikesTests
//
//  That the detail sheet is headed with the place the forecast is for.
//
//  It used to be headed with the ``WeatherSubject``'s own name, which for a
//  selected route is the *hike's* title — the thing the hiker tapped rather
//  than the place being described. What is pinned here is the replacement and,
//  more importantly, the four ways it is allowed to *not* happen: two subjects
//  that keep the name they have, a launch with no geocoder, and an answer that
//  arrives after the hiker has moved on. The same answer carries the zone the
//  week's days are named in (#934), and is held to the same four — and to one
//  more, because a trail's reading moves with the hiker: an answer stands only
//  for the reading it was asked about.
//
//  The cost assertions matter as much as the name ones. A geocode is a network
//  round trip against somebody's rate limit, so `asked` is counted in every
//  case that should spend one and in every case that should not.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

/// Answers a fixed city and zone, and records how often it was asked.
@MainActor
private final class StubPlaceNames: WeatherPlaceNaming {
    var answer: String?
    var timeZone = TimeZone(identifier: "Europe/Berlin")
    private(set) var asked: [CLLocationCoordinate2D] = []
    /// Held open so a test can drive the subject changing mid-flight.
    var beforeReturning: (@Sendable () async -> Void)?

    init(answer: String? = "Berchtesgaden") {
        self.answer = answer
    }

    func place(at coordinate: CLLocationCoordinate2D) async -> WeatherPlaceDescription? {
        asked.append(coordinate)
        await beforeReturning?()
        return WeatherPlaceDescription(cityName: answer, timeZone: timeZone)
    }
}

@MainActor
@Suite("Weather place name")
struct WeatherPlaceNameTests {
    private let watzmann = CLLocationCoordinate2D(latitude: 47.5553, longitude: 12.9225)
    private let budapest = CLLocationCoordinate2D(latitude: 47.4979, longitude: 19.0402)
    /// Twin towns on the Arizona–Utah line, a mile apart and, in summer, an
    /// hour apart.
    private let coloradoCity = CLLocationCoordinate2D(latitude: 36.9908, longitude: -112.9757)
    private let hildale = CLLocationCoordinate2D(latitude: 37.0036, longitude: -112.9663)

    private func manager(_ names: StubPlaceNames?) -> WeatherManager {
        WeatherManager(placeNames: names, widgetPublisher: .inert)
    }

    /// A reading as a fetch leaves it in the cache. Only where it was fetched
    /// matters here, so the weather in it is anything.
    private func reading(capturedAt: Date) -> WeatherSnapshot {
        WeatherSnapshot(
            symbolName: "sun.max.fill",
            temperature: Measurement(value: 31, unit: UnitTemperature.celsius),
            conditionDescription: "Clear",
            capturedAt: capturedAt,
            conditions: .preview
        )
    }

    private func focused(
        _ manager: WeatherManager,
        on subject: WeatherSubject
    ) {
        manager.focus(on: subject, willRequest: false)
    }

    private func trail(named name: String = "Saturday loop") -> WeatherSubject {
        .trail(watzmann, hikeID: UUID(), name: name)
    }
}

// MARK: - The replacement

extension WeatherPlaceNameTests {
    /// The whole point: a hike's title is not a place, and the sheet says
    /// where the forecast is from instead.
    @Test("a trail's forecast is headed with the city it is for")
    func aTrailBorrowsItsCity() async {
        let names = StubPlaceNames()
        let manager = manager(names)
        focused(manager, on: trail())

        await manager.resolvePlace()

        #expect(manager.cityName == "Berchtesgaden")
        #expect(manager.forecastTimeZone?.identifier == "Europe/Berlin")
        #expect(names.asked.count == 1)
    }

    /// Reopening the sheet is free. The city is a property of the anchor, not
    /// of the weather, so nothing about it goes stale.
    @Test("reopening the sheet does not geocode again")
    func theCityIsCached() async {
        let names = StubPlaceNames()
        let manager = manager(names)
        let subject = trail()
        focused(manager, on: subject)

        await manager.resolvePlace()
        await manager.resolvePlace()

        #expect(manager.cityName == "Berchtesgaden")
        #expect(names.asked.count == 1, "the second open is answered from memory")
    }

    /// Going back to a trail gets its title back with its reading, which is
    /// the same bargain the snapshot cache strikes.
    @Test("returning to a trail keeps the city it already had")
    func returningIsFree() async {
        let names = StubPlaceNames()
        let manager = manager(names)
        let first = trail(named: "Saturday loop")
        focused(manager, on: first)
        await manager.resolvePlace()

        names.answer = "Salzburg"
        focused(manager, on: .place(budapest, name: "Budapest"))
        #expect(manager.cityName == nil, "a different subject is not the trail's city")
        #expect(manager.forecastTimeZone == nil, "nor its zone, before it is looked up")

        focused(manager, on: first)
        await manager.resolvePlace()

        #expect(manager.cityName == "Berchtesgaden")
        #expect(names.asked.count == 1)
    }

    /// A trail's key outlives its place. Once the hiker is out on it, its
    /// coordinate follows them — see ``WeatherFocus/hikerMoved(to:)`` — and a
    /// forecast fetched across a border is another town's, with days that
    /// begin at another zone's midnight. Arizona keeps no summer time and Utah
    /// does, so in July Utah's Saturday begins at 06:00Z, which in Arizona is
    /// still Friday: named in the old zone, every row is a weekday early.
    @Test("a trail followed across a zone border is asked about again")
    func aTrailFollowedAcrossABorder() async {
        let names = StubPlaceNames(answer: "Colorado City")
        names.timeZone = TimeZone(identifier: "America/Phoenix")
        let manager = manager(names)
        let arizona = WeatherSubject.trail(coloradoCity, hikeID: UUID(), name: "Canyon loop")
        let fetched = Date.now
        manager.applyUITestSnapshot(reading(capturedAt: fetched), subject: arizona)
        await manager.resolvePlace()

        // The badge follows the hiker at once, and the reading on it is still
        // the one fetched in Arizona — which is what the zone is about.
        let utah = arizona.moved(to: hildale)
        manager.focus(on: utah, willRequest: true)
        await manager.resolvePlace()
        #expect(manager.forecastTimeZone?.identifier == "America/Phoenix")
        #expect(names.asked.count == 1, "nothing the sheet draws has moved yet")

        names.answer = "Hildale"
        names.timeZone = TimeZone(identifier: "America/Denver")
        manager.applyUITestSnapshot(reading(capturedAt: fetched.addingTimeInterval(60)), subject: utah)
        #expect(manager.forecastTimeZone == nil, "Arizona's zone is not put on Utah's days")
        #expect(manager.cityName == nil, "nor its town over the forecast")

        await manager.resolvePlace()
        #expect(manager.forecastTimeZone?.identifier == "America/Denver")
        #expect(manager.cityName == "Hildale")
        #expect(names.asked.count == 2)
        #expect(names.asked.last?.latitude == hildale.latitude)
    }
}

// MARK: - When it must not happen

extension WeatherPlaceNameTests {
    /// A searched place is already a place the hiker named by searching for
    /// it. Replacing what they typed with its administrative parent would be
    /// answering a question nobody asked — so the round trip is spent on its
    /// zone alone, which the week's weekday names need (#934).
    @Test("a searched place keeps the name the hiker searched for, and borrows its zone")
    func aSearchedPlaceKeepsItsName() async {
        let names = StubPlaceNames(answer: "Budapest V. kerület")
        names.timeZone = TimeZone(identifier: "Europe/Budapest")
        let manager = manager(names)
        focused(manager, on: .place(budapest, name: "Budapest"))

        await manager.resolvePlace()

        #expect(manager.cityName == nil)
        #expect(manager.forecastTimeZone?.identifier == "Europe/Budapest")
        #expect(names.asked.count == 1)

        await manager.resolvePlace()
        #expect(names.asked.count == 1, "the zone is remembered as the city is")
    }

    /// `me` is *here*, which the sheet says by saying "Weather", and whose
    /// days begin at the reader's own midnight.
    @Test("the hiker's own forecast borrows no city and no zone")
    func hereIsNotACity() async {
        let names = StubPlaceNames()
        let manager = manager(names)
        focused(manager, on: .me(budapest))

        await manager.resolvePlace()

        #expect(manager.cityName == nil)
        #expect(manager.forecastTimeZone == nil)
        #expect(names.asked.isEmpty)
    }

    /// The UI-testing composition passes no geocoder, and the sheet is then
    /// headed exactly as it was before the feature existed.
    @Test("a launch with no geocoder heads the sheet as it used to")
    func anAbsentNamerIsInert() async {
        let manager = manager(nil)
        focused(manager, on: trail())

        await manager.resolvePlace()

        #expect(manager.cityName == nil)
    }

    /// A trail anchored on open hillside belongs to no settlement. MapKit
    /// answering `nil` is how the sheet knows to keep the hike's own name —
    /// and the hillside is still in a time zone.
    @Test("nowhere in particular keeps the hike's name")
    func noCityIsAnAnswer() async {
        let names = StubPlaceNames(answer: nil)
        let manager = manager(names)
        focused(manager, on: trail())

        await manager.resolvePlace()

        #expect(manager.cityName == nil)
        #expect(manager.forecastTimeZone?.identifier == "Europe/Berlin")
        #expect(names.asked.count == 1)
    }

    /// The race the key exists for. A geocode is a round trip, and the hiker
    /// can dismiss the sheet and select another trail while it is out — an
    /// answer landing then must not be published over the new one.
    @Test("a city arriving late is not put over a different trail")
    func aLateAnswerIsDiscarded() async {
        let names = StubPlaceNames()
        let manager = manager(names)
        let moved = trail(named: "Saturday loop")
        focused(manager, on: moved)
        names.beforeReturning = { @Sendable in
            await MainActor.run { manager.focus(on: .me(self.budapest), willRequest: false) }
        }

        await manager.resolvePlace()

        #expect(manager.cityName == nil, "the badge has moved on, so there is no city to draw")
        #expect(manager.forecastTimeZone == nil, "nor a zone to name its days in")
    }
}
