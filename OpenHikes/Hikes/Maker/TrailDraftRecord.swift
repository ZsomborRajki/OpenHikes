//
//  TrailDraftRecord.swift
//  OpenHikes
//
//  The half-drawn trail, kept across launches.
//
//  A hiker who puts down a dozen points, takes a call and comes back should
//  find them. So the draft is written down — and **into the unmirrored store**,
//  beside ``HikeLocalState`` rather than beside ``Hike``.
//
//  That is the whole of the decision and it is not about storage. A draft is
//  one device's unfinished work: mirroring it would mean last-writer-wins
//  between two phones over a line that is *being drawn*, which is the same
//  shape as the tile-inventory loss ``HikeLocalState`` exists to prevent, and
//  it would put a trail nobody has finished into a database the hiker's other
//  devices read. `cloudKitDatabase: .none` is what says so — see
//  ``ModelConfiguration/openHikesLocal(schema:isStoredInMemoryOnly:)`` — and
//  it also means this type costs no `CD_` record type, no Console index and no
//  entry in ``MirroredCloudKitSchema``.
//
//  SwiftData rather than a file, for what it is *not*: no atomic-write helper,
//  no restore path of its own, no orphan sweep, no second encoded format. The
//  recording journal is a file for reasons this does not share — it is
//  appended per GPS fix, off the main actor, from a delegate callback, and has
//  to survive a kill mid-write. A draft is written when a hiker taps.
//
//  **There is one of these, and the store is what keeps it that way.** The
//  maker draws one trail at a time, so ``TrailDraftStore`` reads the first row
//  and rewrites it rather than inserting a second. No `#Unique` — CloudKit
//  forbids one on the mirrored side and ``Hike`` argues the rest of the case:
//  a uniqueness constraint turns a duplicate into a silent upsert.
//

import Foundation
import SwiftData

@Model
final class TrailDraftRecord {
    /// The points, in order. ``RouteCoordinate`` rather than a second encoded
    /// shape, because it is already what a route is written as and a draft is
    /// a route that is not finished. The per-waypoint identities are not kept:
    /// they exist so a list can key its rows within one session, and a restore
    /// is a new session.
    var waypoints: [RouteCoordinate] = []

    /// What each of those points is called, in the same order, and empty for
    /// one nothing has named — see ``TrailWaypoint/name``.
    ///
    /// **A second array beside the first rather than a richer point**, and the
    /// reason is the store rather than the shape: ``waypoints`` is already a
    /// `RouteCoordinate` column, and changing what a column *is* needs a
    /// migration this phase of the project does not have — see *Schema and
    /// migration policy*. A new column with an inline default does not, which
    /// is exactly how ``places`` was added, so a row written before names
    /// existed resumes as a drawing whose points are named by their roles.
    ///
    /// The cost is that the pairing is an invariant rather than a type, so
    /// ``TrailDraftStore`` zips defensively: a row with the two lengths out of
    /// step resumes with the coordinates it has and no names, because a line in
    /// the wrong place is a worse failure than a line with nothing written
    /// beside it.
    var waypointNames: [String] = []

    /// The places marked along it, in the order they were marked.
    ///
    /// ``TrailPlace`` itself rather than a second encoded shape, because it is
    /// already `Codable` and already the value every screen works in — the
    /// same argument the waypoints above make for ``RouteCoordinate``. It is
    /// only here, in the *unmirrored* store, that a stored `TrailPlace` costs
    /// nothing: the mirrored copy a save writes is ``TrailPoint``, a row per
    /// place, because that is what CloudKit can carry and query.
    ///
    /// The identities *are* kept here, unlike the waypoints', and the
    /// difference is what they are for: a waypoint's id exists so a list can
    /// key its rows within one session, while a place's is what the map, the
    /// editor and the drag all name it by — and what a saved ``TrailPoint``
    /// carries. An empty inline default, so a row written before this column
    /// existed resumes as a drawing with nothing marked on it.
    var places: [TrailPlace] = []

    /// Whether the legs between them were following mapped paths.
    ///
    /// Part of the drawing rather than a global preference, because it is
    /// about *this* trail: a hiker drawing a line across open fell has turned
    /// it off for that line, and a hiker who then starts a route up a marked
    /// valley wants it back on. An inline default, like every column here —
    /// see *Schema and migration policy*; `true` because that is what a new
    /// draft starts as, so a row written before this column existed resumes
    /// the way a new draft would begin.
    var snapsToPaths = true

    /// When this was last written, so a later phase that offers to resume a
    /// draft has something to say about it. Read by nothing today.
    var updatedAt = Date.distantPast

    init(
        waypoints: [RouteCoordinate],
        waypointNames: [String],
        places: [TrailPlace],
        snapsToPaths: Bool,
        updatedAt: Date
    ) {
        self.waypoints = waypoints
        self.waypointNames = waypointNames
        self.places = places
        self.snapsToPaths = snapsToPaths
        self.updatedAt = updatedAt
    }
}
