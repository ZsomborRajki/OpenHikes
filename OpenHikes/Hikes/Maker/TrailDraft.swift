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
//  ## What is published, and what a drag does instead
//
//  ``waypoints`` and ``legs`` are ordinary observed properties, so the map
//  tracks them with `withObservationTracking` exactly as `MapCommunityRoutes`
//  tracks `CommunityBrowser.routeLines`, and the maker's own list reads them
//  in a body. That is correct because both only change when a hiker finishes
//  doing something — a tap, a delete, a drop — or when an answer lands.
//
//  **A drag is the thing that would break it**, and since Phase 3 there is
//  one: dragging a pin writes at display rate, and a published array is a body
//  pass per frame for every reader of it. So the moving point goes on its own
//  untracked channel — ``drag``, with ``dragRevision`` beside it — in the
//  shape ``RecordingTrace`` uses: the map reads the pair and moves one pin and
//  at most two lines, the sheet's list reads neither and is not rebuilt at
//  all, and ``waypoints`` changes exactly once, when the finger lifts. Do not
//  widen these properties into the drag.
//
//  ## Places are the other list, and they have no rank
//
//  ``places`` is what is *on* the trail rather than what it goes through — a
//  spring, a saddle, the hut at the col. It is a second list and deliberately
//  not a second kind of waypoint: a waypoint is the third place the line goes,
//  and a place is a spot on the ground that happens to be near it. So nothing
//  numbers them, nothing reorders them, and where each one sits along the line
//  is derived from the line by ``rankPlaces()`` rather than stored. A leg that
//  snaps through a valley moves every place's distance without a hiker having
//  touched one. See ``TrailPlace``.
//
//  ## Undo, and the one thing that is not snapshotted
//
//  Every operation below records the drawing — the points *and* the places —
//  before it changes it, into ``TrailDraftHistory``. What is *not* in a snapshot is the resolved leg
//  shapes: they are far larger than the points and they are re-derivable, so
//  they are remembered once, by their two ends, in ``TrailLegMemo`` — which
//  `rebuildLegs` consults. That is what makes undo restore the line rather
//  than redraw it straight and ask for it again, and it does the same for a
//  reorder, a delete and a point dragged away and back.
//

