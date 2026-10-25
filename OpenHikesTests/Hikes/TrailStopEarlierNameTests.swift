//
//  TrailStopEarlierNameTests.swift
//  OpenHikesTests
//
//  What a tapped stop is called below iOS 26, where Core Location answers
//  instead of MapKit's own geocoder. The answers are Core Location's, field
//  for field, as they came back on 2026-10-25 for the pins
//  `TrailStopNameTests` records MapKit's answers for — and every one stood
//  exactly at its pin, which is why the rule reads what an answer is rather
//  than how far it stands.
//

import CoreLocation
@testable import OpenHikes
import Testing

@Suite("Trail stop names below iOS 26")
struct TrailStopEarlierNameTests {
    /// The forest above the Traunsee: a postcode, with no street and nothing
    /// of interest at it.
    @Test("a postcode with nothing at the spot is no name for it")
    func aPostcodeIsNoName() {
        let forest = TrailStopName.EarlierAnswer(
            name: "4810",
            thoroughfare: nil,
            areaOfInterest: nil,
            locality: "Gmunden"
        )
        #expect(TrailStopName.here(forest) == nil)
    }

    /// The top of the Traunstein: the summit is what stands there, and the
    /// line reads as the same answer above 26 does once its gap is closed.
    @Test("a summit is named by what stands there")
    func aSummitNamesItsTop() {
        let summit = TrailStopName.EarlierAnswer(
            name: "Traunstein",
            thoroughfare: nil,
            areaOfInterest: "Traunstein",
            locality: "Gmunden"
        )
        #expect(TrailStopName.here(summit) == "Traunstein, Gmunden")
    }

    @Test("a street address is named by its street and number")
    func aStreetNamesItself() {
        let street = TrailStopName.EarlierAnswer(
            name: "Korányi Sándor utca 3A.",
            thoroughfare: "Korányi Sándor utca",
            areaOfInterest: nil,
            locality: "Budapest"
        )
        #expect(TrailStopName.here(street) == "Korányi Sándor utca 3A., Budapest")
    }

    @Test("a place that is its own town is not named twice")
    func aTownIsSaidOnce() {
        let town = TrailStopName.EarlierAnswer(
            name: "Gmunden",
            thoroughfare: nil,
            areaOfInterest: "Gmunden",
            locality: "Gmunden"
        )
        #expect(TrailStopName.here(town) == "Gmunden")
    }

    @Test("a street with no name of its own is named by the street")
    func aBareStreetNamesTheStreet() {
        let street = TrailStopName.EarlierAnswer(
            name: nil,
            thoroughfare: "Seestraße",
            areaOfInterest: nil,
            locality: nil
        )
        #expect(TrailStopName.here(street) == "Seestraße")
    }
}
