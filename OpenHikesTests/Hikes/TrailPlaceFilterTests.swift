//
//  TrailPlaceFilterTests.swift
//  OpenHikesTests
//
//  The maker's switches under *Search this area*: what they remember, and what
//  turning one off does to a trail that already has pins of that kind.
//
//  What a switch does to the *request* is pinned in ``TrailPointQueryTests``
//  and what it does to an answer in ``TrailPointFinderTests``. This is the
//  choice itself and the drawing it is applied to.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@MainActor
@Suite("Trail place filter")
struct TrailPlaceFilterTests {
    private static func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "TrailPlaceFilterTests-\(UUID().uuidString)"))
    }

    private enum Line {
        static let longitude: Double = 12.86
        static let south: Double = 47.6300
        static let north: Double = 47.6340
    }

    private static func coordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: Line.longitude)
    }

    // MARK: - The choice

    /// The current list is the default: nobody has to turn anything on.
    @Test("every kind starts switched on")
    func everyKindStartsOn() throws {
        let filter = TrailPlaceFilter(defaults: try Self.defaults())

        #expect(filter.hidden.isEmpty)
        #expect(filter.shown == Set(TrailPointQuery.searchableSymbols))
    }

    /// App-wide: a hiker who turned shelters off once finds them off on the
    /// next trail and after the next launch.
    @Test("a switch turned off stays off for the next maker")
    func theChoiceIsKept() throws {
        let defaults = try Self.defaults()
        let first = TrailPlaceFilter(defaults: defaults)
        first.setShows(false, .shelter)
        first.setShows(false, .parking)
        first.setShows(true, .parking)

        let next = TrailPlaceFilter(defaults: defaults)

        #expect(next.hidden == [.shelter])
        #expect(!next.shows(.shelter))
        #expect(next.shows(.parking))
    }

    /// What is stored is what was turned off, so a name this build does not
    /// know — a symbol a later version added, then downgraded — reads as
    /// nothing rather than failing the whole list.
    @Test("a stored name this build does not know is ignored")
    func anUnknownStoredNameIsIgnored() throws {
        let defaults = try Self.defaults()
        defaults.set(["Shelter", "Glacier"], forKey: SettingsKey.trailPlaceHiddenSymbols)

        #expect(TrailPlaceFilter(defaults: defaults).hidden == [.shelter])
    }

    /// The switch beside the heading starts on and, like the kinds, stays
    /// where it was left for the next maker.
    @Test("the places switch starts on and is kept")
    func thePlacesSwitchIsKept() throws {
        let defaults = try Self.defaults()
        let first = TrailPlaceFilter(defaults: defaults)
        #expect(first.placesShown)

        first.setPlacesShown(false)

        #expect(!TrailPlaceFilter(defaults: defaults).placesShown)
    }

    /// A place that claims no symbol has no switch to be turned off by.
    @Test("a place with no symbol is always admitted")
    func aPlaceWithNoSymbolIsAdmitted() {
        let filter = TrailPlaceFilter(defaults: nil)
        filter.setShows(false, .water)

        #expect(filter.admits(TrailPlace(latitude: 47.6, longitude: 12.9)))
        #expect(!filter.admits(TrailPlace(latitude: 47.6, longitude: 12.9, symbol: .water)))
    }

    // MARK: - The drawing it is applied to

    /// **Turning a kind off takes its pins off the map**, and off the draft on
    /// disk with them — a hiker who comes back to the drawing tomorrow does
    /// not find the shelters they switched off.
    @Test("a switch turned off removes that kind's places from the trail")
    func switchingOffRemovesThePlaces() throws {
        let store = TrailDraftStore(context: try Fixture.modelContext())
        let maker = TrailDraftController(store: store)
        maker.setEditing(true)
        let hut = TrailPlace(coordinate: Self.coordinate(Line.north), name: "Hut", symbol: .shelter)
        let spring = TrailPlace(coordinate: Self.coordinate(Line.south), name: "Spring", symbol: .water)
        maker.draft.addPlaces([hut, spring])
        maker.appendWaypoint(at: Self.coordinate(Line.south))
        #expect(store.load().places.count == 2)

        maker.setShowsPlaces(false, of: .shelter)

        #expect(maker.draft.places.map(\.name) == ["Spring"])
        #expect(store.load().places.map(\.name) == ["Spring"])
        #expect(!maker.finder.filter.shows(.shelter))
    }

    /// On brings nothing back — they were removed, not hidden — and the next
    /// search is what adds them again.
    @Test("a switch turned back on brings nothing back by itself")
    func switchingBackOnRestoresNothing() {
        let maker = TrailDraftController()
        maker.setEditing(true)
        maker.draft.addPlaces([
            TrailPlace(coordinate: Self.coordinate(Line.north), name: "Hut", symbol: .shelter),
        ])

        maker.setShowsPlaces(false, of: .shelter)
        maker.setShowsPlaces(true, of: .shelter)

        #expect(maker.draft.places.isEmpty)
        #expect(maker.finder.filter.shows(.shelter))
    }

    /// The card about a place that has just gone closes with it, rather than
    /// staying up about a pin nobody can see.
    @Test("the place card about a removed place closes")
    func theCardAboutARemovedPlaceCloses() {
        let maker = TrailDraftController()
        maker.setEditing(true)
        let hut = TrailPlace(coordinate: Self.coordinate(Line.north), name: "Hut", symbol: .shelter)
        maker.draft.addPlaces([hut])
        maker.select(.place(hut.id))
        #expect(maker.selection == .place(hut.id))

        maker.setShowsPlaces(false, of: .shelter)

        #expect(maker.selection == nil)
    }

    // MARK: - The switch above the kinds

    /// **Off hides, it does not remove**: the places stay on the drawing and
    /// on disk, so on brings every one of them back — the opposite of a kind
    /// switched off.
    @Test("the places switch hides the trail's places without removing them")
    func thePlacesSwitchKeepsThePlaces() throws {
        let store = TrailDraftStore(context: try Fixture.modelContext())
        let maker = TrailDraftController(store: store)
        maker.setEditing(true)
        maker.draft.addPlaces([
            TrailPlace(coordinate: Self.coordinate(Line.north), name: "Hut", symbol: .shelter),
        ])
        maker.appendWaypoint(at: Self.coordinate(Line.south))

        maker.setPlacesShown(false)

        #expect(maker.draft.places.map(\.name) == ["Hut"])
        #expect(store.load().places.map(\.name) == ["Hut"])
        #expect(maker.finder.filter.shows(.shelter), "the kinds are left as they were")
    }

    /// The card about a place closes with its pin, and no card can be opened
    /// on one while they are hidden.
    @Test("the places switch closes a place card and opens none")
    func thePlacesSwitchClosesTheCard() {
        let maker = TrailDraftController()
        maker.setEditing(true)
        let hut = TrailPlace(coordinate: Self.coordinate(Line.north), name: "Hut", symbol: .shelter)
        maker.draft.addPlaces([hut])
        maker.select(.place(hut.id))

        maker.setPlacesShown(false)
        #expect(maker.selection == nil)

        maker.select(.place(hut.id))
        #expect(maker.selection == nil)

        maker.setPlacesShown(true)
        maker.select(.place(hut.id))
        #expect(maker.selection == .place(hut.id))
    }
}