import CoreLocation
import Foundation
import Observation

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
    private(set) var travelMode: TrailTravelMode = .hiking

    /// Whether the one point in a one-point draft is the **destination**, with
    /// the start field still open.
    ///
    /// The one extra fact two empty fields need: with none or two-plus points
    /// every row's role follows from its place in the list, and with exactly one
    /// it does not — a hiker who fills *Destination* first has a point that is
    /// not a start. False whenever the count is anything but one, so there is
    /// no stale answer lying about for the next time it is.
    private(set) var startIsOpen = false

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

    /// The places marked along this trail, in the order they were marked.
    ///
    /// The order they were *marked* rather than the order they are met, and
    /// that is not the list a screen draws: ``placeRows`` is. A place has no
    /// rank — it is a spot on the ground — so the only stable order this list
    /// can have is the one nothing else depends on, and where a place sits
    /// along the line is derived from the line rather than stored beside it.
    /// Which means an edit to the route reorders the places for free, and a
    /// place that was marked before there was a line at all is still here to
    /// be measured once there is one.
    private(set) var places: [TrailPlace] = []

    /// The same places in the order they are met walking the line, each with
    /// how far along it sits.
    ///
    /// Stored rather than computed on read, for the reason
    /// ``distancesAlongLine`` is: a snapped trail is thousands of coordinates
    /// and this projects every place onto every segment of it, which is fine
    /// once per edit and is not fine once per body pass. Recomputed by
    /// ``remeasure()``, so it moves when either the line or the places do.
    private(set) var placeRows: [TrailPlaceRow] = []

    /// The point currently under a finger, or `nil` when none is.
    ///
    /// **Untracked, deliberately** — see the file header. Read beside
    /// ``dragRevision``, which is the observed half and the only thing that
    /// says it moved.
    @ObservationIgnored private(set) var drag: TrailWaypointDrag?

    /// Bumped whenever ``drag`` is set, moved or let go.
    ///
    /// An `Int` rather than publishing the drag itself, so the map's
    /// `withObservationTracking` has one cheap thing to watch and nothing that
    /// reads a coordinate is tracked. Nothing in a SwiftUI body may read this.
    private(set) var dragRevision = 0

    /// The steps back. Observed, so the two controls that offer them appear
    /// and go with the line.
    private var history = TrailDraftHistory()

    /// The settled leg shapes this drawing has been given, by their two ends.
    ///
    /// Untracked: it is consulted while legs are being rebuilt and is never
    /// drawn, so publishing it would be a body pass for a cache write. See
    /// ``TrailLegMemo``.
    @ObservationIgnored private var memo = TrailLegMemo()

    /// The line's length.
    ///
    /// The last element of the array above rather than a second sum of the
    /// same legs, which is what makes "the header and the last row say the
    /// same number" true by construction rather than by assertion.
    var distanceMeters: Double { distancesAlongLine.last ?? 0 }

    /// Whether there is a line here at all. One point is a place rather than a
    /// trail, which is why ``TrailDraftSave`` refuses it.
    ///
    /// Read off ``slots`` rather than the points — the same answer, because a
    /// line is exactly a draft with no field left open — so the screens that
    /// ask are not woken by a stop being named or moved.
    var canBeSaved: Bool { !slots.contains { $0.waypointIndex == nil } }

    /// Whether there is nothing here at all — no line and no places.
    ///
    /// Both halves, because this is what decides whether the durable draft is
    /// worth keeping and whether Cancel has anything to ask about. A hiker who
    /// found the huts before drawing anything has done work, and a Cancel that
    /// threw it away without asking would be the same loss a cleared line is.
    var isEmpty: Bool { waypoints.isEmpty && places.isEmpty }

    /// The drawing as one value: what a step of undo remembers, and what a
    /// restore puts back. See ``TrailDraftContents``.
    var contents: TrailDraftContents {
        TrailDraftContents(waypoints: waypoints, places: places, startIsOpen: startIsOpen)
    }

    /// The route list's rows: two open fields over an empty draft, one open
    /// field beside a lone point, and the points themselves from two on.
    ///
    /// **Stored, and written only when a row comes or goes** — never when a
    /// point is named or moved. The maker's screen builds its list from this,
    /// and every row is keyed by a point's identity, so a name landing, a drag
    /// and a searched place filling a row change no row at all. Derived from
    /// ``waypoints`` instead, each of those rebuilt the whole screen to find
    /// that nothing had come or gone. The rows read what did change
    /// themselves — see ``TrailStopRowView``.
    private(set) var slots = TrailStopSlot.rows(for: [], startIsOpen: false)

    /// The whole line's time at this mode's pace, or Apple Maps' where it said.
    var travelTime: TimeInterval {
        legs.reduce(0) { $0 + travelTime(of: $1.path) }
    }

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

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// Whether joining the end back to the start would change anything.
    ///
    /// False for a line that already ends where it began, which is what stops
    /// *Close the Loop* from stacking a second zero-length leg on a loop that
    /// is already closed.
    var canCloseTheLoop: Bool {
        guard let first = waypoints.first, let last = waypoints.last,
              waypoints.count > 1 else { return false }
        return first.latitude != last.latitude || first.longitude != last.longitude
    }

    /// Appends a point at the end of the line.
    ///
    /// - Parameter name: what it is called, for a point that arrives already
    ///   named — a place picked out of the search sheet. Empty for a tap on the
    ///   map, which is named afterwards or not at all; see
    ///   ``TrailWaypoint/name``.
    func append(_ coordinate: CLLocationCoordinate2D, named name: String = "") {
        history.record(contents)
        waypoints.append(TrailWaypoint(coordinate: coordinate, name: name))
        startIsOpen = false
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
    /// A different drawing, so the steps behind the last one go with it — an
    /// undo that reached back past a restore would offer a line from a
    /// session that has ended.
    func replace(
        with waypoints: [TrailWaypoint],
        places: [TrailPlace],
        snapsToPaths: Bool,
        travelMode: TrailTravelMode = .hiking,
        startIsOpen: Bool = false
    ) {
        cancelDrag()
        history.forget()
        self.waypoints = waypoints
        self.places = places
        self.travelMode = travelMode
        self.startIsOpen = waypoints.count == 1 && startIsOpen
        memo = TrailLegMemo()
        legs = []
        setSnapsToPaths(snapsToPaths)
        rebuildLegs()
    }

    /// Empties the draft, which is what Cancel and a completed Save both leave
    /// behind. The toggle is a setting rather than part of the drawing, so it
    /// stays where the hiker left it.
    ///
    /// **Not undoable, and that is the difference from ``clearDrawing()``.**
    /// This is the drawing ending — the hiker cancelled, or it has become a
    /// hike — so the steps behind it and the shapes remembered for it go too.
    /// *Clear* on the maker's own menu is a thing done *to* a drawing that is
    /// still open, and takes a step like every other edit.
    func clear() {
        cancelDrag()
        history.forget()
        memo = TrailLegMemo()
        guard !isEmpty else { return }
        waypoints = []
        places = []
        startIsOpen = false
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

    /// A mode owns its shapes. Undo keeps the current mode and resolves its legs anew.
    func setTravelMode(_ mode: TrailTravelMode) {
        guard travelMode != mode else { return }
        cancelDrag()
        travelMode = mode
        memo = TrailLegMemo()
        straightenLegs()
    }

    /// How far along the line a waypoint sits, for the row that names it.
    ///
    /// Answers rather than traps for an index that is not there: a row is
    /// rebuilt while the list is changing shape underneath it.
    func distanceAlongLine(toWaypointAt index: Int) -> Double {
        guard distancesAlongLine.indices.contains(index) else { return 0 }
        return distancesAlongLine[index]
    }

    /// What the point at `index` is to this route — see ``TrailStopRole``.
    ///
    /// Answers for an index that is not there rather than trapping, for the
    /// reason above: these are read by rows of a list that is being rebuilt
    /// underneath them.
    func role(ofWaypointAt index: Int) -> TrailStopRole {
        if waypoints.count == 1, startIsOpen { return .end }
        return TrailStopRole.of(waypointAt: index, in: waypoints.count)
    }

    /// How long a path takes: Apple Maps' estimate when it gave one, and this
    /// mode's pace over the distance otherwise.
    func travelTime(of path: TrailLegPath) -> TimeInterval {
        path.travelTime ?? path.distanceMeters / travelMode.paceMetersPerSecond
    }

    /// What the point at `index` is called, or empty for one nothing has
    /// named.
    func name(ofWaypointAt index: Int) -> String {
        guard waypoints.indices.contains(index) else { return "" }
        return waypoints[index].name
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
            case .refused, .directionsUnavailable: retryingRefusals ? leg.ends : nil
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
            leg.travelTime = route.travelTime
            leg.alternatives = route.alternatives
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
    /// appending a point cost one question rather than all of them.
    ///
    /// Two places are looked in, in this order: the legs currently drawn, and
    /// then ``memo`` for the ones an edit has already taken out of that list.
    /// The second is the whole of what an undo, a reorder and a delete need —
    /// see ``TrailLegMemo`` — and it is consulted **only while the toggle is
    /// on**, because a remembered leg is a snapped one and handing it back to
    /// a hiker who has turned path-following off would put a path on a line
    /// they asked to be straight.
    ///
    private func rebuildLegs() {
        rebuildLegs(reusing: legs)
    }

    /// - Parameter reusable: the legs to match against. The legs as they stand
    ///   for every caller but one: ``reverse()`` has already turned each of
    ///   them round, and matching against the published list would find none
    ///   of them.
    private func rebuildLegs(reusing reusable: [TrailLeg]) {
        var resolved: [TrailLegEnds: TrailLeg] = [:]
        for leg in reusable { resolved[leg.ends] = leg }
        var rebuilt: [TrailLeg] = []
        rebuilt.reserveCapacity(max(0, waypoints.count - 1))
        for (previous, next) in zip(waypoints, waypoints.dropFirst()) {
            let ends = TrailLegEnds(from: previous, to: next)
            if var existing = resolved[ends] {
                existing.id = next.id
                rebuilt.append(existing)
            } else if snapsToPaths, let remembered = memo.leg(ends, arrivingAt: next.id) {
                rebuilt.append(remembered)
            } else {
                rebuilt.append(TrailLeg.straight(arrivingAt: next.id, along: ends))
            }
        }
        refreshSlots()
        publish(rebuilt)
    }

    /// Brings ``slots`` up to the points and the open field. Every edit that
    /// can add, remove or reorder a point ends in `rebuildLegs`, which is
    /// where this is called; the one that changes only the open field —
    /// reversing a lone point — calls it itself.
    private func refreshSlots() {
        let rows = TrailStopSlot.rows(for: waypoints, startIsOpen: startIsOpen)
        if slots != rows { slots = rows }
    }

    /// Puts the waypoint list back to something the history handed over.
    ///
    /// The legs are rebuilt rather than restored, because the memo above holds
    /// every shape this drawing has settled and the list is what says which of
    /// them apply. See ``TrailDraftHistory`` for why a step is a list of points
    /// and not a list of shapes.
    private func restore(_ restored: TrailDraftContents) {
        cancelDrag()
        waypoints = restored.waypoints
        places = restored.places
        startIsOpen = restored.waypoints.count == 1 && restored.startIsOpen
        rebuildLegs()
    }

    /// Drops every leg back to the straight line between its ends. What
    /// turning the toggle off does.
    private func straightenLegs() {
        mutateLegs { leg in
            leg.coordinates = leg.ends.straightCoordinates
            leg.distanceMeters = leg.ends.straightDistanceMeters
            leg.snap = .freehand
            leg.travelTime = nil
            leg.alternatives = []
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
        // Remembered before the comparison rather than after it: a republish
        // of the same legs is not news to the map, but it is the pass that
        // follows a straightened leg being answered again, and the memo has
        // to see every settled shape exactly once whether or not the array
        // moved.
        memo.remember(rebuilt)
        if legs != rebuilt { legs = rebuilt }
        remeasure()
    }

    private func remeasure() {
        let measured = Self.distances(along: legs, pointCount: waypoints.count)
        if distancesAlongLine != measured { distancesAlongLine = measured }
        rankPlaces()
    }

    /// Puts the places back in the order the line meets them.
    ///
    /// Called from ``remeasure()`` rather than from the place operations, so
    /// that an edit to the *route* re-ranks them too: a leg that snapped
    /// through a valley moves every place's distance along the line without
    /// anything having been marked or moved.
    ///
    /// Measured against the resolved line — ``routeCoordinates`` — rather than
    /// against the waypoints, so the figure beside a place is the same one the
    /// header and the saved hike carry.
    private func rankPlaces() {
        // Guarded rather than left to ``TrailPlaceOrder/ordered(_:along:)``'s
        // own empty case, because what is avoided is *building the argument*:
        // ``routeCoordinates`` flattens every leg into a fresh array, which on
        // a snapped trail is thousands of coordinates, and a hiker who has
        // marked nothing — most of them, most of the time — would pay for it
        // on every tap and on every leg that lands. The same guard
        // ``TrailDraftController/commit()`` makes in front of the finder's
        // re-rank, for the same reason.
        guard !places.isEmpty else {
            if !placeRows.isEmpty { placeRows = [] }
            return
        }
        let ranked = TrailPlaceOrder.ordered(places, along: routeCoordinates)
        guard placeRows != ranked else { return }
        placeRows = ranked
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

// MARK: - Editing

/// The six things a hiker can do to a line that is already drawn, and the two
/// ways back.
///
/// A same-file extension rather than more of the class body, for the reason
/// `OpenHikesView` took the same way out: `type_body_length` is a limit on a
/// body and an extension is not one. Same file, because every one of these
/// ends in `rebuildLegs()`, which is `private` — and `private` is file-scoped.
///
/// **Every one of them records a step first**, with the list as it stands,
/// which is what makes undo a property of the type rather than something each
/// caller has to remember. The ones that would change nothing return before
/// recording, so *Undo* never offers to put a line back the way it already is.
extension TrailDraft {
    /// Moves one point to a new place. What a drag commits.
    ///
    /// **The name does not travel with it**, and that is the decision rather
    /// than an omission: a point called "Lurdy Ház" that has been dragged half
    /// a kilometre up the hill is not at Lurdy Ház any more, and a row still
    /// saying so would be the one thing on this screen that lies about where
    /// the line goes. The point goes back to its role's word, and
    /// ``TrailStopNaming`` says what is at the new spot a moment later — which
    /// is exactly what a fresh tap on the map gets, because a point dropped
    /// somewhere and a point dragged there are the same point.
    ///
    /// Use ``place(waypointAt:at:named:)`` for a move that *does* know what it
    /// is moving to.
    func move(waypointAt index: Int, to coordinate: CLLocationCoordinate2D) {
        place(waypointAt: index, at: coordinate, named: "")
    }

    /// Moves one point to a named place. What picking a search result for a row
    /// that already has a point commits.
    ///
    /// The one verb that writes a coordinate and a name together, and both
    /// halves are the hiker's choice — so unlike ``describe(waypointAt:as:)``
    /// this takes a step of undo like every other edit here.
    func place(
        waypointAt index: Int,
        at coordinate: CLLocationCoordinate2D,
        named name: String
    ) {
        guard waypoints.indices.contains(index) else { return }
        let moved = TrailWaypoint(
            coordinate: coordinate,
            id: waypoints[index].id,
            name: name
        )
        guard moved != waypoints[index] else { return }
        history.record(contents)
        waypoints[index] = moved
        rebuildLegs()
    }

    /// Writes what something else worked out a point is called.
    ///
    /// **Not a step of undo, and not a change to the line.** This is
    /// ``TrailStopNaming``'s answer landing a second after a tap — a
    /// description of a point the hiker has already put down, not an edit they
    /// made — so offering to undo it would put *Undo* on the menu for something
    /// nobody did, and would put the tap that drew the point one step further
    /// away. Nothing geometric moves, so no leg is asked about again.
    ///
    /// **By identity rather than by place in the list**, for the reason
    /// ``apply(_:to:)`` matches a leg by its two ends: this answer was asked
    /// for a second ago, and a hiker who has reordered, inserted or deleted
    /// since would otherwise have the name of one point written onto another.
    ///
    /// Refused for a point that has already been named, which is what keeps a
    /// late answer from overwriting a place the hiker picked themselves while
    /// it was in flight, and for a point that has gone.
    func describe(waypointWith id: UUID, as name: String) {
        guard !name.isEmpty,
              let index = waypoints.firstIndex(where: { $0.id == id }),
              waypoints[index].name.isEmpty else { return }
        waypoints[index].name = name
    }

    /// Puts a point into the middle of a leg, at the place that was tapped.
    ///
    /// After the leg's *start*, which is the whole of what makes this an
    /// insert rather than an append: leg *n* runs from waypoint *n* to
    /// waypoint *n + 1*, so the new point takes index *n + 1* and the leg
    /// becomes two.
    func insert(
        _ coordinate: CLLocationCoordinate2D,
        intoLegAt index: Int,
        named name: String = ""
    ) {
        guard legs.indices.contains(index) else { return }
        history.record(contents)
        waypoints.insert(
            TrailWaypoint(coordinate: coordinate, name: name),
            at: index + 1
        )
        rebuildLegs()
    }

    /// Takes points out of the line. What the delete control on a row does.
    ///
    /// A route cut down to one point keeps that point in the field it was in:
    /// delete the start of a two-point route and what is left is still the
    /// destination, with the start field open again — as in Apple Maps.
    func remove(atOffsets offsets: IndexSet) {
        let kept = waypoints.enumerated().filter { !offsets.contains($0.offset) }
        guard kept.count != waypoints.count else { return }
        history.record(contents)
        let wasDestination = kept.count == 1 && role(ofWaypointAt: kept[0].offset) == .end
        waypoints = kept.map(\.element)
        startIsOpen = wasDestination
        rebuildLegs()
    }

    /// Puts a stop where it belongs: into an open field while there is one —
    /// the start first — and otherwise into the leg nearest to it.
    ///
    /// What the map's place sheet does, so a tap that meant "on the way" never
    /// silently becomes a new destination.
    ///
    /// - Parameter preferredLeg: the leg a thumb landed on, which wins over the
    ///   nearest one where a trail doubles back. Ignored when out of range.
    func addStop(
        _ coordinate: CLLocationCoordinate2D,
        named name: String = "",
        preferringLeg preferredLeg: Int? = nil
    ) {
        guard !fillOpenField(with: coordinate, named: name) else { return }
        let leg = preferredLeg.flatMap { legs.indices.contains($0) ? $0 : nil }
            ?? nearestLegIndex(to: coordinate)
        guard let leg else { return }
        insert(coordinate, intoLegAt: leg, named: name)
    }

    /// Fills the first open field — the start, then the destination — and
    /// answers whether there was one.
    @discardableResult func fillOpenField(
        with coordinate: CLLocationCoordinate2D,
        named name: String = ""
    ) -> Bool {
        guard case .open(let role) = slots.first(where: { $0.waypointIndex == nil }) else { return false }
        fill(role, with: coordinate, named: name)
        return true
    }

    /// Fills the open start or destination field. Does nothing when that field
    /// is not open — a filled end is changed through its own row instead.
    func fill(
        _ role: TrailStopRole,
        with coordinate: CLLocationCoordinate2D,
        named name: String = ""
    ) {
        guard slots.contains(.open(role)) else { return }
        history.record(contents)
        let point = TrailWaypoint(coordinate: coordinate, name: name)
        if role == .start {
            waypoints.insert(point, at: 0)
        } else {
            waypoints.append(point)
        }
        startIsOpen = waypoints.count == 1 && role == .end
        rebuildLegs()
    }

    /// Reorders the line. What a drag in the list's edit mode commits.
    ///
    /// This is the operation the list earns its place with: it is how a hiker
    /// fixes a route built in the wrong direction, and how a point is pulled
    /// back out of a detour that was not meant.
    func moveWaypoints(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let reordered = Self.moving(waypoints, from: offsets, to: destination)
        guard reordered != waypoints else { return }
        history.record(contents)
        waypoints = reordered
        rebuildLegs()
    }

    /// Walks the line the other way.
    ///
    /// Hiking reuses its undirected graph shapes. Other modes must route the
    /// ordered endpoints again, because access can depend on direction.
    /// Every hiking leg already has its shape; reversing
    /// the trail turns each of them round, which is the array reversed and
    /// each leg's own coordinates reversed with its two ends swapped. A route
    /// between two places is the same path walked either way, so this is exact
    /// rather than an approximation of a fresh answer — see
    /// ``TrailLeg/flipped()``.
    ///
    /// The flipped legs are handed to `rebuildLegs` rather than published
    /// directly, because their identities are still the old list's: a leg is
    /// named by the waypoint it arrives at, and every one of those has changed.
    func reverse() {
        guard !waypoints.isEmpty else { return }
        history.record(contents)
        // One point swaps fields, the way Apple Maps' swap button moves a lone
        // destination up into the start.
        if waypoints.count == 1 {
            startIsOpen.toggle()
            refreshSlots()
            return
        }
        let flipped = travelMode == .hiking ? legs.reversed().map { $0.flipped() } : []
        waypoints.reverse()
        rebuildLegs(reusing: flipped)
    }

    /// Joins the end back to the start.
    ///
    /// A new point at the first one's place rather than a leg that closes
    /// without one, because the list, the numbering and the save all count
    /// points: a loop that ended in a leg arriving nowhere would be a trail
    /// whose last row does not exist.
    func closeTheLoop() {
        guard canCloseTheLoop, let first = waypoints.first else { return }
        history.record(contents)
        waypoints.append(
            // The first point's name travels with it, because this *is* the
            // first point: a loop that ends where it began ends at the place it
            // began at, and a destination row reading "Destination" beside a
            // start row reading "Lurdy Ház" would be two words for one spot.
            TrailWaypoint(
                latitude: first.latitude,
                longitude: first.longitude,
                name: first.name
            )
        )
        rebuildLegs()
    }

    /// Throws the points away but keeps the drawing open — the hiker starting
    /// this trail again rather than abandoning it, which is why it is a step
    /// like any other and ``clear()`` is not.
    func clearDrawing() {
        guard !isEmpty else { return }
        history.record(contents)
        cancelDrag()
        waypoints = []
        startIsOpen = false
        // The places go with the line, because *Clear* is the hiker starting
        // this trail again and a hut marked against a route that no longer
        // exists is not the start of anything. One step of undo brings back
        // both, which is the whole reason a step is the drawing rather than
        // the waypoint list — see ``TrailDraftContents``.
        places = []
        rebuildLegs()
    }

    func undo() {
        var restored = contents
        guard history.undo(&restored) else { return }
        restore(restored)
    }

    func redo() {
        var restored = contents
        guard history.redo(&restored) else { return }
        restore(restored)
    }

    // MARK: Places

    /// Adds what a place search found, as one step of undo.
    ///
    /// Places come from OpenStreetMap now, not from a hand-marked pin, so a
    /// search is the one way in and a hiker who regrets it takes it back with
    /// one *Undo* rather than forty deletes. Nothing within
    /// ``TrailPointRanking/alreadyMarkedMeters`` of a place already here is
    /// added twice.
    func addPlaces(_ found: [TrailPlace]) {
        let fresh = TrailPointRanking.excluding(places, from: found)
        guard !fresh.isEmpty else { return }
        history.record(contents)
        places.append(contentsOf: fresh)
        rankPlaces()
    }

    /// Takes one place off this trail — the place sheet's *Remove*. A step of
    /// undo, like every other edit here.
    func removePlace(id: UUID) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        history.record(contents)
        places.remove(at: index)
        rankPlaces()
    }

    /// The place with this identity, or `nil` for one that has gone.
    func place(id: UUID) -> TrailPlace? {
        places.first { $0.id == id }
    }

    /// Which leg of the line runs nearest to `coordinate`, or `nil` when there
    /// is no line.
    ///
    /// What *Add Stop* asks when the tap that dropped the pin did not land
    /// on a leg. Measured on the ground rather than on the glass, unlike the
    /// leg hit-test that answers a thumb: this is a question about where a
    /// point belongs in a route, and the answer must not depend on how the
    /// camera happened to be turned.
    ///
    /// Distance to the leg's drawn shape rather than to the straight line
    /// between its ends, so a snapped leg that loops round a spur is judged by
    /// the path it actually follows.
    func nearestLegIndex(to coordinate: CLLocationCoordinate2D) -> Int? {
        var best: Int?
        var bestDistance = Double.infinity
        for (index, leg) in legs.enumerated() {
            let shape = leg.coordinates.count > 1
                ? leg.coordinates
                : leg.ends.straightCoordinates
            for (start, end) in zip(shape, shape.dropFirst()) {
                let projection = RouteGeometry.project(
                    coordinate,
                    onSegmentFrom: CLLocationCoordinate2D(
                        latitude: start.latitude,
                        longitude: start.longitude
                    ),
                    to: CLLocationCoordinate2D(
                        latitude: end.latitude,
                        longitude: end.longitude
                    )
                )
                guard projection.offRouteMeters < bestDistance else { continue }
                bestDistance = projection.offRouteMeters
                best = index
            }
        }
        return best
    }

    /// Draws alternative `index` for the leg at `legIndex`, offering the shape
    /// it replaces in its place — a tap on a grey route on the map.
    ///
    /// **Not a step of undo**, for the reason a stop's name is not: it changes
    /// which way the line goes between two points the hiker already chose, not
    /// the points, and undo is a history of the points. The memo remembers the
    /// choice, so a reorder or an undo that brings these ends back brings the
    /// chosen shape with them.
    func chooseAlternative(_ index: Int, forLegAt legIndex: Int) {
        guard legs.indices.contains(legIndex),
              let chosen = legs[legIndex].choosing(alternative: index) else { return }
        var updated = legs
        updated[legIndex] = chosen
        publish(updated)
    }

    // MARK: A point under a finger

    /// Takes hold of a point. Answers whether there was one there to take.
    func beginDrag(ofWaypointAt index: Int) -> Bool {
        guard waypoints.indices.contains(index) else { return false }
        drag = TrailWaypointDrag(
            index: index,
            coordinate: waypoints[index].clCoordinate
        )
        dragRevision &+= 1
        return true
    }

    /// Moves the held point. Runs at display rate — see the file header for
    /// what that rules out.
    func moveDrag(to coordinate: CLLocationCoordinate2D) {
        guard var moving = drag else { return }
        guard moving.latitude != coordinate.latitude
            || moving.longitude != coordinate.longitude else { return }
        moving.latitude = coordinate.latitude
        moving.longitude = coordinate.longitude
        drag = moving
        dragRevision &+= 1
    }

    /// Lets go, and writes where the point ended up.
    ///
    /// - Returns: whether the point actually moved, which is what tells the
    ///   controller whether there is anything to write down or route. A press
    ///   that was held and released without travelling is not an edit.
    ///
    /// The drag is dropped **before** the waypoint is written, so the map's
    /// one observation pass sees a settled list with nothing held rather than
    /// a point that is both moved and still moving.
    /// **Whether it moved is asked of the coordinate, not of the whole point.**
    /// Since a point carries a name and ``move(waypointAt:to:)`` throws that
    /// name away, comparing the values either side would call a press that went
    /// nowhere an edit — for a named point it would find the name gone, record
    /// a step of undo for it, and leave the row reading "Stop 2" because a
    /// thumb rested on it.
    @discardableResult func endDrag() -> Bool {
        guard let finished = drag else { return false }
        cancelDrag()
        guard waypoints.indices.contains(finished.index) else { return false }
        let before = waypoints[finished.index]
        guard before.latitude != finished.latitude
            || before.longitude != finished.longitude else { return false }
        move(waypointAt: finished.index, to: finished.clCoordinate)
        return true
    }

    /// Lets go and puts the point back where it was. What a cancelled gesture
    /// comes to — a call arriving mid-drag, or the maker closing under one.
    func cancelDrag() {
        guard drag != nil else { return }
        drag = nil
        dragRevision &+= 1
    }

    // MARK: - Private

    /// `Array.move(fromOffsets:toOffset:)`'s semantics, written out.
    ///
    /// SwiftUI declares that method, and this type deliberately does not
    /// import SwiftUI: it is the model the map writes to from a gesture
    /// recognizer, and the one thing a `List` hands it is a pair of offsets.
    /// Written here instead, where a suite can assert it without a view.
    ///
    /// The destination is an offset **into the list as it stands**, so the
    /// rows lifted out from before it shift it back by their own count. That
    /// adjustment is the whole of what makes dragging a row downwards land
    /// where the hiker dropped it rather than one place short.
    private static func moving(
        _ waypoints: [TrailWaypoint],
        from offsets: IndexSet,
        to destination: Int
    ) -> [TrailWaypoint] {
        let lifted = waypoints.enumerated()
            .filter { offsets.contains($0.offset) }
            .map(\.element)
        guard !lifted.isEmpty else { return waypoints }
        var remaining = waypoints.enumerated()
            .filter { !offsets.contains($0.offset) }
            .map(\.element)
        let landing = destination - offsets.count { $0 < destination }
        remaining.insert(contentsOf: lifted, at: min(max(landing, 0), remaining.count))
        return remaining
    }
}
