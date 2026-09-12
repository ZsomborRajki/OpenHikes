//
//  CommunityQueryPolicy.swift
//  OpenHikes
//
//  Decides whether the map having moved is worth offering Search this area,
//  separately from the explicit action that commits it.
//
//  Its own type for the reason ``SearchQueryPolicy`` and ``TileNetworkPolicy``
//  are theirs: the interesting behaviour is the requests that must *not* be
//  made, and those are invisible in the result. A pan that changes nothing and
//  a pan that was never asked about both leave the same rows on screen.
//
//  There are three separate reasons to refuse, and they are worth naming
//  because only one of them is the obvious one.
//
//  1. **The server cannot tell.** CloudKit's `distanceToLocation:` resolves at
//     around ten kilometres, so nudging the map two streets over asks a
//     different question and gets the same answer back. A request per pan
//     would spend the shared public-database quota redrawing an identical
//     list.
//  2. **A country is not a place.** Zoomed out far enough, "near here" stops
//     meaning anything — every hike in Europe is within the radius, and the
//     twenty that come back are twenty arbitrary ones. Above the ceiling the
//     honest answer is to keep what is already on screen and say nothing.
//  3. **Nobody asked.** Browsing is opt-in, and a walker who has never selected
//     Community should never put a request on the radio — the same bargain the
//     rest of the app's energy policies make.
//

import CoreLocation
import Foundation
import MapKit

/// What the latest map region should do to the community list.
nonisolated enum CommunityQueryAction: Equatable {
    /// Leave what is on screen alone. Nothing moved far enough, the map is too
    /// far out to mean anything, or browsing is off.
    case ignore
    /// Ask for hikes within `radiusMeters` of `coordinate`.
    case search(coordinate: CLLocationCoordinate2D, radiusMeters: Double)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.ignore, .ignore):
            true
        case let (.search(lhsCoordinate, lhsRadius), .search(rhsCoordinate, rhsRadius)):
            lhsCoordinate.latitude == rhsCoordinate.latitude
                && lhsCoordinate.longitude == rhsCoordinate.longitude
                && lhsRadius == rhsRadius
        default:
            false
        }
    }
}

/// The little state machine behind ``CommunityBrowser``: one remembered
/// query, and the two thresholds that decide whether the next region is the
/// same question.
nonisolated struct CommunityQueryPolicy {
    /// Smallest radius worth asking about. Under this the server's own
    /// resolution is coarser than the question, so a smaller number would
    /// narrow the wording and not the answer.
    static let minimumRadiusMeters: Double = 10_000
    /// Largest radius worth asking about, and the zoom ceiling with it: past
    /// this a result means "somewhere on this continent".
    static let maximumRadiusMeters: Double = 150_000
    /// How far the centre has to move, as a fraction of the last radius,
    /// before the question counts as a new one. A quarter of the search radius
    /// is roughly the point at which the returned set can actually differ.
    static let recentreFraction: Double = 0.25
    /// How far the radius has to change before a zoom counts as a new
    /// question, either way.
    private static let zoomFactor: Double = 2

    /// Whether the walker has asked for community hikes at all. Nothing is
    /// requested while this is false, and turning it off forgets the last
    /// query so turning it back on asks again rather than showing a list from
    /// wherever the map used to be.
    private(set) var isBrowsing = false
    private var lastCoordinate: CLLocationCoordinate2D?
    private var lastRadiusMeters: Double = 0

    /// Requests that were actually issued. The policy is otherwise invisible
    /// from outside — a refused pan and a pan nobody made look identical — so
    /// this is what pins it in tests.
    private(set) var issuedQueries = 0

    mutating func startBrowsing() {
        isBrowsing = true
        forgetLastQuery()
    }

    mutating func stopBrowsing() {
        isBrowsing = false
        forgetLastQuery()
    }

    /// What the map settling on `region` should do.
    ///
    /// Takes the region rather than a coordinate and a radius because the
    /// radius *is* the zoom: a walker who has zoomed into one valley is asking
    /// about that valley, and one looking at a whole county is asking about
    /// the county. Deriving it here rather than at the call site is what keeps
    /// the zoom ceiling and the radius from being two separate opinions.
    mutating func action(for region: MKCoordinateRegion) -> CommunityQueryAction {
        guard isBrowsing else { return .ignore }
        // The *unclamped* radius is what the ceiling is tested against, and
        // the distinction is load-bearing: clamping first would make every
        // region look like it was exactly at the ceiling and the guard below
        // could never fire.
        let visibleRadius = Self.visibleRadiusMeters(for: region)
        // Above the ceiling nothing is asked and nothing is forgotten: zooming
        // out to look at the country and back in to the same valley should
        // leave the valley's results standing rather than re-fetch them.
        guard visibleRadius <= Self.maximumRadiusMeters else { return .ignore }
        let radius = max(visibleRadius, Self.minimumRadiusMeters)
        let coordinate = region.center

        if let lastCoordinate {
            let moved = RouteGeometry.distanceMeters(from: lastCoordinate, to: coordinate)
            let zoomed = radius > lastRadiusMeters * Self.zoomFactor
                || radius < lastRadiusMeters / Self.zoomFactor
            guard moved > lastRadiusMeters * Self.recentreFraction || zoomed else {
                return .ignore
            }
        }

        issuedQueries += 1
        lastCoordinate = coordinate
        lastRadiusMeters = radius
        return .search(coordinate: coordinate, radiusMeters: radius)
    }

    /// Drops the remembered query without turning browsing off, so the next
    /// region is asked about whatever it is.
    ///
    /// What a pull-to-refresh means, and what a failed request leaves behind:
    /// a query that came back empty because the network was down must not be
    /// the reason the same region is never asked about again.
    mutating func forgetLastQuery() {
        lastCoordinate = nil
        lastRadiusMeters = 0
    }

    /// Half the longer edge of the visible region, unclamped.
    ///
    /// The longer edge rather than the shorter so the corners of the screen
    /// are inside the circle: a walker can see a trailhead in the corner of
    /// the map, and a radius that excluded it would be showing a hike and
    /// refusing to list it.
    ///
    /// Returned raw so ``action(for:)`` can tell "zoomed out past the ceiling"
    /// from "at the ceiling", which are different answers — see the guard
    /// there.
    static func visibleRadiusMeters(for region: MKCoordinateRegion) -> Double {
        let metersPerDegreeLatitude: Double = 111_320
        let latitudeMeters = region.span.latitudeDelta * metersPerDegreeLatitude
        let longitudeMeters = region.span.longitudeDelta * metersPerDegreeLatitude
            * cos(region.center.latitude * .pi / 180)
        return max(latitudeMeters, abs(longitudeMeters)) / 2
    }
}
