//
//  TrailPlace.swift
//  OpenHikes
//
//  A place worth marking on a trail: a spring, a saddle, a hut, a junction
//  you will otherwise walk past.
//
//  A drawn line says where a walk goes and nothing about what is on it. That
//  is the half of planning a route this adds, and it is deliberately a
//  different kind of thing from a waypoint: a waypoint is a *rank* — it is the
//  third place the line goes through — while this is a *place on the ground*.
//  The consequence is written into every screen that touches the two. A
//  waypoint is dragged in a list and numbered; a place is dragged by its pin
//  and never numbered, and is listed by how far along the line it sits rather
//  than by an order anybody chose.
//
//  ## Two names for one idea, and why
//
//  The row in the store is ``TrailPoint`` — that is the name the plan issue
//  gives it and the name CloudKit carries as `CD_TrailPoint`. This is the
//  value it is read and written as, and the word on screen is **place**,
//  because *point* already means a waypoint in the maker: the list's header
//  says "Points" and every pin on the line is labelled "Point 3". Two things
//  called the same word on one screen is the sort of collision nobody can
//  explain to a hiker afterwards.
//
//  The same shape ``HikeWalk`` and ``TrailWalkRecord`` already take: a `@Model`
//  for the row, a `Sendable` value for everything that is not the store. It is
//  what lets the maker hold places in a draft that is not a model graph, and
//  what lets the map draw them without touching a `ModelContext`.
//
//  ## An unstated symbol is a state, not a missing value
//
//  Every eighth of the curated set is a claim about a place — *this is a
//  spring*, *this is a shelter* — and there is a real case with no claim to
//  make: a `<wpt>` that arrived in somebody else's GPX carrying a `<sym>` this
//  app has no glyph for. Defaulting one of those to *viewpoint* would be the
//  app inventing a fact about a place it has never been. So ``symbol`` is
//  optional, `nil` draws a plain pin, and the picker offers it as a choice
//  rather than hiding it.
//

import CoreLocation
import Foundation

/// What kind of place this is, from the small curated set the picker offers.
///
/// The raw value is doing two jobs and that is deliberate: it is the id stored
/// on ``TrailPoint/symbolID``, and it is the `<sym>` written into GPX. One
/// string rather than two tables to keep in step — and the capitalisation is
/// GPX's own convention rather than a display choice, which is why ``label``
/// exists separately and is the only thing ever shown.
///
/// **Append-only from the day it ships**, like every other raw value that
/// reaches a mirrored column: a case that goes away leaves rows on other
/// devices naming it, which is exactly the state ``TrailPoint/symbol``
/// answers with `nil`.
nonisolated enum TrailPlaceSymbol: String, CaseIterable, Codable, Hashable, Sendable {
    // Alphabetical, which is also the order the picker draws them in: the
    // linter wants the cases sorted, and eight glyphs on one grid have no
    // natural order worth spending a second list on.
    case camp = "Camp"
    case caution = "Caution"
    case junction = "Junction"
    case parking = "Parking"
    case shelter = "Shelter"
    case summit = "Summit"
    case viewpoint = "Viewpoint"
    case water = "Water"

    /// The glyph, in the pin and in the list.
    var systemImageName: String {
        switch self {
        case .viewpoint: "binoculars.fill"
        case .water: "drop.fill"
        case .shelter: "house.fill"
        case .junction: "arrow.triangle.branch"
        case .parking: "parkingsign"
        case .summit: "mountain.2.fill"
        case .camp: "tent.fill"
        case .caution: "exclamationmark.triangle.fill"
        }
    }

    /// The word, which is also what an unnamed place is called.
    ///
    /// Separate from ``rawValue`` even where the two currently read the same,
    /// because one of them is a lookup key in somebody else's symbol table and
    /// the other is a sentence in the hiker's language. Translating the raw
    /// value would silently rewrite every stored row and every exported file.
    var label: String {
        switch self {
        case .viewpoint: String(localized: "Viewpoint")
        case .water: String(localized: "Water")
        case .shelter: String(localized: "Shelter")
        case .junction: String(localized: "Junction")
        case .parking: String(localized: "Parking")
        case .summit: String(localized: "Summit")
        case .camp: String(localized: "Camp")
        case .caution: String(localized: "Caution")
        }
    }

    /// The symbol a stored id names, or `nil` for one this build does not
    /// know — an empty column, or a case a later version added.
    ///
    /// The same shape ``HikeWalk/endReason`` takes, and for the same reason:
    /// a mirrored raw value arrives from a device that may be running
    /// something else, so *unknown* has to be a reading rather than a crash.
    static func named(_ id: String) -> Self? { Self(rawValue: id) }
}

