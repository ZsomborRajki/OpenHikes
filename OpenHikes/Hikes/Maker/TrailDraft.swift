//
//  TrailDraft.swift
//  OpenHikes
//
//  The trail being drawn, before it is a hike.
//
//  Every trail this app could show came from somewhere else — a recording is a
//  walk that already happened, a GPX is a file somebody sent, a listing is a
//  route somebody published, a curated row is an OpenStreetMap relation. This
//  is the one a hiker makes, and it lives here until Save turns it into an
//  ordinary ``Hike`` (see ``TrailDraftSave``). Nothing downstream of that save
//  learns a new kind of thing exists.
//
//  A stable `@Observable` reference type rather than view state, for the
//  reason ``RouteHighlight`` and ``RecordingTrace`` are: the map draws the
//  line and the pins, the list of waypoints is in a screen inside the sheet,
//  and the write that feeds both arrives from a tap on the map — which is a
//  view the sheet cannot see. Passing any of it up through the hierarchy would
//  make the root view a dependency of a screen two pushes down.
//
//  ## Points and legs are two lists, and the second is the one that is drawn
//
//  ``waypoints`` is what the hiker put down. ``legs`` is what runs between
//  them, and since Phase 2 that is not necessarily a straight line: a leg can
//  follow mapped paths, and its shape, its length and its state all belong to
//  it rather than to either point. So the line on the map, the length in the
//  header and the route a save writes are all read off the legs, and the
//  points are only what a pin is drawn at and what a row is named after.
//
//  **This type routes nothing.** It holds the shapes and the states;
//  ``TrailDraftController`` is what asks ``TrailLegRouting`` for them, for the
//  same reason it is what writes the draft down. A new leg is therefore born
//  straight and freehand, and is marked ``TrailLegSnap/routing`` in the same
//  turn the controller asks about it — which is what keeps a draft with no
//  router at all (a preview, a suite about the pill) from drawing a dashed
//  line nobody will ever answer for.
//
//  ## What is published, and what the next phase must not break
//
//  ``waypoints`` and ``legs`` are ordinary observed properties, so the map
//  tracks them with `withObservationTracking` exactly as `MapCommunityRoutes`
//  tracks `CommunityBrowser.routeLines`, and the maker's own list reads them
//  in a body. That is correct for as long as either only changes when a hiker
//  taps or an answer lands — which is all this phase does.
//
//  **A drag is the thing that breaks it, and it is the next phase's first
//  problem.** Dragging a pin writes at display rate, and a published array is
//  a body pass per frame for every reader of it. The shape that survives is
//  the one ``RecordingTrace`` uses: the moving point goes on its own
//  untracked channel with a revision beside it, the map reads that, and
//  ``waypoints`` keeps changing only when a drag *ends*. Do not widen these
//  properties into the drag; add the channel beside them.
//

import CoreLocation
import Foundation
import Observation

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

    init(latitude: Double, longitude: Double, id: UUID = UUID()) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
    }

    init(coordinate: CLLocationCoordinate2D, id: UUID = UUID()) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude, id: id)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The shape a saved route and a stored draft are both written in.
    var routeCoordinate: RouteCoordinate {
        RouteCoordinate(latitude: latitude, longitude: longitude)
    }
}

@Observable
final class TrailDraft {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// The points, in the order they were put down. See the file header for
    /// why this is published and what the drag phase has to do instead.
    private(set) var waypoints: [TrailWaypoint] = []

    /// What runs between them: one leg per point after the first, in the same
    /// order. Empty for a draft with fewer than two points.
    private(set) var legs: [TrailLeg] = []

    /// Whether legs should follow mapped paths.
    ///
    /// The hiker's setting rather than a fact about any one leg, which is why
    /// it lives here and is written down with the points: a draft resumed
    /// tomorrow is resumed the way it was being drawn. On by default, because
    /// a route that follows the ground is the answer nearly everybody wants
    /// and the one this feature exists to give.
    private(set) var snapsToPaths = true

    /// How far along the line each waypoint sits, in the order they were put
    /// down. Empty for an empty draft; `0` for the first point of any other.
    ///
    /// Stored, rather than each row measuring its own, because a list that
    /// asks every row to walk the line from the start is quadratic in the
    /// number of points — free at a dozen and not at a hundred, and a hundred
    /// is a long day's route drawn carefully. Measured once per change
    /// instead, which is one walk per tap.
    ///
    /// Measured along the **legs**, so a snapped leg contributes the length of
    /// the path it follows rather than the distance between its ends. That is
    /// the number on the screen and the number in the library.
    private(set) var distancesAlongLine: [Double] = []

    /// The line's length.
    ///
    /// The last element of the array above rather than a second sum of the
    /// same legs, which is what makes "the header and the last row say the
    /// same number" true by construction rather than by assertion.
    var distanceMeters: Double { distancesAlongLine.last ?? 0 }

