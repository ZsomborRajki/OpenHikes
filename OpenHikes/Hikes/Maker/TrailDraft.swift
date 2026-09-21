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
//  ## Undo, and the one thing that is not snapshotted
//
//  Every operation below records the waypoint list before it changes it, into
//  ``TrailDraftHistory``. What is *not* in a snapshot is the resolved leg
//  shapes: they are far larger than the points and they are re-derivable, so
//  they are remembered once, by their two ends, in ``TrailLegMemo`` — which
//  `rebuildLegs` consults. That is what makes undo restore the line rather
//  than redraw it straight and ask for it again, and it does the same for a
//  reorder, a delete and a point dragged away and back.
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

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// Whether the line can be edited at all — two points is the smallest
    /// thing a reorder, a reverse or a loop is about.
    var canBeRearranged: Bool { waypoints.count > 1 }

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
    func append(_ coordinate: CLLocationCoordinate2D) {
        history.record(waypoints)
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
    /// A different drawing, so the steps behind the last one go with it — an
    /// undo that reached back past a restore would offer a line from a
    /// session that has ended.
    func replace(with waypoints: [TrailWaypoint], snapsToPaths: Bool) {
        cancelDrag()
        history.forget()
        self.waypoints = waypoints
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
        publish(rebuilt)
    }

    /// Puts the waypoint list back to something the history handed over.
    ///
    /// The legs are rebuilt rather than restored, because the memo above holds
    /// every shape this drawing has settled and the list is what says which of
    /// them apply. See ``TrailDraftHistory`` for why a step is a list of points
    /// and not a list of shapes.
    private func restore(_ restored: [TrailWaypoint]) {
        cancelDrag()
        waypoints = restored
        rebuildLegs()
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
    /// Moves one point to a new place. What a drag commits, and the only thing
    /// that changes a waypoint's coordinate.
    func move(waypointAt index: Int, to coordinate: CLLocationCoordinate2D) {
        guard waypoints.indices.contains(index) else { return }
        let moved = TrailWaypoint(coordinate: coordinate, id: waypoints[index].id)
        guard moved != waypoints[index] else { return }
        history.record(waypoints)
        waypoints[index] = moved
        rebuildLegs()
    }

    /// Puts a point into the middle of a leg, at the place that was tapped.
    ///
    /// After the leg's *start*, which is the whole of what makes this an
    /// insert rather than an append: leg *n* runs from waypoint *n* to
    /// waypoint *n + 1*, so the new point takes index *n + 1* and the leg
    /// becomes two.
    func insert(_ coordinate: CLLocationCoordinate2D, intoLegAt index: Int) {
        guard legs.indices.contains(index) else { return }
        history.record(waypoints)
        waypoints.insert(TrailWaypoint(coordinate: coordinate), at: index + 1)
        rebuildLegs()
    }

    /// Takes points out of the line. What a swipe on a row does.
    func remove(atOffsets offsets: IndexSet) {
        let kept = waypoints.enumerated()
            .filter { !offsets.contains($0.offset) }
            .map(\.element)
        guard kept.count != waypoints.count else { return }
        history.record(waypoints)
        waypoints = kept
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
        history.record(waypoints)
        waypoints = reordered
        rebuildLegs()
    }

    /// Walks the line the other way.
    ///
    /// **Nothing is re-asked for.** Every leg already has its shape; reversing
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
        guard canBeRearranged else { return }
        history.record(waypoints)
        let flipped = legs.reversed().map { $0.flipped() }
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
        history.record(waypoints)
        waypoints.append(
            TrailWaypoint(latitude: first.latitude, longitude: first.longitude)
        )
        rebuildLegs()
    }

    /// Throws the points away but keeps the drawing open — the hiker starting
    /// this trail again rather than abandoning it, which is why it is a step
    /// like any other and ``clear()`` is not.
    func clearDrawing() {
        guard !waypoints.isEmpty else { return }
        history.record(waypoints)
        cancelDrag()
        waypoints = []
        rebuildLegs()
    }

    func undo() {
        var restored = waypoints
        guard history.undo(&restored) else { return }
        restore(restored)
    }

    func redo() {
        var restored = waypoints
        guard history.redo(&restored) else { return }
        restore(restored)
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
    @discardableResult func endDrag() -> Bool {
        guard let finished = drag else { return false }
        cancelDrag()
        guard waypoints.indices.contains(finished.index) else { return false }
        let before = waypoints[finished.index]
        move(waypointAt: finished.index, to: finished.clCoordinate)
        return waypoints[finished.index] != before
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
