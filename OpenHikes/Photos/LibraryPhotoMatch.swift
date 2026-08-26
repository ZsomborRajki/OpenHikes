//
//  LibraryPhotoMatch.swift
//  OpenHikes
//
//  Deciding which pictures in the system photo library are pictures of *this*
//  walk, and where on it each one belongs.
//
//  Time is the primary evidence and the route is the authority. A photograph
//  carries the second it was taken; the walk carries a position for very
//  nearly every second it lasted; and the position the walk gives is by
//  construction *on the trail*, which is the thing being pinned to. That is
//  ``HikePhotoTimeline``'s whole job, and most matches are settled by it
//  alone.
//
//  An asset's own recorded position is used for two things, and deliberately
//  not for a third.
//
//  It corroborates. When it agrees with where the walk says the walker was, the
//  match is as strong as this app can make one, and the gallery says so.
//
//  It disqualifies. Someone can take a photograph indoors, of a receipt, in
//  the middle of a hike — the clock says it belongs and the place says it
//  plainly doesn't. Without this the scan would offer every screenshot and
//  every picture of a parking meter taken between the trailhead and the
//  summit.
//
//  What it is *not* allowed to do is override a good time match. The camera's
//  own fix is a single reading taken through whatever the sky was doing under
//  the trees; the walk's is a filtered series that ``RecordingFixPolicy``
//  already refused the bad members of. When the two disagree by less than
//  ``separationToleranceMeters`` the walk wins, and when they disagree by more
//  the photo is only kept if the asset's position is itself on this route —
//  in which case the walk had a gap there, and the reading is all there is.
//

import CoreLocation
import Foundation

/// Everything the matching below needs to know about one photo in the library.
///
/// A value type rather than a `PHAsset`, so the rules can be exercised without
/// a photo library, an authorization prompt, or a device — see
/// ``PhotoLibraryReading``.
nonisolated struct PhotoLibraryAsset: Equatable, Identifiable, Sendable {
    /// The library's own identifier, carried into ``HikePhoto`` so a second
    /// scan can skip what a first one already took.
    let localIdentifier: String
    let createdAt: Date
    /// The position the camera recorded, or `nil` — which is every photo taken
    /// with location services off for the camera, and every screenshot.
    let latitude: Double?
    let longitude: Double?

    var id: String { localIdentifier }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let candidate = CLLocationCoordinate2D(
            latitude: latitude,
            longitude: longitude
        )
        guard CLLocationCoordinate2DIsValid(candidate) else { return nil }
        return candidate
    }

    init(
        localIdentifier: String,
        createdAt: Date,
        coordinate: CLLocationCoordinate2D? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.createdAt = createdAt
        latitude = coordinate?.latitude
        longitude = coordinate?.longitude
    }
}