/// One marked place, as everything that is not the store sees it.
///
/// `Codable` because the draft is written down as these — see
/// ``TrailDraftRecord`` — and `Identifiable` because both the list and the map
/// key on the identity rather than on the coordinate: a place that is dragged
/// is the same place, and two places dropped on one spot are two rows.
nonisolated struct TrailPlace: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var latitude: Double
    var longitude: Double
    /// What the hiker called it, or empty for one they have not named.
    ///
    /// Empty rather than optional, because a blank field is how a hiker says
    /// *I have not named this* and an optional would be a second spelling of
    /// the same answer. What is shown instead is ``displayName``.
    var name: String
    /// What kind of place it is, or `nil` for one that makes no claim — see
    /// the file header.
    var symbol: TrailPlaceSymbol?
    /// Anything else worth saying about it. Empty for most places, for the
    /// reason ``name`` is empty rather than absent.
    var note: String

    init(
        latitude: Double,
        longitude: Double,
        name: String = "",
        symbol: TrailPlaceSymbol? = nil,
        note: String = "",
        id: UUID = UUID()
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
        self.symbol = symbol
        self.note = note
    }

    init(
        coordinate: CLLocationCoordinate2D,
        name: String = "",
        symbol: TrailPlaceSymbol? = nil,
        note: String = "",
        id: UUID = UUID()
    ) {
        self.init(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            name: name,
            symbol: symbol,
            note: note,
            id: id
        )
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var routeCoordinate: RouteCoordinate {
        RouteCoordinate(latitude: latitude, longitude: longitude)
    }

    /// What this place is called on screen: its name, or the word for what it
    /// is, or simply *Place*.
    ///
    /// The fallback chain rather than an empty label, because unnamed is the
    /// normal case and a row of blanks is unreadable — a waterfall, a spring
    /// and a viewpoint mostly have no name at all, which is the measurement
    /// the plan issue makes against OpenStreetMap and the reason a place is
    /// built from a symbol and a distance rather than from a name.
    var displayName: String {
        if !name.isEmpty { return name }
        return symbol?.label ?? String(localized: "Place")
    }

    /// The glyph, falling back to a plain pin for a place that claims nothing.
    var systemImageName: String {
        symbol?.systemImageName ?? "mappin"
    }

    /// Whether this place would draw and read identically to `other`.
    ///
    /// Everything but the identity, which is what the editor compares to
    /// decide whether a dismissal is worth a write — see
    /// ``TrailPlaceEditor``.
    func matches(_ other: Self) -> Bool {
        latitude == other.latitude
            && longitude == other.longitude
            && name == other.name
            && symbol == other.symbol
            && note == other.note
    }
}

// MARK: - Where a place sits on the line

/// How far along a line a place is, and how far off it.
///
/// Both halves are needed and they answer different questions. The distance
/// *along* is what the list sorts and labels by — "Waterfall, 2.3 km" is the
/// whole of what an unnamed place has to identify it. The distance *off* is
/// what says whether the figure means anything: a place a hiker dropped two
/// kilometres from their line is not at 2.3 km of it in any useful sense, and
/// a row that claimed so would be worse than one that says nothing.
nonisolated struct TrailPlaceAnchor: Equatable, Sendable {
    var distanceAlongRouteMeters: Double
    var offRouteMeters: Double

    /// How far off the line a place may sit and still be described by where it
    /// sits along it.
    ///
    /// Generous, because the figure is a label rather than a claim about
    /// walking to it: a hut a couple of hundred metres off the path is still
    /// *the hut at 4.1 km*, and the alternative for anything further is no
    /// figure at all rather than a wrong one. Picked by argument; nothing
    /// downstream is sensitive to the exact number.
    static let describableOffRouteMeters: Double = 250

    /// Whether the along-route figure is worth showing.
    var describesTheRoute: Bool {
        offRouteMeters <= Self.describableOffRouteMeters
    }
}

