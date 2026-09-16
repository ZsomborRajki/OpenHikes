//
//  CuratedTrailQuery.swift
//  OpenHikes
//
//  What this app asks OpenStreetMap for when a hiker searches an area, and
//  the two reasons it is asked in two passes.
//
//  **The listing pass must not carry geometry.** Measured against the real
//  API: `out geom` over one Berchtesgaden search box returned 7.0 MB for 105
//  route relations — 121,496 points — which is not a thing to spend on a list
//  somebody may scroll straight past. `out tags bb` over the identical box
//  returned **43.7 KB**, and carries every tag *plus* a bounding box per
//  relation. So the list is built from that, and lines are fetched afterwards
//  for the handful of routes that survive the filter below.
//
//  **The bounding box is also the day-hike filter, and that is what makes the
//  feature honest.** `route=hiking` relations are not day hikes. The same box
//  held five routes of 57, 170, 237, 411 and 531 km — an app that offered the
//  Maximiliansweg as somewhere to walk on Saturday would be wrong about every
//  one of them. The stated `distance` tag cannot do the filtering: it is on
//  **2%** of them. The bounding box can, because it arrives free with the
//  listing pass. Measured against lengths computed from the real geometry, a
//  diagonal ceiling of ``maximumSpanMeters`` keeps 97 of 102 routes, whose
//  true lengths run 0.1–30.7 km, and rejects exactly those five.
//
//  A diagonal is a *proxy* and is deliberately generous: a switchbacked climb
//  packs 30 km of walking into a small box and is kept, while a straight
//  20 km valley path is near the limit and is also kept. What it is reliably
//  good at is the thing it is here for — throwing out the continental paths,
//  whose boxes are degrees across and not close to the line.
//

import CoreLocation
import Foundation

/// The Overpass requests a curated search makes, and the arithmetic that
/// decides which routes are worth asking about.
///
/// A separate type from the fetcher for the reason ``CommunityQueryPolicy`` is
/// separate from ``CommunityBrowser``: what is being decided here — which
/// routes count, how wide a box is worth asking for — is invisible in the
/// result and would otherwise only be testable through the network.
nonisolated enum CuratedTrailQuery {
    /// The widest search this will ask Overpass about, in metres of radius.
    ///
    /// Lower than ``CommunityQueryPolicy/maximumRadiusMeters``, and
    /// deliberately so: that ceiling is about whether *near here* still means
    /// anything, and this one is about what a volunteer-run API should be
    /// asked for in one request. The listing pass scales with the area of the
    /// box — 44 KB over a 17 × 28 km box in dense Alpine mapping — so an
    /// 80 × 80 km box is roughly 350 KB in the worst region there is, and a
    /// 300 × 300 km one is several megabytes of rows that would then be
    /// thrown away by the limit.
    ///
    /// Above this the curated half of the answer is empty and the published
    /// half is unaffected. That is the right failure: the hiker is looking at
    /// half a continent, where a list of village loops is not what they asked
    /// for anyway.
    static let maximumRadiusMeters: Double = 40_000

    /// The longest bounding-box diagonal a curated route may have, in metres.
    ///
    /// See this file's header for the measurement. 20 km rather than a round
    /// 25 or 15 because that is where the two populations actually separate in
    /// the data: the longest kept route's box is 18.9 km across and the
    /// shortest rejected one's is 55.9 km, so the line has a wide margin on
    /// both sides and is not balanced on a tie.
    static let maximumSpanMeters: Double = 20_000

    /// How many routes one search asks Overpass for geometry for.
    ///
    /// The same figure as ``CommunityBrowser``'s own page, so the two halves
    /// of a merged answer are drawn from comparable budgets. Measured cost of
    /// the geometry pass at this count: about 420 KB for routes of median
    /// size, 1.4 MB for the largest twenty-five in one box.
    static let geometryBatchLimit = 25

    /// How long Overpass is allowed to spend, in seconds, on each pass.
    ///
    /// The listing pass is a tag scan over a box and is quick; the geometry
    /// pass assembles member ways for up to ``geometryBatchLimit`` relations
    /// and is not. Both sit under the 35-second client timeout
    /// ``OverpassTrailGraphProvider`` already uses, so the server gives up
    /// before the socket does and the app gets a diagnosable answer instead of
    /// a cancelled request.
    static let listingTimeoutSeconds = 25
    static let geometryTimeoutSeconds = 30

    /// A south/west/north/east box, in degrees, as Overpass spells one.
    ///
    /// `Codable` for the reason ``CuratedTrail`` is: the box is what decides
    /// where a curated pin stands, so a stored route is not a route without
    /// it.
    struct BoundingBox: Codable, Hashable, Sendable {
        var south: Double
        var west: Double
        var north: Double
        var east: Double

        /// The four numbers in the order an Overpass filter takes them.
        var overpassLiteral: String {
            "\(south),\(west),\(north),\(east)"
        }
    }
}

