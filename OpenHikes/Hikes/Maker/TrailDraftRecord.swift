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
    /// What the hiker has typed into the maker's name field, unbounded here
    /// and bounded on the way out — ``TrailDraftSave`` is where a draft
    /// becomes a hike and where ``HikeTitle/bounded(_:)`` is spent, which is
    /// the rule that type states: a name is bounded where it enters the app's
    /// payloads, and a draft on this device's own disk is not one of them.
    var name: String = ""

    /// The points, in order. ``RouteCoordinate`` rather than a second encoded
    /// shape, because it is already what a route is written as and a draft is
    /// a route that is not finished. The per-waypoint identities are not kept:
    /// they exist so a list can key its rows within one session, and a restore
    /// is a new session.
    var waypoints: [RouteCoordinate] = []

    /// When this was last written, so a later phase that offers to resume a
    /// draft has something to say about it. Read by nothing today.
    var updatedAt = Date.distantPast

    init(name: String, waypoints: [RouteCoordinate], updatedAt: Date) {
        self.name = name
        self.waypoints = waypoints
        self.updatedAt = updatedAt
    }
}
