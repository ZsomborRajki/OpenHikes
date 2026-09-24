//
//  TrailRegion.swift
//  OpenHikes
//
//  The circle the system watches on this app's behalf, so that background
//  matching is armed only while the hiker is anywhere near the trail it would
//  be matching fixes against.
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
//  So proximity is the fourth condition, and the system is the one that
//  answers it. This app registers a circle and is told when the phone crosses
//  it; it never asks where the phone is, never receives a coordinate for this
//  purpose, and stores nothing about the hiker's position on disk. The one
//  thing it keeps is in memory and one of three values — see
//  ``TrailRegionState``.
//
//  That is the whole reason this is a circle rather than the trail's own
//  bounding box. A box would fit a linear route far better, and an earlier
//  draft of this gate used one. But a box has to be evaluated against a
//  position, which means having a position, which means storing one across
//  launches — and the position a significant-change feed hands you is not
//  where the hiker walked, it is wherever they happen to be: home, work, the
//  school run. Circumscribing the box costs coverage that ``slackMeters``
//  was already spending, and buys never holding that datum at all.
//

import CoreLocation
import Foundation
import OpenHikesData

/// The circle the tracked trail sits inside, as registered with the system.
///
/// Not `Codable`, and deliberately so: nothing here is persisted by this app.
/// The system holds the geometry against the identifier it was registered
/// under, and a launch asks it for the answer rather than recomputing one.
nonisolated struct TrailRegion: Equatable, Sendable {
    /// How far outside the trail's own extent still counts as near it.
    ///
    /// Ten kilometres, which is about a quarter of an hour of driving and is
    /// deliberately far wider than any GPS question. What the slack absorbs is
    /// not error but the approach: a hiker on the last stretch of the drive
    /// has crossed into the region already, so a walk started at the trailhead
    /// is matched from its first fix rather than from the first foreground.
    ///
    /// It is not a claim about how far people travel to hike. A hiker further
    /// out than this loses nothing but background wakes they were not using,
    /// and crossing in is an event the system delivers whether or not this app
    /// is running.
    static let slackMeters: CLLocationDistance = 10_000

    /// The largest circle worth registering.
    ///
    /// Our own bound, not the system's: CoreLocation publishes no maximum for
    /// a ``CLMonitor`` condition, and the honest reading of that silence is
    /// that very large circles are not what the hardware geofence is for. A
    /// trail whose circle would exceed this gets no condition at all and so
    /// stays armed — see ``init(route:slackMeters:)``. That is the same
    /// fail-open direction the rest of this gate takes, and it means a
    /// long-distance route behaves exactly as it did before this existed.
    static let maximumRadiusMeters: CLLocationDistance = 100_000

    let latitude: Double
    let longitude: Double
    let radiusMeters: CLLocationDistance

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(latitude: Double, longitude: Double, radiusMeters: CLLocationDistance) {
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
    }

    /// The circle enclosing `route`, grown by `slack`.
    ///
    /// Built on ``TileBoundingBox`` rather than on a plain min/max, because
    /// longitude is cyclic and that type already knows it: a route that steps
    /// over the antimeridian has an east edge numerically *west* of its west
    /// edge, and a naive centre would land halfway round the world from the
    /// trail. The box picks the shorter of the two arcs through the points,
    /// and the centre below walks half that arc east from its west edge.
    ///
    /// - Returns: `nil` for a route with no points, which has no circle to
    ///   speak of, and for one whose circle would exceed
    ///   ``maximumRadiusMeters``. Both answers mean *do not register a
    ///   condition*, and the caller reads both as *stay armed*.
    init?(route: [CLLocationCoordinate2D], slackMeters slack: CLLocationDistance = slackMeters) {
        guard let box = TileBoundingBox(route: route) else { return nil }

        let centerLatitude = (box.southLat + box.northLat) / 2
        // Back into `[-180, 180)`, which is where ``TileBoundingBox/westLon``
        // lives and where CoreLocation wants a centre.
        let centerLongitude = RouteGeometry.normalizedLongitude(box.westLon + box.lonSpan / 2)

        // Half the box's own diagonal, then the slack on top. A degree of
        // longitude is shortest at the poles, so the half-span that matters is
        // the one measured at whichever of the box's two latitude edges lies
        // closest to the equator — and if the box straddles the equator, at
        // the equator itself. Taking the widest of them overstates the radius,
        // which errs towards *near*, which is the direction this gate errs in
        // everywhere else.
        let widestLatitude = box.southLat <= 0 && box.northLat >= 0
            ? 0
            : min(abs(box.southLat), abs(box.northLat))
        let halfHeightMeters = (box.northLat - box.southLat) / 2 * RouteGeometry.metersPerDegreeLatitude
        let halfWidthMeters = box.lonSpan / 2
            * RouteGeometry.metersPerDegreeLatitude
            * cos(widestLatitude * .pi / 180)

        let radius = (halfHeightMeters * halfHeightMeters + halfWidthMeters * halfWidthMeters)
            .squareRoot() + slack
        guard radius <= Self.maximumRadiusMeters else { return nil }

        self.init(latitude: centerLatitude, longitude: centerLongitude, radiusMeters: radius)
    }
}
