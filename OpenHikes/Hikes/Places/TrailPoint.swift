//
//  TrailPoint.swift
//  OpenHikes
//
//  One marked place, kept with the hike it belongs to.
//
//  A `@Model` in the mirrored store rather than a value array on ``Hike`` like
//  ``Hike/photos``, and the argument is ``HikeWalk``'s with one addition. A
//  place is a fact about the trail rather than about the phone, so it syncs;
//  the cascade on the relationship is what takes the places with the hike
//  without a deletion step of its own; and a place is a row rather than an
//  element because the *pixels* problem `photos` has does not exist here — a
//  place is a coordinate, two short strings and an identifier, and a hike with
//  thirty of them is a couple of kilobytes rather than a gallery.
//
//  The addition is CloudKit's: unlike a photograph, all of a place fits in a
//  record, so this is the first thing the app stores that reaches a second
//  device *complete*. Nothing has to be said about a place that is not on this
//  device, because there is no such state.
//
//  **Append-only from the day it ships**, for the reason `HikeWalk` says it:
//  the mirrored schema never lets a column change type or go away, which is
//  why ``symbolID`` is a string rather than an enumeration the store knows
//  about, and why an id this build cannot read is answered as *no symbol*
//  rather than as a failure.
//
//  See ``TrailPlace`` for the value this is read and written as, for why the
//  word on screen is *place* rather than *point*, and for the rule that an
//  unstated symbol is a state rather than a missing one.
//

import Foundation
import SwiftData

@Model
final class TrailPoint {
    /// `id` for identity lookups and `hikeID` for the places of one hike.
    /// `#Index` rather than `#Unique` for the reason ``Hike`` gives and
    /// mirroring settles: a uniqueness constraint is forbidden outright.
    #Index<TrailPoint>([\.id], [\.hikeID])

    // Every non-optional column carries an inline default, because mirroring
    // refuses to open a store whose mandatory attributes cannot be backfilled.

    var id = UUID()
    /// The host's id, by value, beside the relationship below — the same pair
    /// ``HikeWalk`` carries, and for the same reason: a query that filters on
    /// a column is not invalidated by a write to the hike's own row.
    var hikeID = UUID()
    /// The host. Optional and inversed, both required by CloudKit mirroring.
    var hike: Hike?
    var latitude: Double = 0
    var longitude: Double = 0
    /// What the hiker called it, empty for one they did not name. See
    /// ``TrailPlace/name``.
    var name: String = ""
    /// ``TrailPlaceSymbol`` by raw value, and empty for a place that claims
    /// nothing about what it is.
    ///
    /// Empty rather than an optional column: "no symbol" is a real answer
    /// here rather than an absent one, and an optional would make *unset* and
    /// *unstated* two spellings of it that every reader would have to collapse
    /// anyway.
    var symbolID: String = ""
    var note: String = ""
    /// `node`, `way` or `relation` for a place that came from OpenStreetMap,
    /// and empty for one a hiker made — see ``TrailPlace/osm``.
    ///
    /// Kept since the place overhaul, which is what lets a saved trail's place
    /// card say what the maker's said: the element is the link to
    /// openstreetmap.org and the proof that the place is OpenStreetMap's to
    /// name rather than the hiker's. Empty rather than optional for the reason
    /// ``symbolID`` is.
    var osmElementType: String = ""
    /// The element's id, `0` alongside an empty ``osmElementType``.
    var osmElementID: Int64 = 0
    /// What OpenStreetMap said about the place when it was found — its height,
    /// whether the water is drinkable. A few short strings, so a value column
    /// rather than rows, the way ``Hike/photos`` is one.
    var osmFacts: [TrailPlaceFact] = []
    /// When it was marked. Read by nothing today; kept because it is the one
    /// fact about a place that cannot be recovered afterwards, and because it
    /// is what orders two places a GPX round-trip gave the same everything
    /// else.
    var createdAt = Date.distantPast

