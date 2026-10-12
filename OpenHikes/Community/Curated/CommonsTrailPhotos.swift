//
//  CommonsTrailPhotos.swift
//  OpenHikes
//
//  Which of the photographs Commons has near a route are photographs *of the
//  walk* — and which dozen of those to show.
//
//  ## On the line, or not at all
//
//  Commons answers a circle, and a circle around a stretch of trail holds the
//  village at the trailhead, the road the bus took, the hut across the valley
//  and the aerial survey of all of it. Measured over one Berchtesgaden box,
//  two in three of a sample of OpenStreetMap places had a geotagged file
//  within 250 metres and one in three within 100 — and read by title, a good
//  share of the near ones were houses, car parks and survey tiles. So the rule
//  is the one this app already applies to a photograph from the hiker's own
//  library: the camera has to have stood within
//  ``LibraryPhotoMatcher/maximumOffRouteMeters`` of the line, and it is pinned
//  *on* the line, at the point nearest where it stood — see
//  ``PickedPhotoPlacement``, which snaps the same way for the same reason.
//
//  ## Spread along the walk, not piled at the car park
//
//  The places people photograph are not evenly spaced: a summit cross, a lake
//  shore and a hut terrace hold dozens of files each, and the forest between
//  them none. Taking the nearest dozen to the line would show one viewpoint
//  twelve times. So the route is cut into as many equal lengths as there are
//  photographs to show, the file whose camera stood closest to the line is
//  taken from each, and only then is any length allowed a second — so a
//  dozen photographs of a ten-kilometre walk are about one a kilometre, and
//  the strip reads in walking order.
//
//  And spread among the people who took them. One uploader's run of a road, a
//  frame a minute, can stand on every stretch of a short walk at once; so no
//  photographer takes more than ``CommonsTrailPhotos/perAuthorLimit`` places
//  while somebody else's photograph could take one — see
//  ``CommonsTrailPhotos/chosen(_:authors:limit:over:)``.
//

import CoreLocation
import Foundation
import OpenHikesData

