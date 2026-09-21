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
            id: id
        )
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
    var orderedPlaces: [TrailPlaceRow] {
        TrailPlaceOrder.ordered((trailPoints ?? []).map(\.place), along: route)
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
}
