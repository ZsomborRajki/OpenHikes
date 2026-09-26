//
//  HikePlaceChangeTests.swift
//  OpenHikesTests
//
//  Adding, editing and removing a hike's place by hand when the store
//  refuses the save (#719): the hike is put back as it was, an unrelated
//  pending edit survives, and trying again commits the change once.
//
//  Each test reads the outcome back through a fresh `ModelContext` on the same
//  container, which is what the store holds after a relaunch rather than what
//  the main context still has pending.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("Hike place changes")
struct HikePlaceChangeTests {
    private static let route = [
        RouteCoordinate(latitude: 47.60, longitude: 12.98),
        RouteCoordinate(latitude: 47.62, longitude: 12.98),
    ]

    private static func own(name: String = "Bivouac rock") -> TrailPlace {
        TrailPlace(latitude: 47.605, longitude: 12.98, name: name, symbol: .camp, note: "Dry")
    }

    /// A saved hike, and an edit of the hiker's own pending in the same
    /// context: what a `rollback()` would have taken with it.
    private func hike() throws -> (Hike, ModelContext) {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context, route: Self.route)
        try context.save()
        hike.title = "Renamed"
        return (hike, context)
    }

    private func stored(in context: ModelContext) throws -> [TrailPoint] {
        try ModelContext(context.container).fetch(FetchDescriptor<TrailPoint>())
    }

    private func renameToCave(
        _ place: TrailPlace,
        on hike: Hike,
        in context: ModelContext,
        save: HikePlaceChange.Save
    ) throws(HikePlaceRefusal) {
        try HikePlaceChange.edit(
            id: place.id,
            on: hike,
            name: "Cave",
            symbol: .viewpoint,
            note: "Wet",
            in: context,
            save: save
        )
    }

    @Test("a refused add takes the place back, and adding again commits it once")
    func refusedAddCanBeRetried() throws {
        let (hike, context) = try hike()
        let place = Self.own()
        let saver = ScriptedModelContextSaver(failedSaveNumbers: [1])

        #expect(throws: HikePlaceRefusal.notAdded) {
            try HikePlaceChange.add(place, to: hike, in: context, save: saver.save)
        }
        #expect(hike.places.isEmpty)
        #expect(hike.title == "Renamed")

        let added = try HikePlaceChange.add(place, to: hike, in: context, save: saver.save)

        #expect(added)
        #expect(hike.places.map(\.id) == [place.id])
        #expect(try stored(in: context).map(\.id) == [place.id])
    }

    @Test("adding an element the hike already has saves nothing")
    func heldElementIsNotSaved() throws {
        let (hike, context) = try hike()
        let hut = TrailPlace(
            latitude: 47.61,
            longitude: 12.98,
            symbol: .shelter,
            osm: TrailPlaceOSM(elementType: "way", elementID: 42, facts: [])
        )
        try HikePlaceChange.add(hut, to: hike, in: context)
        let saver = ScriptedModelContextSaver(failedSaveNumbers: [])

        let added = try HikePlaceChange.add(hut, to: hike, in: context, save: saver.save)

        #expect(added == false)
        #expect(saver.saveCount == 0)
    }

    @Test("a refused edit puts the place's words back, and saving again keeps the new ones")
    func refusedEditCanBeRetried() throws {
        let (hike, context) = try hike()
        let place = Self.own()
        try HikePlaceChange.add(place, to: hike, in: context)
        hike.title = "Renamed again"
        let saver = ScriptedModelContextSaver(failedSaveNumbers: [1])

        #expect(throws: HikePlaceRefusal.notEdited) {
            try renameToCave(place, on: hike, in: context, save: saver.save)
        }
        let restored = try #require(hike.places.first)
        #expect(restored.name == place.name)
        #expect(restored.symbol == place.symbol)
        #expect(restored.note == place.note)
        #expect(hike.title == "Renamed again")

        try renameToCave(place, on: hike, in: context, save: saver.save)

        let kept = try #require(try stored(in: context).first?.place)
        #expect(kept.name == "Cave")
        #expect(kept.symbol == .viewpoint)
        #expect(kept.note == "Wet")
    }

    @Test("a refused removal puts the place and its photographs back, and a later save keeps them")
    func refusedRemovalIsPutBack() throws {
        let (hike, context) = try hike()
        let place = Self.own()
        try HikePlaceChange.add(place, to: hike, in: context)
        var photo = HikePhoto()
        photo.placeID = place.id
        hike.addPhoto(photo)
        hike.addPhoto(HikePhoto())
        try context.save()
        let saver = ScriptedModelContextSaver(failedSaveNumbers: [1])

        #expect(throws: HikePlaceRefusal.notRemoved) {
            try HikePlaceChange.remove(id: place.id, from: hike, in: context, save: saver.save)
        }
        #expect(hike.places.map(\.id) == [place.id])
        #expect(hike.photos(ofPlace: place.id).map(\.id) == [photo.id])
        #expect(HikePlaceCard(hike: hike, placeID: place.id) != nil)

        // The autosave the old code was relying on: the place must survive it.
        try context.save()
        #expect(try stored(in: context).map(\.id) == [place.id])
        #expect(try stored(in: context).first?.place.name == place.name)
    }

    @Test("removing again after a refusal takes the place off once and unfiles its photographs")
    func refusedRemovalCanBeRetried() throws {
        let (hike, context) = try hike()
        let place = Self.own()
        try HikePlaceChange.add(place, to: hike, in: context)
        var photo = HikePhoto()
        photo.placeID = place.id
        hike.addPhoto(photo)
        let saver = ScriptedModelContextSaver(failedSaveNumbers: [1])

        #expect(throws: HikePlaceRefusal.notRemoved) {
            try HikePlaceChange.remove(id: place.id, from: hike, in: context, save: saver.save)
        }
        try HikePlaceChange.remove(id: place.id, from: hike, in: context, save: saver.save)

        #expect(hike.places.isEmpty)
        #expect(hike.photos.allSatisfy { $0.placeID == nil })
        #expect(try stored(in: context).isEmpty)
        #expect(hike.title == "Renamed")
    }
}
