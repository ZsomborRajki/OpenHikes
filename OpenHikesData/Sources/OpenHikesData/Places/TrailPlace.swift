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
//  waypoint is dragged in a list and numbered; a place is never numbered, and
//  is described by how far along the line it sits rather than by an order
//  anybody chose.
//
//  ## Two names for one idea, and why
//
//  The row in the store is ``TrailPoint`` — that is the name the plan issue
//  gives it and the name CloudKit carries as `CD_TrailPoint`. This is the
//  value it is read and written as, and the word on screen is **place**,
//  because *point* already meant a waypoint in the maker when this was named,
//  and a *stop* is one now. Two things called the same word on one screen is
//  the sort of collision nobody can explain to a hiker afterwards.
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
//  optional, and `nil` draws a plain pin.
//

import Algorithms
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
/// devices naming it, which is exactly the state
/// ``TrailPlaceSymbol/named(_:)`` answers with `nil`.
nonisolated public enum TrailPlaceSymbol: String, CaseIterable, Codable, Hashable, Sendable {
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
    public var systemImageName: String {
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

    /// The symbol a stored id names, or `nil` for one this build does not
    /// know — an empty column, or a case a later version added.
    ///
    /// The same shape ``HikeWalk/endReason`` takes, and for the same reason:
    /// a mirrored raw value arrives from a device that may be running
    /// something else, so *unknown* has to be a reading rather than a crash.
    public static func named(_ id: String) -> Self? { Self(rawValue: id) }
}

/// One marked place, as everything that is not the store sees it.
///
/// `Codable` because the draft is written down as these — see
/// ``TrailDraftRecord`` — and `Identifiable` because both the list and the map
/// key on the identity rather than on the coordinate: a place that is dragged
/// is the same place, and two places dropped on one spot are two rows.
nonisolated public struct TrailPlace: Codable, Hashable, Identifiable, Sendable {
    /// How close two places have to be to be the same place — the rule the
    /// maker's search and a saved hike's place list both hold a new place to,
    /// because a place a hiker added by hand at the hut *is* the hut, whatever
    /// it is called.
    public static let alreadyMarkedMeters: Double = 25

    public let id: UUID
    public var latitude: Double
    public var longitude: Double
    /// What the hiker called it, or empty for one they have not named.
    ///
    /// Empty rather than optional, because a blank field is how a hiker says
    /// *I have not named this* and an optional would be a second spelling of
    /// the same answer. What is shown instead is ``displayName``.
    public var name: String
    /// What kind of place it is, or `nil` for one that makes no claim — see
    /// the file header.
    public var symbol: TrailPlaceSymbol?
    /// Anything else worth saying about it. Empty for most places, for the
    /// reason ``name`` is empty rather than absent.
    public var note: String
    /// Where OpenStreetMap keeps this place and what else it says about it —
    /// `nil` for a place that did not come from there, such as an imported
    /// `<wpt>` or one a hiker added while recording. Kept in the draft for the
    /// place sheet and written to a saved hike's ``TrailPoint``, so a saved
    /// trail's place card says what the maker's said.
    ///
    /// Also the line between the two kinds of place a saved hike holds: see
    /// ``isHikersOwn``.
    public var osm: TrailPlaceOSM?

    public init(
        latitude: Double,
        longitude: Double,
        name: String = "",
        symbol: TrailPlaceSymbol? = nil,
        note: String = "",
        osm: TrailPlaceOSM? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
        self.symbol = symbol
        self.note = note
        self.osm = osm
    }

    public init(
        coordinate: CLLocationCoordinate2D,
        name: String = "",
        symbol: TrailPlaceSymbol? = nil,
        note: String = "",
        osm: TrailPlaceOSM? = nil,
        id: UUID = UUID()
    ) {
        self.init(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            name: name,
            symbol: symbol,
            note: note,
            osm: osm,
            id: id
        )
    }

    public var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var routeCoordinate: RouteCoordinate {
        RouteCoordinate(latitude: latitude, longitude: longitude)
    }

    /// The glyph, falling back to a plain pin for a place that claims nothing.
    public var systemImageName: String {
        symbol?.systemImageName ?? "mappin"
    }

    /// Whether this place is the hiker's own to describe.
    ///
    /// **A place from OpenStreetMap is OpenStreetMap's**: its name and kind
    /// are what the map says, and the place to correct them is
    /// openstreetmap.org, which its card links to. So on a saved hike such a
    /// place takes photographs and nothing else, while one the hiker made —
    /// added while recording, or read out of a `.gpx` — can be renamed,
    /// re-kinded and annotated. Both kinds can be removed.
    public var isHikersOwn: Bool { osm == nil }
}

/// An OpenStreetMap element, and the tags on it a hiker would want to read.
nonisolated public struct TrailPlaceOSM: Codable, Hashable, Sendable {
    /// `node`, `way` or `relation`, as Overpass spells it.
    public let elementType: String
    public let elementID: Int64
    public var facts: [TrailPlaceFact] = []

    /// The three element types Overpass answers with. Anything else read back
    /// off a stored row or a shared file is no element at all.
    public static let elementTypes: Set<String> = ["node", "way", "relation"]

    /// The element a place-page link names, read back — what a GPX `<link>`
    /// written by ``url`` carries. `nil` for any other URL.
    public init?(url: URL) {
        guard url.host() == "www.openstreetmap.org" || url.host() == "openstreetmap.org" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, Self.elementTypes.contains(parts[0]),
              let id = Int64(parts[1]), id > 0 else { return nil }
        self.init(elementType: parts[0], elementID: id)
    }

    public init(elementType: String, elementID: Int64, facts: [TrailPlaceFact] = []) {
        self.elementType = elementType
        self.elementID = elementID
        self.facts = facts
    }

    /// Whether two places are the same OpenStreetMap element.
    public func isSameElement(as other: Self) -> Bool {
        elementType == other.elementType && elementID == other.elementID
    }

    /// The element's page on openstreetmap.org — where to read everything else
    /// and where to correct it.
    public var url: URL? {
        URL(string: "https://www.openstreetmap.org/\(elementType)/\(elementID)")
    }
}

/// One thing OpenStreetMap says about a place: its height, its hours, whether
/// the water is drinkable.
nonisolated public struct TrailPlaceFact: Codable, Hashable, Sendable {
    /// The tags read, in the order a place sheet lists them. Alphabetical here
    /// for the linter; ``Kind/allCases`` is the order. The raw value is the
    /// tag itself.
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case access = "access"
        case capacity = "capacity"
        case description = "description"
        case drinkingWater = "drinking_water"
        case elevation = "ele"
        case fee = "fee"
        case openingHours = "opening_hours"
        case operatorName = "operator"
        case phone = "phone"
        case website = "website"

        public static let allCases: [Self] = [
            .elevation, .description, .drinkingWater, .openingHours, .fee,
            .access, .capacity, .operatorName, .phone, .website,
        ]

        /// The tag, then the fallbacks OpenStreetMap also uses for it.
        public var tagKeys: [String] {
            switch self {
            case .phone: [rawValue, "contact:phone"]
            case .website: [rawValue, "contact:website", "url"]
            default: [rawValue]
            }
        }
    }

    public let kind: Kind
    /// The tag's value as written. Bounded when read — see ``facts(in:)``.
    public let value: String

    /// Every fact `tags` states, in display order. Values are bounded the way a
    /// keyword is, because they arrive off the wire.
    public static func facts(in tags: [String: String]) -> [Self] {
        Kind.allCases.compactMap { kind in
            kind.tagKeys.lazy
                .compactMap { BoundedText.bounded(tags[$0], to: .keywords) }
                .first
                .map { Self(kind: kind, value: $0) }
        }
    }

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
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
nonisolated public struct TrailPlaceAnchor: Equatable, Sendable {
    public var distanceAlongRouteMeters: Double
    public var offRouteMeters: Double

    /// How far off the line a place may sit and still be described by where it
    /// sits along it.
    ///
    /// Generous, because the figure is a label rather than a claim about
    /// walking to it: a hut a couple of hundred metres off the path is still
    /// *the hut at 4.1 km*, and the alternative for anything further is no
    /// figure at all rather than a wrong one. Picked by argument; nothing
    /// downstream is sensitive to the exact number.
    public static let describableOffRouteMeters: Double = 250

    /// Whether the along-route figure is worth showing.
    public var describesTheRoute: Bool {
        offRouteMeters <= Self.describableOffRouteMeters
    }

    /// How far off the line a place may sit and still be one a hiker walking
    /// it passes — what a save keeps. See ``TrailPlaceOrder/touched(_:along:)``.
    ///
    /// Much tighter than ``describableOffRouteMeters``, because this is a
    /// claim about walking to it rather than a label. A spring or a junction
    /// on a snapped leg is a node of the way the leg follows and sits at
    /// nothing; what needs the slack is a hut, which Overpass answers as the
    /// centre of its building rather than the door the path reaches, and a
    /// summit whose path stops a few metres short of the survey point. The
    /// same figure as ``TrailWalkPolicy/reachedEndProximityMeters``, the
    /// radius at which a walk counts as having got somewhere.
    public static let touchedOffRouteMeters: Double = 50

    public init(distanceAlongRouteMeters: Double, offRouteMeters: Double) {
        self.distanceAlongRouteMeters = distanceAlongRouteMeters
        self.offRouteMeters = offRouteMeters
    }
}

/// One place with where it sits, which is what a list row and a callout are
/// both built from.
///
/// A type rather than a tuple because it crosses a published property — see
/// ``TrailDraft/placeRows`` — and a tuple of an optional is neither
/// `Equatable` nor `Identifiable`, both of which that property and the
/// `ForEach` reading it need.
nonisolated public struct TrailPlaceRow: Equatable, Identifiable, Sendable {
    public var place: TrailPlace
    /// `nil` for a place that has no line to be measured against, or one too
    /// far off it to be described by — see ``TrailPlaceAnchor``.
    public var anchor: TrailPlaceAnchor?

    public var id: UUID { place.id }

    public init(place: TrailPlace, anchor: TrailPlaceAnchor? = nil) {
        self.place = place
        self.anchor = anchor
    }
}

nonisolated public enum TrailPlaceOrder {
    /// Where each place sits along `route`, keyed by identity.
    ///
    /// One walk over the line for all the places rather than one per place:
    /// a snapped trail is thousands of coordinates and a hiker marks a
    /// handful of places, so the route is the expensive half and is traversed
    /// once. Empty for a route with fewer than two points, which has no
    /// "along" to measure against.
    public static func anchors(
        of places: [TrailPlace],
        along route: [RouteCoordinate]
    ) -> [UUID: TrailPlaceAnchor] {
        guard route.count > 1, !places.isEmpty else { return [:] }
        let coordinates = route.map { point in
            CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        }
        // Projected out of the places once rather than read off each of them
        // inside the segment loop. ``TrailPlace/clCoordinate`` is computed, so
        // the inner read built a fresh `CLLocationCoordinate2D` per segment
        // per place — forty places against a snapped line is a hundred and
        // twenty thousand of them for one re-rank.
        let targets = places.map { place in (id: place.id, coordinate: place.clCoordinate) }
        var best: [UUID: TrailPlaceAnchor] = [:]
        best.reserveCapacity(places.count)
        var travelled: Double = 0
        for (start, end) in coordinates.adjacentPairs() {
            let length = RouteGeometry.distanceMeters(from: start, to: end)
            for target in targets {
                let projection = RouteGeometry.project(
                    target.coordinate,
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
                guard let existing = best[target.id] else {
                    best[target.id] = candidate
                    continue
                }
                if candidate.offRouteMeters < existing.offRouteMeters {
                    best[target.id] = candidate
                }
            }
            travelled += length
        }
        return best
    }

    /// The places of `places` a hiker walking `route` passes, in the order
    /// they were given — what a save keeps of a drawing's places.
    ///
    /// A search puts everything it found near the line onto the drawing, so
    /// the drawing holds the viewpoint two hundred metres up a side path and
    /// the summit across the valley alongside the spring on the climb. Those
    /// are worth seeing while the route is still being decided, and noise on
    /// a trail that is finished. Empty for a route with fewer than two points,
    /// which nothing can be on.
    public static func touched(
        _ places: [TrailPlace],
        along route: [RouteCoordinate]
    ) -> [TrailPlace] {
        let anchors = anchors(of: places, along: route)
        return places.filter { place in
            guard let anchor = anchors[place.id] else { return false }
            return anchor.offRouteMeters <= TrailPlaceAnchor.touchedOffRouteMeters
        }
    }

    /// `places` in the order they are met walking the line, with where each
    /// one sits.
    ///
    /// Places that cannot be measured — there is no line yet — keep the order
    /// they were marked in and carry no anchor, which is what the list draws
    /// as a place with no distance beside it. Dropping them instead would make
    /// marking a place before drawing a line look like it had failed.
    public static func ordered(
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
