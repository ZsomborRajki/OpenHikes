//
//  TrailLeg.swift
//  OpenHikes
//
//  One stretch of the drawn line, and what happened when it was asked to
//  follow a real path.
//
//  Phase 1 drew a trail as a list of points and the straight lines between
//  them. A hiker planning a walk does not walk straight lines, so a leg is now
//  a thing in its own right: it has a shape that is not necessarily its two
//  endpoints, a length that is not necessarily the distance between them, and
//  a state that says which of those it is and why.
//
//  ## Why the state is five cases and not a Boolean
//
//  *Snapped or not* is the question the toggle asks, and it is the wrong
//  question to store. A straight leg can be straight for four different
//  reasons — the hiker turned snapping off, the answer has not come back yet,
//  OpenStreetMap has nothing mapped between these two points, or Overpass
//  refused to answer — and only the last is a failure. Flattening them would
//  put the warning glyph on a hiker's own deliberate choice and put nothing at
//  all on a leg that is silently waiting. That is the same flattening
//  ``CuratedTrailNotice`` exists to undo one feature over, which is why the
//  refusal case carries that feature's ``CuratedTrailOutage`` rather than a
//  second spelling of the same three answers.
//
//  **Nothing here may ever block drawing.** Every case draws a line, has a
//  length and counts towards the total. A leg that could not be routed is a
//  leg the hiker can save, export and walk; it simply did not get the extra
//  the route would have added. Overpass rate limits have been hit in the
//  field, and an editor that stops working when a volunteer-run API is busy is
//  an editor that stops working.
//

import CoreLocation
import Foundation

/// The two ends of one leg, which is what a resolved shape is looked up by.
///
/// Coordinates rather than the waypoints' identities, and that is what makes
/// the cache in ``OverpassTrailLegRouter`` worth having: the answer to *what
/// path runs between these two places* does not change when the points either
/// side of them are renumbered. A reorder, an insert and a delete all leave
/// most legs geometrically untouched, so most legs come back from the cache —
/// which is the whole of what Phase 3 needs from this phase.
///
/// ``RouteCoordinate`` rather than a pair of `CLLocationCoordinate2D`, for the
/// reason ``TrailWaypoint`` stores its own that way: MapKit's coordinate is
/// neither `Equatable` nor `Hashable`, and this type is a dictionary key.
nonisolated struct TrailLegEnds: Hashable, Sendable {
    let start: RouteCoordinate
    let end: RouteCoordinate

    init(from start: TrailWaypoint, to end: TrailWaypoint) {
        self.start = start.routeCoordinate
        self.end = end.routeCoordinate
    }

    init(start: RouteCoordinate, end: RouteCoordinate) {
        self.start = start
        self.end = end
    }

    /// The same two places, the other way round.
    ///
    /// A walking path between two points is the same path whichever way it is
    /// walked, which is what lets ``TrailDraft/reverse()`` turn a whole trail
    /// round without asking OpenStreetMap anything. The pair is still ordered,
    /// and deliberately: a leg's stored shape runs from its start to its end,
    /// so a key that ignored direction would hand a reversed leg a shape drawn
    /// backwards.
    var flipped: Self { Self(start: end, end: start) }

    var startCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)
    }

    var endCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: end.latitude, longitude: end.longitude)
    }

    /// The straight line between them, which is what every leg falls back to.
    var straightCoordinates: [RouteCoordinate] { [start, end] }

    var straightDistanceMeters: Double {
        RouteGeometry.distanceMeters(from: startCoordinate, to: endCoordinate)
    }
}

/// Why a leg that was asked to follow a path is not following one.
///
/// Both of these are *answers* rather than failures, which is why they are
/// separated from ``TrailLegSnap/refused(_:)``: OpenStreetMap was reached and
/// there is nothing here to follow. Nothing is broken and waiting will not
/// help, so neither wears the warning glyph — the same distinction
/// ``CuratedTrailNotice`` draws between an empty area and a busy server.
nonisolated enum TrailLegGap: Equatable, Sendable {
    /// Neither end is near anything mapped, or nothing mapped joins them.
    ///
    /// One case for both because a hiker cannot act on the difference: a leg
    /// across a trackless corrie and a leg between two paths that do not meet
    /// are the same line on the same screen, and naming which would be a
    /// sentence about the graph rather than about the walk.
    case noPathBetween
    /// The two points are further apart than one leg may ask about — see
    /// ``OverpassTrailLegRouter/maximumLegMeters``.
    case tooFarApart
}