    init(hikeID: UUID, place: TrailPlace, createdAt: Date = .now) {
        self.hikeID = hikeID
        id = place.id
        latitude = place.latitude
        longitude = place.longitude
        name = place.name
        symbolID = place.symbol?.rawValue ?? ""
        note = place.note
        osmElementType = place.osm?.elementType ?? ""
        osmElementID = place.osm?.elementID ?? 0
        osmFacts = place.osm?.facts ?? []
        self.createdAt = createdAt
    }
}

extension TrailPoint {
    /// This row as the value everything outside the store works in.
    var place: TrailPlace {
        TrailPlace(
            latitude: latitude,
            longitude: longitude,
            name: name,
            symbol: TrailPlaceSymbol.named(symbolID),
            note: note,
            osm: osm,
            id: id
        )
    }

    /// The OpenStreetMap element this place is, or `nil` for one a hiker made.
    private var osm: TrailPlaceOSM? {
        guard TrailPlaceOSM.elementTypes.contains(osmElementType), osmElementID > 0 else { return nil }
        return TrailPlaceOSM(elementType: osmElementType, elementID: osmElementID, facts: osmFacts)
    }

    /// Writes the three things a hiker may change about a place they made.
    /// See ``Hike/editPlace(id:name:symbol:note:)`` for who may.
    func apply(name: String, symbol: TrailPlaceSymbol?, note: String) {
        if self.name != name { self.name = name }
        let symbolID = symbol?.rawValue ?? ""
        if self.symbolID != symbolID { self.symbolID = symbolID }
        if self.note != note { self.note = note }
    }
}

extension Hike {
    /// This hike's marked places, in the order they are met along its route.
    ///
    /// Read through the relationship rather than through a `@Query` on
    /// ``TrailPoint/hikeID``, unlike the walks: there is no screen that lists
    /// places across hikes, and what every caller wants is *this trail's*,
    /// already ordered against *this trail's* line. The sort is
    /// ``TrailPlaceOrder``'s rather than a stored rank, because where a place
    /// sits along a route is a fact about the geometry — an edited line moves
    /// it without anything having been written.
    ///
    /// Empty for a hike that has been deleted or detached. A screen showing
    /// one can re-render between the delete and the pop that takes it away —
    /// discarding a recording does exactly that to the recording screen — and
    /// ``Hike/route`` is external storage that traps when it is faulted in off
    /// a deleted row. See ``Hike/isAttached``.
    var orderedPlaces: [TrailPlaceRow] {
        guard isAttached else { return [] }
        return TrailPlaceOrder.ordered(places, along: route)
    }

    /// This hike's places as values, in no particular order. Empty for a hike
    /// that has been deleted or detached, as ``orderedPlaces`` is.
    var places: [TrailPlace] {
        guard isAttached else { return [] }
        return (trailPoints ?? []).map(\.place)
    }

    /// One place, with where it sits on the route — what its card is built
    /// from. `nil` for one that has gone, which closes the card.
    func placeRow(id: UUID) -> TrailPlaceRow? {
        guard isAttached, let place = trailPoints?.first(where: { $0.id == id })?.place else { return nil }
        let anchor = TrailPlaceOrder.anchors(of: [place], along: route)[id]
        return TrailPlaceRow(place: place, anchor: anchor?.describesTheRoute == true ? anchor : nil)
    }

    /// Replaces this hike's places with `places`, which is what a save and an
    /// import both do.
    ///
    /// Written as a whole set rather than one row at a time, because both
    /// callers have the whole set: a drawn trail is saved once and an imported
    /// file arrives once. The rows that go are deleted rather than orphaned —
    /// the cascade only fires when the *hike* goes.
    func replacePlaces(with places: [TrailPlace], in context: ModelContext, now: Date = .now) {
        for existing in trailPoints ?? [] {
            context.delete(existing)
        }
        trailPoints = places.map { place in
            TrailPoint(hikeID: id, place: place, createdAt: now)
        }
    }

