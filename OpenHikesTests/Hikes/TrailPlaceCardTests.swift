//
//  TrailPlaceCardTests.swift
//  OpenHikesTests
//
//  What the maker's place card writes, apart from the card: a coordinate the
//  way Apple Maps spells it, the link a shared place opens, and OpenStreetMap's
//  facts in the hiker's words.
//
//  The coordinate's digits are formatted in the reader's locale, and this
//  machine and CI do not share one, so the text is checked by its hemispheres
//  and its shape rather than by a spelled-out number.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import Testing

@Suite("Trail place card")
struct TrailPlaceCardTests {
    private static let bartholomae = CLLocationCoordinate2D(latitude: 47.55412, longitude: 12.9731)

    @Test("A coordinate is written with its hemispheres, never a minus sign", arguments: [
        (CLLocationCoordinate2D(latitude: 47.5, longitude: 12.9), String(localized: "N"), String(localized: "E")),
        (CLLocationCoordinate2D(latitude: -33.9, longitude: 18.4), String(localized: "S"), String(localized: "E")),
        (CLLocationCoordinate2D(latitude: 40.7, longitude: -74.0), String(localized: "N"), String(localized: "W")),
        (CLLocationCoordinate2D(latitude: -22.9, longitude: -43.2), String(localized: "S"), String(localized: "W")),
    ])
    func coordinateHemispheres(_ coordinate: CLLocationCoordinate2D, north: String, east: String) {
        let text = TrailPlaceCoordinates.text(coordinate)
        #expect(!text.contains("-"))
        #expect(text.contains("° \(north),"))
        #expect(text.hasSuffix("° \(east)"))
    }

    @Test("A shared place links to Apple Maps at the spot, under its name")
    func mapsLink() throws {
        let url = TrailPlaceCoordinates.mapsURL(Self.bartholomae, named: "St. Bartholomä")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.scheme == "https")
        #expect(components.host == "maps.apple.com")
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
        )
        #expect(items["ll"] == "47.55412,12.9731")
        #expect(items["q"] == "St. Bartholomä")
    }

    @Test("An OpenStreetMap elevation is shown in the reader's unit")
    func elevationInTheReadersUnit() {
        let fact = TrailPlaceFact(kind: .elevation, value: "1250 m")
        let expected = HikeFormat.elevation(Measurement(value: 1250, unit: UnitLength.meters))

        #expect(fact.displayValue == expected)
        #expect(TrailPlaceFact(kind: .elevation, value: "1250").displayValue == expected)
    }

    @Test("An elevation that is not a number is shown as written")
    func unreadableElevation() {
        #expect(TrailPlaceFact(kind: .elevation, value: "about 1200").displayValue == "about 1200")
    }

    @Test("OpenStreetMap's yes and no are words, whatever their case", arguments: [
        TrailPlaceFact.Kind.drinkingWater, .fee,
    ])
    func yesAndNo(_ kind: TrailPlaceFact.Kind) {
        #expect(TrailPlaceFact(kind: kind, value: "YES").displayValue == String(localized: "Yes"))
        #expect(TrailPlaceFact(kind: kind, value: "no").displayValue == String(localized: "No"))
        #expect(TrailPlaceFact(kind: kind, value: "customers").displayValue == "customers")
    }

    @Test("Any other fact is shown exactly as it was tagged")
    func otherFactsAsWritten() {
        #expect(TrailPlaceFact(kind: .openingHours, value: "Mo-Su 09:00-17:00").displayValue == "Mo-Su 09:00-17:00")
        #expect(TrailPlaceFact(kind: .access, value: "yes").displayValue == "yes")
    }

    @Test("Every fact the card can show has a label of its own")
    func labelsAreDistinct() {
        let labels = TrailPlaceFact.Kind.allCases.map(\.label)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == labels.count)
    }
}