/// One place with where it sits, which is what a list row and a callout are
/// both built from.
///
/// A type rather than a tuple because it crosses a published property — see
/// ``TrailDraft/placeRows`` — and a tuple of an optional is neither
/// `Equatable` nor `Identifiable`, both of which that property and the
/// `ForEach` reading it need.
nonisolated struct TrailPlaceRow: Equatable, Identifiable, Sendable {
    var place: TrailPlace
    /// `nil` for a place that has no line to be measured against, or one too
    /// far off it to be described by — see ``TrailPlaceAnchor``.
    var anchor: TrailPlaceAnchor?

    var id: UUID { place.id }
}

nonisolated enum TrailPlaceOrder {
    /// Where each place sits along `route`, keyed by identity.
    ///
    /// One walk over the line for all the places rather than one per place:
    /// a snapped trail is thousands of coordinates and a hiker marks a
    /// handful of places, so the route is the expensive half and is traversed
    /// once. Empty for a route with fewer than two points, which has no
    /// "along" to measure against.
    static func anchors(
        of places: [TrailPlace],
        along route: [RouteCoordinate]
    ) -> [UUID: TrailPlaceAnchor] {
        guard route.count > 1, !places.isEmpty else { return [:] }
        let coordinates = route.map { point in
            CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        }
        var best: [UUID: TrailPlaceAnchor] = [:]
        best.reserveCapacity(places.count)
        var travelled: Double = 0
        for index in 0..<(coordinates.count - 1) {
            let start = coordinates[index]
            let end = coordinates[index + 1]
            let length = RouteGeometry.distanceMeters(from: start, to: end)
            for place in places {
                let projection = RouteGeometry.project(
                    place.clCoordinate,
                    onSegmentFrom: start,
                    to: end
                )
                let candidate = TrailPlaceAnchor(
                    distanceAlongRouteMeters: travelled + length * projection.fraction,
                    offRouteMeters: projection.offRouteMeters
                )
                // Nearest to the line wins, not first along it. A trail that
                // doubles back passes a place twice, and the crossing the
                // hiker means is the one it actually touches.
                guard let existing = best[place.id] else {
                    best[place.id] = candidate
                    continue
                }
                if candidate.offRouteMeters < existing.offRouteMeters {
                    best[place.id] = candidate
                }
            }
            travelled += length
        }
        return best
    }

    /// `places` in the order they are met walking the line, with where each
    /// one sits.
    ///
    /// Places that cannot be measured — there is no line yet — keep the order
    /// they were marked in and carry no anchor, which is what the list draws
    /// as a place with no distance beside it. Dropping them instead would make
    /// marking a place before drawing a line look like it had failed.
    static func ordered(
        _ places: [TrailPlace],
        along route: [RouteCoordinate]
    ) -> [TrailPlaceRow] {
        let anchors = anchors(of: places, along: route)
        guard !anchors.isEmpty else {
            return places.map { TrailPlaceRow(place: $0, anchor: nil) }
        }
        return places
            .enumerated()
            .sorted { left, right in
                let leftAnchor = anchors[left.element.id]
                let rightAnchor = anchors[right.element.id]
                switch (leftAnchor, rightAnchor) {
                case let (lhs?, rhs?):
                    guard lhs.distanceAlongRouteMeters != rhs.distanceAlongRouteMeters else {
                        // Two places at the same distance keep the order they
                        // were marked in, so the list never reshuffles under a
                        // hiker for a difference of nothing.
                        return left.offset < right.offset
                    }
                    return lhs.distanceAlongRouteMeters < rhs.distanceAlongRouteMeters
                // An unmeasured place sorts after every measured one: it is
                // not on the line, so it belongs under the places that are.
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return left.offset < right.offset
                }
            }
            .map { indexed in
                let anchor = anchors[indexed.element.id]
                // An anchor that cannot describe the route is dropped rather
                // than shown: the sort above still used it, because *nearest
                // crossing* is the best order there is for a place beside the
                // line, but a figure nobody should read is worse than none.
                return TrailPlaceRow(
                    place: indexed.element,
                    anchor: anchor?.describesTheRoute == true ? anchor : nil
                )
            }
    }
}