    /// Whether there is a line here at all. One point is a place rather than a
    /// trail, which is why ``TrailDraftSave`` refuses it.
    var canBeSaved: Bool { waypoints.count > 1 }

    var isEmpty: Bool { waypoints.isEmpty }

    /// Where the pins go. The points themselves, never the resolved shape.
    var coordinates: [CLLocationCoordinate2D] {
        waypoints.map(\.clCoordinate)
    }

    /// The whole drawn line, flattened, in the shape a ``Hike`` is written in.
    ///
    /// The legs end to end with the duplicate joins dropped — each leg carries
    /// both of its endpoints, so the point where two legs meet is in the list
    /// twice before this runs. A single point is its own one-coordinate route,
    /// which ``TrailDraftSave`` refuses before it can be written.
    var routeCoordinates: [RouteCoordinate] {
        guard !legs.isEmpty else { return waypoints.map(\.routeCoordinate) }
        var flattened = legs[0].coordinates
        for leg in legs.dropFirst() {
            flattened.append(contentsOf: leg.coordinates.dropFirst())
        }
        return flattened
    }

    /// Whether any leg is waiting for an answer — what the header says while
    /// the line is settling.
    var isRouting: Bool {
        legs.contains(where: \.snap.isRouting)
    }

    /// What to say about the line as a whole, or `nil` when there is nothing
    /// to say.
    ///
    /// The worst thing any leg has to report, because a caption under a list
    /// is one line: a refusal outranks a gap, which outranks the routing that
    /// is merely in progress. A hiker with one busy leg and one trackless one
    /// is told about the busy one, because that is the one a tap can fix.
    var notice: TrailLegNotice? {
        if let refused = legs.first(where: \.snap.isRetryable) {
            return refused.snap.notice
        }
        if let gap = legs.first(where: \.snap.isDegraded) {
            return gap.snap.notice
        }
        return legs.first(where: \.snap.isRouting)?.snap.notice
    }

    /// Whether *Retry* has anything to do.
    var hasRetryableLegs: Bool {
        legs.contains(where: \.snap.isRetryable)
    }

    /// Appends a point at the end of the line.
    func append(_ coordinate: CLLocationCoordinate2D) {
        waypoints.append(TrailWaypoint(coordinate: coordinate))
        rebuildLegs()
    }

    /// Replaces the whole draft — what a restore from disk does, and nothing
    /// else does today.
    ///
    /// The points and the toggle are the whole of it: a drawn trail is named
    /// in the alert that saves it, so there is nothing else a restore could
    /// bring back. The resolved shapes are deliberately not among them — they
    /// are re-derivable, the graph they came from is on disk for a month, and
    /// storing a few hundred coordinates per leg to save a cache lookup would
    /// be writing down the answer to a question the disk already answers. See
    /// ``TrailDraftView``.
    func replace(with waypoints: [TrailWaypoint], snapsToPaths: Bool) {
        self.waypoints = waypoints
        legs = []
        setSnapsToPaths(snapsToPaths)
        rebuildLegs()
    }

    /// Empties the draft, which is what Cancel and a completed Save both leave
    /// behind. The toggle is a setting rather than part of the drawing, so it
    /// stays where the hiker left it.
    func clear() {
        guard !waypoints.isEmpty else { return }
        waypoints = []
        rebuildLegs()
    }

    /// Turns path-following on or off.
    ///
    /// Already-drawn legs are **re-resolved rather than discarded**, and that
    /// is ``TrailDraftController``'s half: this only records the setting and
    /// straightens what is on screen, so the line never sits claiming to
    /// follow paths the toggle has just switched off. Turning it back on
    /// costs nothing on the wire, because the router remembers what it
    /// answered — see ``OverpassTrailLegRouter``.
    func setSnapsToPaths(_ snapping: Bool) {
        guard snapsToPaths != snapping else { return }
        snapsToPaths = snapping
        if !snapping { straightenLegs() }
    }

    /// How far along the line a waypoint sits, for the row that names it.
    ///
    /// Answers rather than traps for an index that is not there: a row is
    /// rebuilt while the list is changing shape underneath it.
    func distanceAlongLine(toWaypointAt index: Int) -> Double {
        guard distancesAlongLine.indices.contains(index) else { return 0 }
        return distancesAlongLine[index]
    }

    /// The leg arriving at the waypoint at `index`, or `nil` for the first
    /// point, which nothing arrives at.
    func leg(arrivingAtWaypointAt index: Int) -> TrailLeg? {
        guard index > 0, legs.indices.contains(index - 1) else { return nil }
        return legs[index - 1]
    }

    // MARK: - Routing, driven from the controller

    /// The legs that want an answer and do not have one, in drawing order.
    ///
    /// - Parameter retryingRefusals: whether legs that were refused count as
    ///   wanting one. False for the ordinary pass a tap starts, true for
    ///   *Retry* — otherwise a refusal would be asked about again on every
    ///   subsequent tap, which is one extra request per point put down against
    ///   the server that has just said it is busy.
    func legsAwaitingRoutes(retryingRefusals: Bool) -> [TrailLegEnds] {
        guard snapsToPaths else { return [] }
        return legs.compactMap { leg in
            switch leg.snap {
            case .freehand: leg.ends
            case .refused: retryingRefusals ? leg.ends : nil
            case .routing, .snapped, .unmapped: nil
            }
        }
    }