    /// Adds `places` to the ones this hike already has, leaving out any it
    /// already holds, and answers the ones that went in.
    ///
    /// *Already holds* is the same OpenStreetMap element, or anything within
    /// ``TrailPointRanking/alreadyMarkedMeters`` of a place already here —
    /// the rule the maker's search uses, and for its reason: a place a hiker
    /// added by hand at the hut is the hut, whatever it is called.
    ///
    /// Each of `places` is checked against the ones added before it **by
    /// element only**, so an answer that names one spring twice adds it once
    /// while the hut and the spring beside it both go in. The distance rule is
    /// for what the hike held before, not for `places` among themselves:
    /// *Find Places Along Trail* lists every place it found as a row of its
    /// own, and a ticked row that quietly failed to arrive would be the list
    /// saying one thing and the hike another.
    @discardableResult func addPlaces(
        _ places: [TrailPlace],
        in context: ModelContext,
        now: Date = .now
    ) -> [TrailPlace] {
        let held = self.places
        var added: [TrailPlace] = []
        for place in places where !Self.holds(place, among: held) && !Self.isSameElement(place, asAnyOf: added) {
            added.append(place)
        }
        guard !added.isEmpty else { return [] }
        let rows = added.map { TrailPoint(hikeID: id, place: $0, createdAt: now) }
        // Inserted before they are related, for the reason a save's rows are:
        // a relationship assigned to a row that is in no context yet has
        // nowhere to put it.
        for row in rows { context.insert(row) }
        trailPoints = (trailPoints ?? []) + rows
        return added
    }

    /// Adds one place a hiker chose by hand, answering whether it went in.
    ///
    /// Unlike ``addPlaces(_:in:now:)`` this does not leave out a place near
    /// one already held: a hiker standing between the hut and its spring who
    /// adds both meant both. Only the same OpenStreetMap element twice is
    /// refused, because that is one place.
    @discardableResult func addPlace(_ place: TrailPlace, in context: ModelContext, now: Date = .now) -> Bool {
        if Self.isSameElement(place, asAnyOf: places) { return false }
        let row = TrailPoint(hikeID: id, place: place, createdAt: now)
        context.insert(row)
        trailPoints = (trailPoints ?? []) + [row]
        return true
    }

    private static func holds(_ place: TrailPlace, among held: [TrailPlace]) -> Bool {
        isSameElement(place, asAnyOf: held) || held.contains { existing in
            RouteGeometry.distanceMeters(from: existing.clCoordinate, to: place.clCoordinate)
                <= TrailPointRanking.alreadyMarkedMeters
        }
    }

    /// Whether `place` is an OpenStreetMap element one of `others` already is.
    /// Never true of a place the hiker made, which is no element.
    private static func isSameElement(_ place: TrailPlace, asAnyOf others: [TrailPlace]) -> Bool {
        guard let osm = place.osm else { return false }
        return others.contains { $0.osm.map(osm.isSameElement(as:)) == true }
    }

    /// Renames, re-kinds and re-describes one of the hiker's own places.
    ///
    /// Refuses a place from OpenStreetMap, which is the rule
    /// ``TrailPlace/isHikersOwn`` states: its name and kind are the map's.
    /// Answers whether anything was written.
    @discardableResult func editPlace(
        id: UUID,
        name: String,
        symbol: TrailPlaceSymbol?,
        note: String
    ) -> Bool {
        guard let row = trailPoints?.first(where: { $0.id == id }), row.place.isHikersOwn else { return false }
        row.apply(
            name: BoundedText.boundedOrEmpty(name, to: .title),
            symbol: symbol,
            note: BoundedText.boundedOrEmpty(note, to: .notes)
        )
        return true
    }

    /// Takes one place off this hike, and the photographs filed under it back
    /// into the hike's own gallery.
    ///
    /// The photographs stay: they are pictures of this walk whichever place
    /// they were of, and deleting a hiker's pictures as a side effect of
    /// tidying a list is not something anybody would expect a *Remove* to do.
    func removePlace(id: UUID, in context: ModelContext) {
        guard let row = trailPoints?.first(where: { $0.id == id }) else { return }
        trailPoints?.removeAll { $0.id == id }
        context.delete(row)
        unfilePhotos(fromPlace: id)
    }
}