// MARK: - Turning a search area into a box

nonisolated extension CuratedTrailQuery {
    private static let metresPerDegreeLatitude: Double = 111_320
    /// Where `cos(latitude)` stops being a usable divisor. Beyond it the
    /// longitude span of a fixed distance runs away to the whole world, and
    /// there is no box — a search a few hundred metres from the pole would
    /// otherwise ask about everything, and there is no hiking up there to
    /// miss.
    private static let polarLatitudeLimit: Double = 89

    /// The box that circumscribes `area`, or `nil` when the area is too wide
    /// to ask about.
    ///
    /// Circumscribing rather than inscribed, because the hiker is being
    /// offered *what is on screen*: a box inside the circle would leave routes
    /// visible on the map out of the list that claims to describe it. The
    /// corners bring in a little more than the circle, which is the harmless
    /// direction — a route just outside the radius is still somewhere the
    /// hiker can see.
    ///
    /// **Longitude here is continuous, not wrapped**: a search near the date
    /// line answers with a `west` below −180 or an `east` above 180, which is
    /// a true statement about the circle and not a box Overpass will take.
    /// ``searchBoxes(for:)`` is what turns it into one, and it is what every
    /// caller outside this file wants.
    static func circumscribingBox(for area: CommunitySearchArea) -> BoundingBox? {
        guard area.radiusMeters > 0, area.radiusMeters <= maximumRadiusMeters else {
            return nil
        }
        let latitude = area.latitude
        guard abs(latitude) < polarLatitudeLimit else { return nil }

        let latitudeSpan = area.radiusMeters / metresPerDegreeLatitude
        let longitudeSpan = area.radiusMeters
            / (metresPerDegreeLatitude * cos(latitude * .pi / 180))
        guard latitudeSpan.isFinite, longitudeSpan.isFinite else { return nil }

        let longitude = wrapped(area.longitude)
        return BoundingBox(
            south: max(-90, latitude - latitudeSpan),
            west: longitude - longitudeSpan,
            north: min(90, latitude + latitudeSpan),
            east: longitude + longitudeSpan
        )
    }

    /// The boxes a search of `area` asks Overpass about: one, or **two** where
    /// the circle crosses the antimeridian, or none where there is nothing to
    /// ask.
    ///
    /// Two rather than a clamp, which is what this used to do and which lost
    /// half the search silently. At 60°N a 40 km radius is 0.72° of longitude,
    /// so a hiker at 179.8° had everything from 180° east to −179.48° dropped
    /// from a list that said it described what was around them — while the
    /// published half, which reaches CloudKit through `distanceToLocation:`,
    /// has no such seam and answered about the whole circle. Two halves
    /// describing different areas is the one thing a merged list may not do.
    ///
    /// Still **one request**: Overpass takes a union of filters, so the two
    /// boxes cost the same round trip as one — see ``listingQuery(in:)``.
    static func searchBoxes(for area: CommunitySearchArea) -> [BoundingBox] {
        guard let box = circumscribingBox(for: area) else { return [] }
        if box.west < -180 {
            return [
                BoundingBox(south: box.south, west: box.west + 360, north: box.north, east: 180),
                BoundingBox(south: box.south, west: -180, north: box.north, east: box.east),
            ]
        }
        if box.east > 180 {
            return [
                BoundingBox(south: box.south, west: box.west, north: box.north, east: 180),
                BoundingBox(south: box.south, west: -180, north: box.north, east: box.east - 360),
            ]
        }
        return [box]
    }

    /// `longitude` brought into −180...180.
    ///
    /// A map can hand back a longitude that has wrapped several times over
    /// while the hiker dragged east, and 540° is a real value meaning 180°.
    /// Normalised before the span is applied rather than after, so the split
    /// below has only the one seam to look for.
    private static func wrapped(_ longitude: Double) -> Double {
        guard longitude.isFinite else { return longitude }
        let shifted = (longitude + 180).truncatingRemainder(dividingBy: 360)
        return (shifted < 0 ? shifted + 360 : shifted) - 180
    }
}

