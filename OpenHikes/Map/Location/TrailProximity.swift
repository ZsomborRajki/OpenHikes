//
//  TrailProximity.swift
//  OpenHikes
//
//  Whether the phone is anywhere near the trail it would be matching fixes
//  against.
//
//  ``BackgroundTrailTracker`` arms significant-change monitoring only while it
//  has something to do, and until this existed "something to do" meant a trail
//  being selected. A selection is persisted and restored, so that condition is
//  true forever for anyone who has ever opened a trail and not explicitly
//  closed it — including on the other side of a continent, where every wake
//  the registration buys is a launch that returns at the off-route branch. The
//  registration also outlives the process that made it, which is what puts the
//  system's background-location indicator in front of a hiker who has force-
//  quit the app.
//
//  So proximity is the fourth condition, and it is coarse on purpose: the box
//  is the trail's own bounding box, padded by ``slackMeters``, and the
//  position it is tested against is whatever the app last heard — not a fix
//  asked for here. Nothing in this file costs a location request.
//
//  ## What this is not
//
//  It is not a re-arm mechanism. Once monitoring is down there is no feed left
//  to notice the hiker approaching, so the arming decision is re-taken
//  wherever a position arrives by some other route: the foreground
//  ``SignificantLocationFeed`` and a background fix that is still being
//  delivered. That covers the ordinary case — a hiker opens the app when they
//  reach the trailhead — at no background cost.
//
//  `CLMonitor`'s circular conditions are the honest long-term shape: region
//  monitoring is the mechanism actually designed for "tell me when they get
//  near", and it costs no wakes in between. It is a larger change than the
//  symptom needs, and is deliberately left for its own issue.
//

import CoreLocation
import Foundation

/// The trail background matching is armed for, reduced to the one fact the
/// arming decision needs.
///
/// Persisted rather than derived, because the decision is taken in
/// ``BackgroundTrailTracker/init(container:monitor:defaults:liveActivityController:clock:widgetReload:)``
/// — before any view exists, on a launch that may have been started by the
/// system purely to deliver a fix. Deriving the box there would mean fetching
/// the hike and materialising its externally stored route, which is the
/// route-sized work the tracker is careful to keep off a launch's main thread.
///
/// The hike id travels with the box for the same reason
/// ``SettingsKey/lastMatchedDistance`` is cleared on a selection change: a box
/// belonging to the previous trail is worse than no box at all, since it
/// would answer the distance question about a trail nobody is following.
nonisolated struct TrackedTrailArea: Codable, Equatable, Sendable {
    let hikeID: UUID
    let box: TileBoundingBox

    /// `nil` for a route with no points, which has no box to speak of.
    init?(hikeID: UUID, route: [RouteCoordinate]) {
        guard let boundingBox = TileBoundingBox(route: route.map(\.clCoordinate)) else { return nil }
        self.hikeID = hikeID
        box = boundingBox
    }
}

nonisolated enum TrailProximity {
    /// How far outside the trail's bounding box still counts as near it.
    ///
    /// Ten kilometres, which is about a quarter of an hour of driving and is
    /// deliberately far wider than any GPS question. What the slack absorbs is
    /// not error but the approach: a hiker who has the app in the background
    /// on the last stretch of the drive keeps monitoring armed, so a walk
    /// started at the trailhead is matched from its first fix rather than from
    /// the first foreground.
    ///
    /// It is not a claim about how far people travel to hike. A hiker further
    /// out than this loses nothing but background wakes they were not using:
    /// opening the app re-takes the decision, and opening the app is what they
    /// do on arrival.
    static let slackMeters: CLLocationDistance = 10_000

    /// Whether `coordinate` is inside `area`'s box, padded by `slackMeters`.
    static func isNear(
        _ coordinate: CLLocationCoordinate2D,
        of area: TrackedTrailArea,
        slackMeters slack: CLLocationDistance = slackMeters
    ) -> Bool {
        area.box.padded(byMeters: slack).contains(coordinate)
    }
}