    /// Marks these legs as waiting, which is what draws them dashed.
    ///
    /// Done in the same turn the question is asked, so a leg is never on
    /// screen as a settled straight line while an answer about it is in
    /// flight.
    func beginRouting(_ pending: [TrailLegEnds]) {
        let wanted = Set(pending)
        mutateLegs { leg in
            guard wanted.contains(leg.ends) else { return }
            leg.snap = .routing
        }
    }

    /// Takes an answer, if the leg it is about is still the leg that asked.
    ///
    /// Matched by ends rather than by index, because the list can have grown
    /// underneath the question: a hiker who puts down two more points while a
    /// leg is routing still gets that leg's answer, and a hiker who has turned
    /// snapping off in the meantime gets none, because the leg is no longer
    /// ``TrailLegSnap/routing``.
    func apply(_ route: TrailLegRoute, to ends: TrailLegEnds) {
        mutateLegs { leg in
            guard leg.ends == ends, leg.snap.isRouting else { return }
            leg.coordinates = route.coordinates
            leg.distanceMeters = route.distanceMeters
            leg.snap = route.snap
        }
    }

    /// Gives up on one leg that was being asked about, leaving it the
    /// straight line it already is.
    ///
    /// What a cancelled question comes to. Cancellation is not a failure and
    /// must not be drawn as one — but the leg cannot be left waiting either,
    /// because a leg that is waiting is never asked about again and would
    /// stay dashed for the rest of the drawing. Dropped back to freehand
    /// instead, so the next pass picks it up.
    func abandonRouting(of ends: TrailLegEnds) {
        mutateLegs { leg in
            guard leg.ends == ends, leg.snap.isRouting else { return }
            leg.snap = .freehand
        }
    }

    /// Gives up on legs still waiting, leaving them the straight lines they
    /// already are — what the maker closing does, so a draft resumed later
    /// does not come back dashed forever.
    func stopRouting() {
        mutateLegs { leg in
            guard leg.snap.isRouting else { return }
            leg.snap = .freehand
        }
    }

    // MARK: - Private

    /// One leg per adjacent pair, keeping whatever has already been resolved.
    ///
    /// Reuse is keyed on ``TrailLegEnds`` — the two places, not the two
    /// waypoints — so a leg whose geometry did not change keeps its shape and
    /// its state through a change to the list around it. That is what makes
    /// appending a point cost one question rather than all of them, and it is
    /// what Phase 3's reorder will need from this phase.
    private func rebuildLegs() {
        var resolved: [TrailLegEnds: TrailLeg] = [:]
        for leg in legs { resolved[leg.ends] = leg }
        var rebuilt: [TrailLeg] = []
        rebuilt.reserveCapacity(max(0, waypoints.count - 1))
        for (previous, next) in zip(waypoints, waypoints.dropFirst()) {
            let ends = TrailLegEnds(from: previous, to: next)
            if var existing = resolved[ends] {
                existing.id = next.id
                rebuilt.append(existing)
            } else {
                rebuilt.append(TrailLeg.straight(arrivingAt: next.id, along: ends))
            }
        }
        publish(rebuilt)
    }

    /// Drops every leg back to the straight line between its ends. What
    /// turning the toggle off does.
    private func straightenLegs() {
        mutateLegs { leg in
            leg.coordinates = leg.ends.straightCoordinates
            leg.distanceMeters = leg.ends.straightDistanceMeters
            leg.snap = .freehand
        }
    }

    /// Runs `change` over every leg and publishes the result if anything moved.
    ///
    /// One write to ``legs`` rather than one per leg, because each is an
    /// observation the map and the list both act on — and because a
    /// same-value write is filtered only for an `Equatable` value, which is
    /// what the array of legs is (see *Render isolation, in practice*).
    private func mutateLegs(_ change: (inout TrailLeg) -> Void) {
        var changed = legs
        for index in changed.indices { change(&changed[index]) }
        publish(changed)
    }

    private func publish(_ rebuilt: [TrailLeg]) {
        if legs != rebuilt { legs = rebuilt }
        remeasure()
    }

    private func remeasure() {
        let measured = Self.distances(along: legs, pointCount: waypoints.count)
        guard distancesAlongLine != measured else { return }
        distancesAlongLine = measured
    }

    /// One running total per waypoint, in one walk of the legs.
    private static func distances(along legs: [TrailLeg], pointCount: Int) -> [Double] {
        guard pointCount > 0 else { return [] }
        var distances: [Double] = [0]
        distances.reserveCapacity(pointCount)
        var total: Double = 0
        for leg in legs {
            total += leg.distanceMeters
            distances.append(total)
        }
        return distances
    }
}