/// What one leg of the drawn line currently is.
nonisolated enum TrailLegSnap: Equatable, Sendable {
    /// A straight line, because the hiker asked for one. The toggle is off.
    case freehand
    /// Overpass could not be asked. Carries the same three answers the
    /// curated work already reads out of a failed Overpass call.
    case refused(CuratedTrailOutage)
    /// A route has been asked for and has not come back. Drawn dashed.
    case routing
    /// It follows mapped paths.
    case snapped
    /// It was asked, and there is nothing to follow.
    case unmapped(TrailLegGap)

    /// Whether this leg is still waiting for an answer, which is what the map
    /// draws as a dashed line and what keeps a second request for the same
    /// leg from being started beside the first.
    var isRouting: Bool { self == .routing }

    /// Whether asking again could change this. Only a refusal could: the
    /// other four are either the hiker's own choice or an answer.
    var isRetryable: Bool {
        if case .refused = self { return true }
        return false
    }

    /// Whether the line is drawn as a settled straight line rather than as a
    /// path it followed — which the map needs to know because *straight
    /// because I asked for it* and *straight because nobody could route it*
    /// are not the same line.
    var isDegraded: Bool {
        switch self {
        case .freehand, .routing, .snapped: false
        case .refused, .unmapped: true
        }
    }

    /// One short line about this leg, or `nil` when there is nothing worth
    /// saying.
    ///
    /// `nil` for the two cases that worked: a snapped leg is what the toggle
    /// promised and a freehand leg is what the toggle says it is, and a label
    /// on either would be a label on a working screen — the reason
    /// ``CuratedTrailOutcome/notice`` answers `nil` for trails that arrived.
    var notice: TrailLegNotice? {
        switch self {
        case .freehand, .snapped:
            nil
        case .refused(let outage):
            TrailLegNotice(
                text: outage.text,
                symbolName: "exclamationmark.triangle.fill",
                isWarning: true
            )
        case .routing:
            TrailLegNotice(
                text: String(localized: "Finding a path…"),
                symbolName: "point.topleft.down.to.point.bottomright.curvepath",
                isWarning: false
            )
        case .unmapped(.noPathBetween):
            TrailLegNotice(
                text: String(localized: "No mapped path here"),
                symbolName: "mappin.slash",
                isWarning: false
            )
        case .unmapped(.tooFarApart):
            TrailLegNotice(
                text: String(localized: "Too far apart to follow a path"),
                symbolName: "mappin.slash",
                isWarning: false
            )
        }
    }
}

/// What to say about a leg, and how to draw the saying of it.
///
/// The same three fields ``CuratedTrailNotice`` publishes, for the same reason
/// and in the same shape: the glyph is the whole of the difference at a
/// glance, and whether it is a warning is what decides its colour. A struct
/// rather than a second enumeration because the cases it would have are
/// already ``TrailLegSnap``'s.
nonisolated struct TrailLegNotice: Equatable, Sendable {
    let text: String
    let symbolName: String
    /// Orange and a triangle, or neither. See ``CuratedTrailNotice/isWarning``.
    let isWarning: Bool
}

/// One stretch of the drawn line, between two consecutive waypoints.
nonisolated struct TrailLeg: Identifiable, Equatable, Sendable {
    /// The waypoint this leg **arrives at**.
    ///
    /// There is one leg per point after the first, so the arriving point names
    /// it — which is also where a list row draws it, because the row that
    /// shows how far along point *n* sits is the row the leg into point *n*
    /// belongs on.
    ///
    /// `var` because a leg is reused across a change to the list: the two
    /// places it runs between are what identify it, so a leg that survives a
    /// change is retargeted at whichever waypoint now arrives at its end
    /// rather than rebuilt from scratch. See ``TrailDraft``'s `rebuildLegs`.
    var id: UUID
    /// Where it runs between. What a resolved shape is cached by, and what an
    /// answer arriving late is matched against.
    let ends: TrailLegEnds
    /// The shape actually drawn, both endpoints included. Never fewer than
    /// two: a leg with nothing resolved is its own straight line.
    var coordinates: [RouteCoordinate]
    /// Measured along ``coordinates`` rather than between the ends, so the
    /// header, the rows and the saved hike are all the length of the line the
    /// hiker is looking at.
    var distanceMeters: Double
    var snap: TrailLegSnap

    /// The same leg, walked the other way.
    ///
    /// The shape reversed and the two ends swapped, so a reversed trail is
    /// drawn from the geometry it already has rather than asked for again —
    /// see ``TrailDraft/reverse()``. The length and the state are properties
    /// of the stretch rather than of the direction, so both survive; the
    /// identity does not, because a leg is named by the waypoint it arrives at
    /// and that is the other one now. `rebuildLegs` retargets it.
    func flipped() -> Self {
        Self(
            id: id,
            ends: ends.flipped,
            coordinates: coordinates.reversed(),
            distanceMeters: distanceMeters,
            snap: snap
        )
    }

    /// A leg that follows nothing yet.
    ///
    /// Every leg starts here, including one about to be routed: the controller
    /// marks it ``TrailLegSnap/routing`` in the same turn it asks, so there is
    /// no frame in which a new leg is dashed before anybody has asked
    /// anything. A draft with no router — a preview, a suite about the pill —
    /// simply leaves them all like this.
    static func straight(arrivingAt id: UUID, along ends: TrailLegEnds) -> Self {
        Self(
            id: id,
            ends: ends,
            coordinates: ends.straightCoordinates,
            distanceMeters: ends.straightDistanceMeters,
            snap: .freehand
        )
    }
}

/// A resolved leg: what the router came back with.
///
/// Its own type rather than a ``TrailLeg``, because the router knows nothing
/// about which waypoint a leg arrives at or where it sits in a list — it is
/// asked a question about two places and answers it. That is also what lets
/// an answer be applied to whichever leg still has those two ends when it
/// lands, rather than to the index it was asked about.
nonisolated struct TrailLegRoute: Equatable, Sendable {
    var coordinates: [RouteCoordinate]
    var distanceMeters: Double
    var snap: TrailLegSnap

    /// The straight line between `ends`, in `snap`. What every refusal and
    /// every gap answers with, because a leg always draws something.
    static func straight(along ends: TrailLegEnds, _ snap: TrailLegSnap) -> Self {
        Self(
            coordinates: ends.straightCoordinates,
            distanceMeters: ends.straightDistanceMeters,
            snap: snap
        )
    }
}
