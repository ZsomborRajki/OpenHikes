//
//  TrailPlaceCardTextTests.swift
//  OpenHikesTests
//
//  The words both place cards are made of: what an OpenStreetMap fact is
//  called and how its value reads, how a coordinate is written, and the link
//  a place is shared as.
//
//  Shared by the maker's sheet and a saved hike's place screen since the
//  place overhaul, which is what makes them worth pinning: one spelling on
//  two cards. Nothing here asserts a figure through `Locale.current` — CI's
//  simulator region is not a development machine's — so a formatted number
//  is compared against the formatter it is supposed to come from.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Place card text")
struct TrailPlaceCardTextTests {
    @Test("every fact has a label of its own")
    func everyFactIsLabelled() {
        let labels = TrailPlaceFact.Kind.allCases.map(\.label)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == labels.count)
    }

    @Test("yes and no read as words, and anything else as written")
    func yesAndNoAreWords() {
        #expect(TrailPlaceFact(kind: .drinkingWater, value: "yes").displayValue == String(localized: "Yes"))
        #expect(TrailPlaceFact(kind: .fee, value: "NO").displayValue == String(localized: "No"))
        #expect(TrailPlaceFact(kind: .fee, value: "donation").displayValue == "donation")
        #expect(TrailPlaceFact(kind: .operatorName, value: "DAV").displayValue == "DAV")
    }

    @Test("an elevation reads in the hiker's unit, and one that is not a number as written")
    func elevationIsFormatted() {
        let expected = HikeFormat.elevation(Measurement(value: 1638, unit: UnitLength.meters))
        #expect(TrailPlaceFact(kind: .elevation, value: "1638").displayValue == expected)
        #expect(TrailPlaceFact(kind: .elevation, value: "1638 m").displayValue == expected)
        #expect(TrailPlaceFact(kind: .elevation, value: "about 1600").displayValue == "about 1600")
    }

    @Test("a coordinate names its hemispheres")
    func coordinatesNameHemispheres() {
        let north = TrailPlaceCoordinates.text(CLLocationCoordinate2D(latitude: 47.5, longitude: 12.9))
        let south = TrailPlaceCoordinates.text(CLLocationCoordinate2D(latitude: -33.9, longitude: -70.6))
        #expect(north.contains(String(localized: "N")) && north.contains(String(localized: "E")))
        #expect(south.contains(String(localized: "S")) && south.contains(String(localized: "W")))
        #expect(!south.contains("-"), "the hemisphere says the sign")
    }

    @Test("a place is shared as an Apple Maps link to its spot, under its name")
    func shareLinkIsAppleMaps() throws {
        let url = TrailPlaceCoordinates.mapsURL(
            CLLocationCoordinate2D(latitude: 47.61, longitude: 12.98),
            named: "Kärlingerhaus"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "maps.apple.com")
        #expect(components.queryItems?.first { $0.name == "ll" }?.value == "47.61,12.98")
        #expect(components.queryItems?.first { $0.name == "q" }?.value == "Kärlingerhaus")
    }

    @Test("a saved place's card reads its glyph, colour and note off the place")
    func cardPassesThePlaceThrough() {
        let place = TrailPlace(latitude: 47.61, longitude: 12.98, symbol: .water, note: "Cold")
        let card = HikePlaceCard(row: TrailPlaceRow(place: place, anchor: nil))
        #expect(card.systemImage == TrailPlaceSymbol.water.systemImageName)
        #expect(card.tint == TrailPlaceSymbol.water.tint)
        #expect(card.coordinate.latitude == 47.61)
        #expect(card.note == "Cold")
        #expect(card.subtitle == nil, "an unnamed spring is titled by its kind, and a subtitle would repeat it")
    }
}
