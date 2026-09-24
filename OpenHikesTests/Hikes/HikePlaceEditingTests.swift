//
//  HikePlaceEditingTests.swift
//  OpenHikesTests
//
//  What a saved hike lets a hiker do to its places, and what it keeps of
//  them.
//
//  The rule these defend is the user's, stated when the place overhaul was
//  asked for: a place from OpenStreetMap takes photographs and nothing else,
//  while a place the hiker made can also be renamed, re-kinded and annotated.
//  And a saved place now keeps what OpenStreetMap said about it, which the
//  maker used to throw away on save.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Hike place editing")
struct HikePlaceEditingTests {
    private enum Line {
        static let longitude = 12.98
        static let south = 47.60
        static let north = 47.62
        static let route = [
            RouteCoordinate(latitude: south, longitude: longitude),
            RouteCoordinate(latitude: north, longitude: longitude),
        ]
    }

    private static func hut(_ id: Int64 = 42, latitude: Double = 47.61) -> TrailPlace {
        TrailPlace(
            latitude: latitude,
            longitude: Line.longitude,
            name: "Kärlingerhaus",
            symbol: .shelter,
            osm: TrailPlaceOSM(
                elementType: "way",
                elementID: id,
                facts: [TrailPlaceFact(kind: .elevation, value: "1638")]
            )
        )
    }

    private static func own(latitude: Double = 47.605, name: String = "Bivouac rock") -> TrailPlace {
        TrailPlace(latitude: latitude, longitude: Line.longitude, name: name, symbol: .camp, note: "Dry")
    }