// MARK: - The two queries

nonisolated extension CuratedTrailQuery {
    /// Every named hiking route whose relation touches `box`, tags and
    /// bounding box only.
    ///
    /// `["name"]` is part of the filter rather than something checked after
    /// the fact, because a route with no name is a row with nothing to say:
    /// 103 of 106 relations in the measured box carry one, so the filter costs
    /// almost nothing and saves decoding the rest.
    ///
    /// `out tags bb` is the whole reason a browse can afford this — see the
    /// file header. Note it is `bb` and not `center`: the centre alone would
    /// place a pin, and the *box* is what decides whether a route is a day
    /// hike at all.
    ///
    /// A union of filters, and a union even when there is one box, because
    /// that is what lets an antimeridian search be a single request rather
    /// than two — see ``searchBoxes(for:)``. A union of one is exactly the
    /// query it encloses. `nil` for no boxes at all: a caller with nothing to
    /// ask about should not be making a request.
    static func listingQuery(in boxes: [BoundingBox]) -> String? {
        guard !boxes.isEmpty else { return nil }
        let filters = boxes
            .map { "  rel[\"route\"=\"hiking\"][\"name\"](\($0.overpassLiteral));" }
            .joined(separator: "\n")
        return """
        [out:json][timeout:\(listingTimeoutSeconds)];
        (
        \(filters)
        );
        out tags bb;
        """
    }

    /// The member geometry of the relations named by `ids`.
    ///
    /// By id rather than by box, which is what keeps this bounded: the
    /// expensive pass runs over the routes that already survived the filter,
    /// never over everything the area holds.
    ///
    /// `out geom` puts the coordinates inline on each member way, so no
    /// second resolution of node ids is needed — the difference between one
    /// request and three. Empty `ids` produces no query at all; a caller with
    /// nothing to ask about should not be making a request.
    static func geometryQuery(ids: [Int64]) -> String? {
        guard !ids.isEmpty else { return nil }
        let list = ids.prefix(geometryBatchLimit)
            .map(String.init)
            .joined(separator: ",")
        return """
        [out:json][timeout:\(geometryTimeoutSeconds)];
        rel(id:\(list));
        out geom;
        """
    }
}

// MARK: - Which routes are day hikes

nonisolated extension CuratedTrailQuery {
    /// The diagonal of `box` on the ground, in metres.
    ///
    /// Great-circle on each edge rather than a degree-space hypotenuse,
    /// because a degree of longitude is 111 km at the equator and 56 km at
    /// 60°N — a filter that ignored that would be twice as strict in Norway as
    /// in Italy.
    static func spanMeters(of box: BoundingBox) -> Double {
        let height = RouteGeometry.distanceMeters(
            from: CLLocationCoordinate2D(latitude: box.south, longitude: box.west),
            to: CLLocationCoordinate2D(latitude: box.north, longitude: box.west)
        )
        let width = RouteGeometry.distanceMeters(
            from: CLLocationCoordinate2D(latitude: box.south, longitude: box.west),
            to: CLLocationCoordinate2D(latitude: box.south, longitude: box.east)
        )
        return (height * height + width * width).squareRoot()
    }

    /// Whether a route with this bounding box is a day hike.
    ///
    /// See the file header for what this is standing in for and why it is
    /// allowed to be a proxy.
    static func isDayHike(box: BoundingBox) -> Bool {
        let span = spanMeters(of: box)
        return span.isFinite && span <= maximumSpanMeters
    }

    /// The centre of `box`, which is where a curated route's pin stands.
    ///
    /// Deliberately *not* the same rule a published hike follows —
    /// ``CommunitySubmissionDraft/startCoordinate`` uses the first point of
    /// the route, on the argument that a hiker searching near a place wants a
    /// trailhead to set off from. A relation's member ways are in whatever
    /// order they were added, so its "first" point is not a trailhead and
    /// carries no meaning at all; the centre of the box is at least a true
    /// statement about where the route is. The listing pass has no geometry to
    /// do better with, and by the time it does the pin is already placed.
    static func centre(of box: BoundingBox) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (box.south + box.north) / 2,
            longitude: (box.west + box.east) / 2
        )
    }
}
