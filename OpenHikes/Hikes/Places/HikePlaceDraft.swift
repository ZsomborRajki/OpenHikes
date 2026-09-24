//
//  HikePlaceDraft.swift
//  OpenHikes
//
//  What *Add Place* from the map's pill has been told so far, before anything
//  is on the hike.
//
//  A value apart from ``HikePlaceAdder`` for the reason ``HikePlaceCard`` is
//  one apart from its screen: what the form starts out saying, how the name
//  follows the kind, and what is finally written are decisions, and a decision
//  inside a body is one only a UI test can check.
//

import CoreLocation
import Foundation

/// Where a place about to be added stands, and the id it will be added under.
///
/// The id is decided here rather than at *Add*, so the pin standing in for the
/// place and the place itself are the same row to the map: adding it redraws
/// a glyph rather than taking one pin down and putting another up.
nonisolated struct HikePlaceSpot: Hashable, Sendable {
    let id: UUID
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D, id: UUID = UUID()) {
        self.id = id
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// The three things a hiker says about a place of their own — the same three
/// ``HikePlaceEditor`` asks about one already on the hike.
nonisolated struct HikePlaceDraft: Equatable, Sendable {
    /// What a place added from the pill is until the hiker says otherwise.
    /// The pill is on the map, and what a hiker stops on a trail to mark is
    /// most often the view.
    static let defaultKind: TrailPlaceSymbol = .viewpoint

    /// Starts as the kind's own name, so the field is filled in rather than
    /// showing a prompt — the user's choice, 2026-09-24.
    var name = Self.defaultKind.label
    private(set) var symbol: TrailPlaceSymbol? = Self.defaultKind
    var note = ""

    /// Changes the kind, and the name with it for as long as the name is still
    /// the old kind's own — a hiker who picks *Summit* over the prefilled
    /// *Viewpoint* would otherwise be adding a summit called "Viewpoint". A
    /// name the hiker typed is theirs and stays.
    mutating func setKind(_ kind: TrailPlaceSymbol?) {
        if name.trimmingCharacters(in: .whitespacesAndNewlines) == Self.label(of: symbol) {
            name = Self.label(of: kind)
        }
        symbol = kind
    }

    /// What the form's header shows as the title: the name, or the kind's
    /// label when the field is blank — ``TrailPlace/displayName``'s rule.
    var displayName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.isEmpty else { return typed }
        return symbol?.label ?? String(localized: "Place")
    }

    /// The place as it would go onto the hike.
    ///
    /// A name that only repeats the kind is stored blank, which is how every
    /// other unnamed place is stored: it reads the same everywhere
    /// (``TrailPlace/displayName`` falls back to the kind), and it keeps a
    /// card from saying "Viewpoint · Viewpoint".
    func place(at spot: HikePlaceSpot) -> TrailPlace {
        let bounded = BoundedText.boundedOrEmpty(name, to: .title)
        return TrailPlace(
            coordinate: spot.coordinate,
            name: bounded == Self.label(of: symbol) ? "" : bounded,
            symbol: symbol,
            note: BoundedText.boundedOrEmpty(note, to: .notes),
            id: spot.id
        )
    }

    /// The pin standing in for the place while it is being described: the
    /// kind's glyph and colour, where it will be. No name, so typing one does
    /// not redraw every pin on the map once a keystroke — the map draws no
    /// title for these anyway.
    func placeholder(at spot: HikePlaceSpot) -> TrailPlaceRow {
        TrailPlaceRow(
            place: TrailPlace(coordinate: spot.coordinate, symbol: symbol, id: spot.id),
            anchor: nil
        )
    }

    private static func label(of kind: TrailPlaceSymbol?) -> String {
        kind?.label ?? ""
    }
}