    private func hike() throws -> (Hike, ModelContext) {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Line.route)
        return (hike, context)
    }

    // MARK: What a saved place keeps

    @Test("a saved place keeps its OpenStreetMap element and facts")
    func keepsOpenStreetMap() throws {
        let (hike, context) = try hike()
        hike.replacePlaces(with: [Self.hut()], in: context)

        let saved = try #require(hike.places.first)
        #expect(saved.osm?.elementType == "way")
        #expect(saved.osm?.elementID == 42)
        #expect(saved.osm?.facts == [TrailPlaceFact(kind: .elevation, value: "1638")])
        #expect(saved.isHikersOwn == false)
    }

    @Test("a hiker's own place reads back with no element")
    func ownPlaceHasNoElement() throws {
        let (hike, context) = try hike()
        hike.replacePlaces(with: [Self.own()], in: context)

        #expect(hike.places.first?.osm == nil)
        #expect(hike.places.first?.isHikersOwn == true)
    }

    @Test("a stored element type Overpass never answers with reads as no element")
    func unknownElementTypeIsNoElement() throws {
        let (hike, context) = try hike()
        hike.replacePlaces(with: [Self.hut()], in: context)
        let row = try #require(hike.trailPoints?.first)
        row.osmElementType = "area"

        #expect(hike.places.first?.osm == nil)
    }

    // MARK: Adding

    @Test("adding leaves out the same element and anything at a place already held")
    func addingSkipsWhatIsHeld() throws {
        let (hike, context) = try hike()
        hike.replacePlaces(with: [Self.hut()], in: context)

        let added = hike.addPlaces(
            [
                Self.hut(),
                // Ten metres from the hut, and a different element: the same
                // place by the rule the maker's search uses.
                Self.hut(7, latitude: 47.61009),
                Self.own(),
                // One answer naming one element twice.
                Self.hut(8, latitude: 47.615),
                Self.hut(8, latitude: 47.615),
            ],
            in: context
        )

        #expect(added.count == 2)
        #expect(hike.places.count == 3)
    }

    @Test("two found places a few metres apart both go in, as the list offered them")
    func addingKeepsFoundNeighbours() throws {
        let (hike, context) = try hike()
        let spring = TrailPlace(
            latitude: 47.61005,
            longitude: Line.longitude,
            symbol: .water,
            osm: TrailPlaceOSM(elementType: "node", elementID: 9)
        )

        let added = hike.addPlaces([Self.hut(), spring], in: context)

        #expect(added.count == 2)
        #expect(hike.places.count == 2)
    }

    @Test("a place added by hand goes in beside one a few metres away")
    func addingByHandKeepsNeighbours() throws {
        let (hike, context) = try hike()
        hike.replacePlaces(with: [Self.hut()], in: context)

        let spring = TrailPlace(latitude: 47.61005, longitude: Line.longitude, symbol: .water)
        #expect(hike.addPlace(spring, in: context))
        #expect(hike.addPlace(Self.hut(), in: context) == false)
        #expect(hike.places.count == 2)
    }

    // MARK: Editing

    @Test("an OpenStreetMap place cannot be renamed")
    func osmPlaceIsReadOnly() throws {
        let (hike, context) = try hike()
        let hut = Self.hut()
        hike.replacePlaces(with: [hut], in: context)

        #expect(hike.editPlace(id: hut.id, name: "Mine", symbol: .camp, note: "x") == false)
        #expect(hike.places.first?.name == "Kärlingerhaus")
        #expect(hike.places.first?.symbol == .shelter)
    }

    @Test("a hiker's own place is renamed, re-kinded and annotated, trimmed")
    func ownPlaceIsEditable() throws {
        let (hike, context) = try hike()
        let own = Self.own()
        hike.replacePlaces(with: [own], in: context)

        #expect(hike.editPlace(id: own.id, name: "  Ford  ", symbol: nil, note: " High after rain "))
        let edited = try #require(hike.places.first)
        #expect(edited.name == "Ford")
        #expect(edited.symbol == nil)
        #expect(edited.note == "High after rain")
    }

    // MARK: Removing

    @Test("removing a place returns its photographs to the gallery")
    func removingUnfilesPhotos() throws {
        let (hike, context) = try hike()
        let own = Self.own()
        hike.replacePlaces(with: [own], in: context)
        var photo = HikePhoto()
        photo.placeID = own.id
        hike.addPhoto(photo)
        hike.addPhoto(HikePhoto())

        hike.removePlace(id: own.id, in: context)

        #expect(hike.places.isEmpty)
        #expect(hike.photos.count == 2)
        #expect(hike.photos.allSatisfy { $0.placeID == nil })
    }

    /// Discarding a recording deletes its hike while the recording screen is
    /// still up and still drawing that hike's places. Reading the route of a
    /// deleted row traps, so a deleted hike has no places to draw.
    @Test("a deleted hike has no places, rather than a route to trap on")
    func deletedHikeHasNoPlaces() throws {
        let (hike, context) = try hike()
        let own = Self.own()
        hike.replacePlaces(with: [own], in: context)
        try context.save()

        context.delete(hike)
        try context.save()

        #expect(hike.orderedPlaces.isEmpty)
        #expect(hike.places.isEmpty)
        #expect(hike.placeRow(id: own.id) == nil)
    }

    // MARK: The card

    @Test("a place's card says where it came from and who may edit it")
    func cardProvenance() throws {
        let (hike, context) = try hike()
        let hut = Self.hut()
        let own = Self.own()
        hike.replacePlaces(with: [hut, own], in: context)

        let hutCard = try #require(HikePlaceCard(hike: hike, placeID: hut.id))
        #expect(hutCard.isEditable == false)
        #expect(hutCard.openStreetMapURL?.absoluteString == "https://www.openstreetmap.org/way/42")
        #expect(hutCard.facts.count == 1)
        #expect(hutCard.distanceAlongRouteMeters != nil)

        let ownCard = try #require(HikePlaceCard(hike: hike, placeID: own.id))
        #expect(ownCard.isEditable)
        #expect(ownCard.openStreetMapURL == nil)
        #expect(ownCard.provenance != hutCard.provenance)
    }

    @Test("a place's card reads its glyph, colour and note off the place")
    func cardPassesThePlaceThrough() {
        let place = TrailPlace(latitude: 47.61, longitude: Line.longitude, symbol: .water, note: "Cold")
        let card = HikePlaceCard(row: TrailPlaceRow(place: place, anchor: nil))
        #expect(card.systemImage == TrailPlaceSymbol.water.systemImageName)
        #expect(card.tint == TrailPlaceSymbol.water.tint)
        #expect(card.coordinate.latitude == 47.61)
        #expect(card.note == "Cold")
        #expect(card.subtitle == nil, "an unnamed spring is titled by its kind, and a subtitle would repeat it")
    }

    @Test("a removed place has no card")
    func removedPlaceHasNoCard() throws {
        let (hike, context) = try hike()
        let own = Self.own()
        hike.replacePlaces(with: [own], in: context)
        hike.removePlace(id: own.id, in: context)

        #expect(HikePlaceCard(hike: hike, placeID: own.id) == nil)
    }
}
