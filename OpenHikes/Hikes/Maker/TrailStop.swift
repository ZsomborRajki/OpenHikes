//
//  TrailStop.swift
//  OpenHikes
//
//  A stop on a drawn trail, what it is to the route, and the row it fills.
//
//  The values ``TrailDraft`` keeps and hands out, apart from the type that
//  keeps them.
//

import CoreLocation
import Foundation

/// One point a hiker put down, and the identity that lets a list draw it.
///
/// Latitude and longitude rather than a `CLLocationCoordinate2D`, because that
/// type is neither `Equatable` nor `Hashable` — and an `@Observable` filters a
/// same-value write only for a value that can answer whether it is one (see
/// *Render isolation, in practice*). The same reason ``RouteCoordinate``
/// stores its pair that way.
///
/// The id is what a row is keyed on and what a reorder moves, so it survives
/// the point being moved on the ground: two waypoints dropped on the same spot
/// are still two waypoints.
nonisolated struct TrailWaypoint: Identifiable, Hashable, Sendable {
    let id: UUID
    var latitude: Double
    var longitude: Double
    /// What this spot is called, or empty for one nothing has named yet.
    ///
    /// A waypoint acquired a name when the list became a list of *stops* rather
    /// than of numbered points: a row reading "Lurdy Ház" is the one thing that
    /// makes a route readable without the map beside it, and it is what the
    /// search sheet writes back into the row it was opened from — see
    /// ``TrailStopSearchSheet``.
    ///
    /// Two things can fill it and they are not the same. A search result
    /// arrives named by MapKit and the hiker chose it. A point put down by a
    /// tap on the map arrives with nothing, and ``TrailStopNaming`` asks what
    /// is there a moment later; that answer is a *description* rather than a
    /// choice, which is why a later answer never overwrites a choice and why
    /// moving the point throws it away again. Empty is a state and not a
    /// missing value: ``TrailStopRole/title`` is what a nameless stop reads as.
    var name: String = ""

    init(
        latitude: Double,
        longitude: Double,
        id: UUID = UUID(),
        name: String = ""
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }

    init(coordinate: CLLocationCoordinate2D, id: UUID = UUID(), name: String = "") {
        self.init(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            id: id,
            name: name
        )
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The shape a saved route and a stored draft are both written in.
    var routeCoordinate: RouteCoordinate {
        RouteCoordinate(latitude: latitude, longitude: longitude)
    }
}

/// What a point is to the route it is in: where it starts, somewhere it passes
/// through, or where it ends.
///
/// Derived from a point's place in the list rather than stored on it, and that
/// is the same argument ``TrailPlace`` makes for having no rank: the role *is*
/// the position, so storing it would be a second answer to a question the list
/// already answers — and one that a reorder, an insert or a delete would leave
/// behind. Dragging the last stop to the top makes it the start, with nothing
/// written anywhere.
///
/// A one-point draft is a start, or a destination with the start still open —
/// see ``TrailDraft/startIsOpen``. Never both: there is no line yet, so
/// calling it both ends would be two words for one pin.
/// The cases are in alphabetical order rather than in route order, which reads
/// oddly and is the linter's `sorted_enum_cases` rather than a statement: the
/// order a route is walked in is ``of(waypointAt:in:)`` below.
nonisolated enum TrailStopRole: Hashable, Sendable {
    case end
    case start
    /// The *n*th stop along the way, counted from one, as a hiker reads it.
    case stop(number: Int)

    static func of(waypointAt index: Int, in count: Int) -> Self {
        if index == 0 { return .start }
        if index == count - 1 { return .end }
        return .stop(number: index)
    }

    /// What a row reads when nothing has named the point — the fallback
    /// ``TrailWaypoint/name`` describes, and the word beside a named one.
    var title: String {
        switch self {
        case .start: String(localized: "Start")
        case .stop(let number): String(localized: "Stop \(number)")
        case .end: String(localized: "Destination")
        }
    }

    /// The glyph on the route's own line. Filled at the two ends and hollow in
    /// between, which is the whole of what a picture of a route has to say:
    /// these are where it begins and finishes, and those are places it passes.
    var systemImageName: String {
        switch self {
        case .start, .end: "circle.fill"
        case .stop: "circle"
        }
    }
}

/// One row of the route list: a point, or a field still waiting for one.
///
/// Apple Maps' directions card opens with two empty fields, *start* and
/// *destination*, and so does the maker — so a list of rows is not the list of
/// points until there are two of them. Derived, like the role, and stored
/// nowhere.
nonisolated enum TrailStopSlot: Hashable, Sendable, Identifiable {
    /// A field with nothing in it yet. The role is `.start` or `.end`.
    case open(TrailStopRole)
    case point(index: Int, id: UUID)

    var id: String {
        switch self {
        case .open(.start): "open-start"
        case .open: "open-end"
        case .point(_, let id): id.uuidString
        }
    }

    var waypointIndex: Int? {
        guard case .point(let index, _) = self else { return nil }
        return index
    }

    /// The waypoint's identity, or `nil` for an open field.
    var stopID: UUID? {
        guard case .point(_, let id) = self else { return nil }
        return id
    }

    /// The rows for `waypoints`: two open fields over none, one open field
    /// beside a lone point — the start's, when `startIsOpen` says the point is
    /// the destination — and the points themselves from two on.
    static func rows(for waypoints: [TrailWaypoint], startIsOpen: Bool) -> [Self] {
        let points = waypoints.enumerated().map { Self.point(index: $0.offset, id: $0.element.id) }
        switch waypoints.count {
        case 0: return [.open(.start), .open(.end)]
        case 1: return startIsOpen ? [.open(.start)] + points : points + [.open(.end)]
        default: return points
        }
    }
}

/// A point under a finger: which one, and where it is right now.
///
/// The whole of the untracked channel this file's header describes. It carries
/// the waypoint's **place in the list** rather than its identity, because the
/// one thing that reads it is the map — which has the pins and the leg
/// polylines in that order and has to move the *n*th of each. The list cannot
/// change underneath a drag: the only thing that could change it is the sheet,
/// and the finger doing this is on the map.
nonisolated struct TrailWaypointDrag: Equatable, Sendable {
    let index: Int
    var latitude: Double
    var longitude: Double

    init(index: Int, coordinate: CLLocationCoordinate2D) {
        self.index = index
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The legs this point is an end of: the one arriving at it and the one
    /// leaving it, in leg indices. Both, either or neither will be in range —
    /// the first point has nothing arriving and the last has nothing leaving.
    var adjacentLegIndices: [Int] { [index - 1, index] }
}