nonisolated enum CommonsTrailPhotos {
    /// How far from the line a camera may have stood — the rule a library
    /// photograph is placed by, and for the same reason. See this file's
    /// header.
    static let corridorMeters = LibraryPhotoMatcher.maximumOffRouteMeters

    /// How much of the line one geosearch covers, in metres of radius before
    /// the corridor is added.
    ///
    /// Small, because the geosearch answers at most
    /// ``CommonsPhotoQuery/geosearchLimit`` files nearest its centre, and a
    /// popular valley holds more than that within a few kilometres — measured,
    /// every 7 × 6 km tile over the Berchtesgaden box answered its full 500. A
    /// circle a kilometre in radius — two and a bit across, with the corridor
    /// — loses its far edge to that cap only in a town, where the trail is
    /// rarely the point.
    static let stretchRadiusMeters: Double = 1000

    /// The most geosearches one route makes, and the circle none of them may
    /// grow past — Commons refuses a radius over ten kilometres.
    static let maximumAreas = 16
    static let maximumRadiusMeters: Double = 10_000

    /// How many photographs one route shows.
    ///
    /// A dozen fills the strip and puts about one a kilometre on a ten-
    /// kilometre walk, at a cost — see ``CommonsPhotoQuery/thumbnailWidth`` —
    /// a hiker who opens a trail and leaves can afford.
    static let photoLimit = 12

    /// The most places in the strip one photographer may take while somebody
    /// else's photograph could take one instead.
    ///
    /// Measured against the live service along the Königssee shore: seven of
    /// the twelve photographs the spread chose were one uploader's run of the
    /// same road, a frame a minute. A walk photographed by one person still
    /// shows theirs all along it — past the limit, a photographer's pictures
    /// go only where nobody's stands yet — but a walk photographed by several
    /// shows several.
    static let perAuthorLimit = 3

    /// One file, standing on the line.
    struct Placed: Equatable, Sendable {
        var pageID: Int
        /// The point on the line nearest where the camera stood — the pin.
        var latitude: Double
        var longitude: Double
        /// How far along the route that point is, in metres.
        var distanceAlongRoute: Double
        /// How far off the line the camera stood, in metres. Smaller is the
        /// better claim to being a photograph of the walk.
        var offRouteMeters: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        /// The page and its pin, which is all a download needs to know — the
        /// shape an area's photographs are chosen in, so both reach one
        /// download. See ``CommonsAreaPhotos``.
        var spot: CommonsPhotoCandidate {
            CommonsPhotoCandidate(pageID: pageID, latitude: latitude, longitude: longitude)
        }
    }

    /// The circles one route's geosearches ask about, in walking order.
    static func areas(along route: [RouteCoordinate]) -> [CommunitySearchArea] {
        TrailPlaceCorridorSearch.areas(
            along: route,
            stretchRadius: stretchRadiusMeters,
            margin: corridorMeters,
            maximumAreas: maximumAreas,
            ceiling: maximumRadiusMeters
        )
    }

    /// The candidates whose camera stood within ``corridorMeters`` of the
    /// line, each pinned to the nearest point on it — once each, however many
    /// circles found it.
    static func placed(_ candidates: [CommonsPhotoCandidate], on profile: RouteProfile) -> [Placed] {
        var seen: Set<Int> = []
        return candidates.compactMap { candidate in
            guard seen.insert(candidate.pageID).inserted,
                  let nearest = profile.nearestPoint(to: candidate.coordinate),
                  nearest.offRouteMeters <= corridorMeters,
                  let pin = profile.coordinate(atDistance: nearest.distanceAlongRoute)
            else { return nil }
            return Placed(
                pageID: candidate.pageID,
                latitude: pin.latitude,
                longitude: pin.longitude,
                distanceAlongRoute: nearest.distanceAlongRoute,
                offRouteMeters: nearest.offRouteMeters
            )
        }
    }

    /// At most `limit` of `placed`, spread along a route of `length` metres
    /// and returned in walking order — see this file's header.
    ///
    /// Deterministic: ties go to the lower page id, so the same answer always
    /// draws the same strip.
    static func spread(_ placed: [Placed], limit: Int, over length: Double) -> [Placed] {
        guard limit > 0 else { return [] }
        guard placed.count > limit else { return placed.sorted(by: walkingOrder) }
        let byStretch = Dictionary(grouping: placed) { stretch(of: $0, limit: limit, over: length) }
        var picked = byStretch.values.compactMap { $0.min(by: closerToTheLine) }
        if picked.count < limit {
            let taken = Set(picked.map(\.pageID))
            let rest = placed.filter { !taken.contains($0.pageID) }.sorted(by: closerToTheLine)
            picked += rest.prefix(limit - picked.count)
        }
        return picked.sorted(by: walkingOrder)
    }

    /// At most `limit` of `placed`, spread along the route as
    /// ``spread(_:limit:over:)`` spreads them, with no photographer taking more
    /// than ``perAuthorLimit`` places while anybody else's photograph could
    /// fill one — see that limit for why.
    ///
    /// Each photographer's nearest-the-line photographs are the ones that
    /// compete first. The rest are offered afterwards, and only for the
    /// stretches of the route nothing chosen stands on yet: a second run of
    /// one person's pictures fills a gap in the walk rather than piling onto a
    /// stretch it already shows. A file whose page names nobody is nobody's,
    /// and is never held back.
    ///
    /// - Parameter authors: Who took each file, by page id, for the files
    ///   whose page names somebody.
    static func chosen(
        _ placed: [Placed],
        authors: [Int: String],
        limit: Int,
        over length: Double
    ) -> [Placed] {
        var taken: [String: Int] = [:]
        var preferred: [Placed] = []
        var heldBack: [Placed] = []
        for photo in placed.sorted(by: closerToTheLine) {
            guard let author = authors[photo.pageID] else {
                preferred.append(photo)
                continue
            }
            let count = taken[author, default: 0]
            if count < perAuthorLimit {
                taken[author] = count + 1
                preferred.append(photo)
            } else {
                heldBack.append(photo)
            }
        }
        let first = spread(preferred, limit: limit, over: length)
        guard first.count < limit else { return first }
        let covered = Set(first.map { stretch(of: $0, limit: limit, over: length) })
        let gaps = Dictionary(grouping: heldBack) { stretch(of: $0, limit: limit, over: length) }
            .filter { !covered.contains($0.key) }
            .values
            .compactMap { $0.min(by: closerToTheLine) }
            .sorted(by: closerToTheLine)
        return (first + gaps.prefix(limit - first.count)).sorted(by: walkingOrder)
    }

    /// Which of `limit` equal lengths of a route `length` metres long a
    /// photograph stands on — the stretches ``spread(_:limit:over:)`` takes one
    /// from each of.
    private static func stretch(of photo: Placed, limit: Int, over length: Double) -> Int {
        min(Int(photo.distanceAlongRoute / (max(length, 1) / Double(limit))), limit - 1)
    }

    private static func closerToTheLine(_ lhs: Placed, _ rhs: Placed) -> Bool {
        lhs.offRouteMeters == rhs.offRouteMeters ? lhs.pageID < rhs.pageID : lhs.offRouteMeters < rhs.offRouteMeters
    }

    private static func walkingOrder(_ lhs: Placed, _ rhs: Placed) -> Bool {
        lhs.distanceAlongRoute == rhs.distanceAlongRoute
            ? lhs.pageID < rhs.pageID
            : lhs.distanceAlongRoute < rhs.distanceAlongRoute
    }
}
