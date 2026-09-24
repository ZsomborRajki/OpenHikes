//
//  SeededCommunitySpread.swift
//  OpenHikes
//
//  Where each seeded hike stands on the map.
//
//  Its own file because ``SeededCommunityTransport`` is at the 500-line limit,
//  and because this is one idea rather than a corner of that one: the seeded
//  listings all began at exactly ``SeededCommunityTransport/startLatitude``,
//  and the map pins for them — which are allowed to declutter, see
//  `MapCommunityAnnotations.swift` — therefore drew as a single marker at
//  every zoom. Three hikes sharing one pin is not what the pins are for.
//
//  Two coordinates come out of this and they are not the same coordinate. The
//  pin's is a stored field on the listing, set where the listing is built; the
//  line's comes from `route(of:)`. Both were the trailhead, so moving only one
//  of them would put a hike's marker somewhere its own line is not.
//

import Foundation
import OpenHikesData

#if DEBUG

nonisolated extension SeededCommunityTransport {
    /// How far apart two seeded hikes start: about 550 m of latitude and
    /// 220 m of longitude per step along the spread.
    ///
    /// Far enough that the markers do not declutter into one, close enough
    /// that the whole set fits the band of map a half-height sheet leaves.
    ///
    /// Well inside ``CommunityQueryPolicy/minimumRadiusMeters``, so a nearby
    /// search still answers with all of them, and far short of the eight
    /// kilometres the curated routes sit at — so the merged answer's
    /// nearest-first order is what it always was.
    static let listingSpreadLatitude = 0.005
    static let listingSpreadLongitude = 0.003

    /// The seeded titles in the order their start points are spread.
    ///
    /// An explicit list rather than a hash of the id, which is what this was:
    /// `abs(listing.id.hashValue % 5)` is wrong twice over. Swift seeds its
    /// hasher per process, so the hikes moved on every launch — invisible to
    /// an assertion about a row, and obvious in a screenshot of the map — and
    /// five buckets collide often enough that two of them regularly landed on
    /// the same point anyway.
    static let spreadOrder = [
        ridgeTitle, lakeTitle, scrambleTitle, queuedTitle, queuedPhotographedTitle,
    ]

    /// Where `title` sits in the spread, or past the end for anything not
    /// seeded here.
    static func spreadIndex(title: String) -> Int {
        spreadOrder.firstIndex(of: title) ?? spreadOrder.count
    }

    /// How far this listing's start stands from the trailhead, in degrees.
    static func spreadLatitude(of title: String) -> Double {
        Double(spreadIndex(title: title)) * listingSpreadLatitude
    }

    /// Staggered across two columns rather than strung out along one line, so
    /// the pins read as hikes in a valley rather than as a list drawn sideways.
    static func spreadLongitude(of title: String) -> Double {
        Double(spreadIndex(title: title) % 2) * listingSpreadLongitude
    }
}

#endif
