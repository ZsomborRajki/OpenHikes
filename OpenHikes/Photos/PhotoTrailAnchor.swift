//
//  PhotoTrailAnchor.swift
//  OpenHikes
//
//  Which point on the trail a photo taken right now belongs to — and, just as
//  importantly, when the answer is "none".
//
//  The elevation graph already carries a position: the live match while
//  auto-follow has one, or wherever the walker last left the scrubber. That is
//  the selection a photo is pinned to, so taking a picture needs no separate
//  gesture and no second idea of "where I am".
//
//  The rule it encodes is one distinction that a view cannot make on its own.
//  ``TrackerState/trackerDistance`` starts every hike at 0 as a *placeholder* —
//  `HikeDetailView` sets it when the profile is built, before anything has
//  been matched or dragged — and 0 is also a real position, at the trailhead.
//  Treating them alike would either drop a genuine photo taken at the start of
//  a walk, or pin every unanchored photo to the trailhead. So a live match
//  counts at any distance including zero, a scrub counts once it has actually
//  moved, and a bare placeholder counts as nothing at all.
//

import CoreLocation
import Foundation

nonisolated enum PhotoTrailAnchor {
    /// How far along the route a photo taken now belongs, or `nil` when the
    /// elevation graph has no position worth pinning to.
    ///
    /// - Parameters:
    ///   - live: ``TrackerState/liveTrackerDistance`` — a real GPS match onto
    ///     this route, or `nil` when auto-follow is off, has no fix, or the
    ///     walker is off-trail.
    ///   - scrubbed: ``TrackerState/trackerDistance`` — the persistent
    ///     tracker, which is 0 until it is moved.
    static func distanceAlongRoute(live: Double?, scrubbed: Double) -> Double? {
        // A match is evidence of a place, so it is taken at face value even at
        // the trailhead. Only the untouched placeholder is refused.
        if let live, live.isFinite, live >= 0 { return live }
        guard scrubbed.isFinite, scrubbed > 0 else { return nil }
        return scrubbed
    }

    /// The coordinate to attach to a photo taken now, or `nil` to file it in
    /// the hike's gallery without a place on the map.
    ///
    /// `nil` covers all three ways this can come up empty: no route profile
    /// has been built yet, no position has been selected on the graph, and a
    /// position that the profile cannot turn into a coordinate — a route of
    /// one point, or none.
    static func coordinate(
        profile: RouteProfile?,
        live: Double?,
        scrubbed: Double
    ) -> CLLocationCoordinate2D? {
        guard let profile,
              let distance = distanceAlongRoute(live: live, scrubbed: scrubbed),
              let coordinate = profile.coordinate(atDistance: distance),
              CLLocationCoordinate2DIsValid(coordinate)
        else { return nil }
        return coordinate
    }

    /// The coordinate for a photo taken while recording, where there is no
    /// elevation graph to read and the walker is, by definition, standing at
    /// the point the picture is of.
    ///
    /// The draft's last accepted fix rather than a fresh location read: only
    /// fixes that got past ``RecordingFixPolicy`` become one, so this inherits
    /// the same accuracy, speed and displacement gates the route itself is
    /// built from — and it is, by construction, a point that is actually on
    /// the line the photo will be shown against. A recording with no accepted
    /// fix yet has no place to pin to, and says so.
    ///
    /// Takes the recorder's live fix rather than the draft `Hike`'s `route`:
    /// that array is written once, when the recording stops, so during the
    /// walk — which is the only time this is called — it is always empty.
    static func recordingCoordinate(_ point: RecordingPoint?) -> CLLocationCoordinate2D? {
        guard let point else { return nil }
        let coordinate = CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return coordinate
    }
}