/// One library photo that belongs to a hike, and the point on it to pin the
/// photo to.
nonisolated struct LibraryPhotoMatch: Equatable, Identifiable, Sendable {
    let asset: PhotoLibraryAsset
    let latitude: Double
    let longitude: Double
    let evidence: PhotoMatchEvidence
    /// How far the moment the photo was taken is from the nearest fix used to
    /// place it. Zero for a photo taken on a fix, and the number the review
    /// screen shows so a match can be judged rather than trusted.
    let secondsFromFix: TimeInterval

    var id: String { asset.localIdentifier }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

nonisolated enum LibraryPhotoMatcher {
    /// How far apart the walk's answer and the camera's own may be before they
    /// are treated as describing different places.
    ///
    /// Generous on purpose. A phone fixes its position to a few metres in the
    /// open and to a great deal worse under tree cover or against a rock face,
    /// and the walk's own point is itself interpolated between two fixes taken
    /// seconds apart. Disagreement at this scale is two imperfect measurements
    /// of one place; disagreement past it is two places.
    static let separationToleranceMeters: Double = 150

    /// How far off the route the camera's own position may be and still be
    /// snapped onto it, when the walk has no fix close enough in time to
    /// place the photo itself.
    ///
    /// Tighter than the tolerance above, because this is the case with no
    /// corroboration at all: the only thing saying the picture belongs to this
    /// walk is that it was taken during it, next to it.
    static let maximumOffRouteMeters: Double = 100

    /// Every asset that belongs to this walk, in the order they were taken.
    ///
    /// - Parameters:
    ///   - assets: What the library returned for ``HikePhotoTimeline/searchWindow``.
    ///     Assets outside it are refused here too rather than assumed away —
    ///     a stub, a future fetch that widens its predicate, or a library that
    ///     rounds a creation date must not be able to smuggle one past.
    ///   - timeline: The walk's time-to-place index.
    ///   - route: The route itself, for the off-route test. Passed as the raw
    ///     coordinates rather than a ``RouteProfile``: the question here is a
    ///     distance to the nearest point, not a position along the line, and
    ///     building a profile for it would be route-sized work for an answer
    ///     that doesn't need it.
    ///   - alreadyImported: Local identifiers already attached to the hike —
    ///     see ``Hike/importedPhotoAssetIdentifiers``.
    static func matches(
        assets: [PhotoLibraryAsset],
        timeline: HikePhotoTimeline,
        route: [RouteCoordinate],
        alreadyImported: Set<String> = []
    ) -> [LibraryPhotoMatch] {
        let window = timeline.searchWindow
        return assets
            .filter { asset in
                window.contains(asset.createdAt)
                    && !alreadyImported.contains(asset.localIdentifier)
            }
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { asset in
                match(asset, timeline: timeline, route: route)
            }
    }

    /// The rules in the header, applied to one asset.
    static func match(
        _ asset: PhotoLibraryAsset,
        timeline: HikePhotoTimeline,
        route: [RouteCoordinate]
    ) -> LibraryPhotoMatch? {
        let position = timeline.position(at: asset.createdAt)
        guard let camera = asset.coordinate else {
            // Nothing to corroborate with, so the clock decides alone. A photo
            // inside a GPS gap has no answer at all in this case, which is the
            // correct one: neither source can place it.
            guard let position else { return nil }
            return LibraryPhotoMatch(
                asset: asset,
                latitude: position.latitude,
                longitude: position.longitude,
                evidence: .time,
                secondsFromFix: position.secondsFromFix
            )
        }

        if let position {
            let separation = RouteGeometry.distanceMeters(
                from: camera,
                to: position.coordinate
            )
            if separation <= Self.separationToleranceMeters {
                return LibraryPhotoMatch(
                    asset: asset,
                    latitude: position.latitude,
                    longitude: position.longitude,
                    evidence: .timeAndPlace,
                    secondsFromFix: position.secondsFromFix
                )
            }
        }

        // Either the walk could not place the photo, or it placed it somewhere
        // the camera flatly disagrees with. Both come down to the same
        // question: is the camera's own position on this route? If it is, the
        // photo was taken on the walk and the reading is better than nothing.
        // If it isn't, the picture was taken somewhere this walk never went,
        // and it is not a photo of it however well the clock lines up.
        guard let nearest = nearestRoutePoint(to: camera, in: route),
              nearest.meters <= Self.maximumOffRouteMeters
        else { return nil }
        return LibraryPhotoMatch(
            asset: asset,
            latitude: nearest.coordinate.latitude,
            longitude: nearest.coordinate.longitude,
            evidence: .place,
            // Placed by position rather than by clock, so there is no fix it
            // is an offset from. Reported as zero rather than as the distance
            // to the nearest one in time, which would read as a small number
            // describing a match that did not use it.
            secondsFromFix: 0
        )
    }

    /// The route point closest to `coordinate`, and how far away it is.
    ///
    /// Vertices rather than segments. A route is sampled every few metres, so
    /// the nearest vertex is within a couple of metres of the nearest point on
    /// the line — far inside ``maximumOffRouteMeters``, and the answer is
    /// being used to decide whether something is on the trail at all rather
    /// than to position a tracker along it.
    private static func nearestRoutePoint(
        to coordinate: CLLocationCoordinate2D,
        in route: [RouteCoordinate]
    ) -> (coordinate: CLLocationCoordinate2D, meters: Double)? {
        var best: (coordinate: CLLocationCoordinate2D, meters: Double)?
        for point in route {
            let candidate = point.clCoordinate
            let meters = RouteGeometry.distanceMeters(
                from: coordinate,
                to: candidate
            )
            if meters < (best?.meters ?? .infinity) {
                best = (candidate, meters)
            }
        }
        return best
    }
}
