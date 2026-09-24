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
//  arrives after the hiker has moved on.
//
//  The cost assertions matter as much as the name ones. A geocode is a network
//  round trip against somebody's rate limit, so `asked` is counted in every
//  case that should spend one and in every case that should not.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

/// Answers a fixed city, and records how often it was asked.
@MainActor
private final class StubPlaceNames: WeatherPlaceNaming {
    var answer: String?
    private(set) var asked: [CLLocationCoordinate2D] = []
    /// Held open so a test can drive the subject changing mid-flight.
    var beforeReturning: (@Sendable () async -> Void)?

    init(answer: String? = "Berchtesgaden") {
        self.answer = answer
    }

    func cityName(at coordinate: CLLocationCoordinate2D) async -> String? {
        asked.append(coordinate)
        await beforeReturning?()
        return answer
    }
}

@MainActor
@Suite("Weather place name")
struct WeatherPlaceNameTests {
    private let watzmann = CLLocationCoordinate2D(latitude: 47.5553, longitude: 12.9225)
    private let budapest = CLLocationCoordinate2D(latitude: 47.4979, longitude: 19.0402)

    private func manager(_ names: StubPlaceNames?) -> WeatherManager {
        WeatherManager(placeNames: names, widgetPublisher: .inert)
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

        await manager.resolveCityName()

        #expect(manager.cityName == "Berchtesgaden")
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

        await manager.resolveCityName()
        await manager.resolveCityName()

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
        await manager.resolveCityName()

        names.answer = "Salzburg"
        focused(manager, on: .place(budapest, name: "Budapest"))
        #expect(manager.cityName == nil, "a different subject is not the trail's city")

        focused(manager, on: first)
        await manager.resolveCityName()

        #expect(manager.cityName == "Berchtesgaden")
        #expect(names.asked.count == 1)
    }
}

// MARK: - When it must not happen

extension WeatherPlaceNameTests {
    /// A searched place is already a place the hiker named by searching for
    /// it. Replacing what they typed with its administrative parent would be
    /// answering a question nobody asked — and would spend a round trip doing
    /// it.
    @Test("a searched place keeps the name the hiker searched for")
    func aSearchedPlaceIsLeftAlone() async {
        let names = StubPlaceNames()
        let manager = manager(names)
        focused(manager, on: .place(budapest, name: "Budapest"))

        await manager.resolveCityName()

        #expect(manager.cityName == nil)
        #expect(names.asked.isEmpty, "nothing to look up, so nothing is spent")
    }

    /// `me` is *here*, which the sheet says by saying "Weather".
    @Test("the hiker's own forecast borrows no city")
    func hereIsNotACity() async {
        let names = StubPlaceNames()
        let manager = manager(names)
        focused(manager, on: .me(budapest))

        await manager.resolveCityName()

        #expect(manager.cityName == nil)
        #expect(names.asked.isEmpty)
    }

    /// The UI-testing composition passes no geocoder, and the sheet is then
    /// headed exactly as it was before the feature existed.
    @Test("a launch with no geocoder heads the sheet as it used to")
    func anAbsentNamerIsInert() async {
        let manager = manager(nil)
        focused(manager, on: trail())

        await manager.resolveCityName()

        #expect(manager.cityName == nil)
    }

    /// A trail anchored on open hillside belongs to no settlement. MapKit
    /// answering `nil` is how the sheet knows to keep the hike's own name.
    @Test("nowhere in particular keeps the hike's name")
    func noCityIsAnAnswer() async {
        let names = StubPlaceNames(answer: nil)
        let manager = manager(names)
        focused(manager, on: trail())

        await manager.resolveCityName()

        #expect(manager.cityName == nil)
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

        await manager.resolveCityName()

        #expect(manager.cityName == nil, "the badge has moved on, so there is no city to draw")
    }
}
