//
//  CuratedTrailQuery.swift
//  OpenHikes
//
//  What this app asks OpenStreetMap for when a hiker searches an area: one
//  request for the map most searches cover, two for a wide one, and why.
//
//  **The lines come with the list when the area is small, and only then.**
//  Measured against the real API: `out geom` over one Berchtesgaden search box
//  returned 7.0 MB for 105 route relations — 121,496 points — while `out tags
//  bb` over the identical box returned **43.7 KB**, carrying every tag *plus* a
//  bounding box per relation. That is why the list was built from the cheap
//  pass and the lines fetched afterwards, by id, for the handful of routes
//  that survived the filter below — and it is still how a wide area is asked.
//
//  But a second request is not priced in bytes. Measured on 2026-10-21,
//  `overpass-api.de` held every request it admitted for 25–52 seconds whatever
//  it asked — a query for one node waited as long as a search did — so two
//  passes were two waits: a median of 68 seconds to a drawn list, against 37
//  for one request carrying the lines, alternating the two over eight rounds.
//  What made the seven megabytes was the box rather than the pass: a square
//  never narrower than twenty kilometres, with the continental paths in it.
//  The map above the sheet is a fraction of that — see ``CommunitySearchArea``
//  — and every line in it came to 7–400 KB gzipped across the four areas
//  measured. So a search up to ``maximumOneRequestAreaSquareMeters`` asks once
//  and gets its lines; a wider one keeps the two passes. ``areaRequest(in:)``
//  is where that is decided.
//
//  **The continental paths are left out before their boxes are measured.**
//  Both shapes of search filter on ``maximumMemberCount``, because Overpass
//  computes a relation's box — and draws its line — from every member it has,
//  and the paths no day hike resembles have thousands: 609 to 4,471 over the
//  Berchtesgaden and Pilis boxes, where the largest of 832 day hikes measured
//  had 209. Dropping them halved the listing pass's time on the server, and
//  they were never going to survive the diagonal below anyway.
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
import OpenHikesData

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
    /// **The app's zoom ceiling as well, and this is where it is decided.**
    /// ``CommunityQueryPolicy/maximumRadiusMeters`` is spelled as this value
    /// rather than as a number of its own — see *One ceiling, and it is
    /// OpenStreetMap's* in that file. The figure is set by the source that
    /// minds being asked: the listing pass scales with the *area* of the box
    /// — 44 KB over a 17 × 28 km box in dense Alpine mapping — so an 80 × 80 km
    /// box is roughly 350 KB in the worst region there is, and a 300 × 300 km
    /// one is several megabytes of rows the limit would then throw away.
    ///
    /// There used to be two ceilings, 150 km there and 40 km here, described
    /// as a deliberate difference. It was a gap: between them the pill was
    /// enabled, a tap spent a CloudKit query, and this half answered `[]` with
    /// no failure to report, so a hiker looking at 100 km of map got no trails
    /// and nothing saying that zooming in was the answer.
    ///
    /// The guard below is therefore unreachable from the app — the policy
    /// refuses a wider region before anything is committed — and it stays as
    /// the contract for callers that are not the policy: a search wider than
    /// this answers `[]` rather than asking, which is the right answer when
    /// the hiker is looking at half a continent.
    static let maximumRadiusMeters: Double = 40_000

    /// The longest bounding-box diagonal a curated route may have, in metres.
    ///
    /// See this file's header for the measurement. 20 km rather than a round
    /// 25 or 15 because that is where the two populations actually separate in
    /// the data: the longest kept route's box is 18.9 km across and the
    /// shortest rejected one's is 55.9 km, so the line has a wide margin on
    /// both sides and is not balanced on a tie.
    static let maximumSpanMeters: Double = 20_000

    /// The most members a relation may have and still be asked about.
    ///
    /// See this file's header for the measurement: 209 for the largest day
    /// hike of 832, 609 for the smallest continental path. Five hundred sits
    /// between them with room on the day-hike side, which is the side a
    /// mistake would cost — a route left out here is never offered at all,
    /// where one let through is only measured and thrown away by
    /// ``isDayHike(box:)``.
    static let maximumMemberCount = 500

    /// The widest search, in square metres of box, whose lines are asked for
    /// with its list.
    ///
    /// Up to here the second request costs more than the lines do; past it the
    /// lines start to cost more than the request. Three hundred square
    /// kilometres is the map above a half-height sheet up to a view about
    /// seventeen kilometres across. The densest box measured — the Pilis hills,
    /// 141 km² — carried 55 day hikes in 2.9 MB of JSON, 0.4 MB gzipped, so the
    /// worst case at the ceiling is under a megabyte on the wire, against a
    /// second turn in a queue that held every admitted request for at least 25
    /// seconds. See this file's header.
    static let maximumOneRequestAreaSquareMeters: Double = 300_000_000

    /// How many routes one search keeps lines for.
    ///
    /// The same figure as ``CommunityBrowser``'s own page, so the two halves
    /// of a merged answer are drawn from comparable budgets. A one-request
    /// search brings the lines of every route in its box and keeps this many
    /// of them; a wide one asks for exactly this many by id. Measured cost of
    /// that geometry pass: about 420 KB for routes of median size, 1.4 MB for
    /// the largest twenty-five in one box.
    static let geometryBatchLimit = 25

    /// How long Overpass is allowed to spend, in seconds, on each pass.
    ///
    /// The listing pass is a tag scan over a box and is quick; the geometry
    /// pass assembles member ways for up to ``geometryBatchLimit`` relations
    /// and is not. A one-request search draws every line in its box, so it
    /// takes the geometry pass's figure. The client's own timeout is derived
    /// from whichever is sent, by ``OverpassRequest/idleTimeout(forServerTimeout:)``,
    /// which allows for the queue wait and the transfer on top of it — so the
    /// server gives up before the socket does and the app gets a diagnosable
    /// answer instead of a cancelled request.
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
    /// Where `cos(latitude)` stops being a usable divisor. Beyond it the
    /// longitude span of a fixed distance runs away to the whole world, and
    /// there is no box — a search a few hundred metres from the pole would
    /// otherwise ask about everything, and there is no hiking up there to
    /// miss.
    private static let polarLatitudeLimit: Double = 89

    /// The box that circumscribes `area`, or `nil` when the area is too wide
    /// to ask about.
    ///
    /// What an area that is only a circle is asked about — a place search
    /// along a stretch of a route is, through ``TrailPointQuery`` — while one
    /// the map handed over carries the rectangle the hiker could see, and is
    /// asked about that instead: see ``visibleBox(for:)``.
    ///
    /// Circumscribing rather than inscribed, because a box inside the circle
    /// would leave out routes the circle was meant to reach. The corners bring
    /// in a little more than the circle, which is the harmless direction.
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

        // ``RouteGeometry``'s figure rather than one of this file's own:
        // a circumscribing box is exactly the buffer that constant is
        // for, and a second spelling of it is a second thing to keep
        // right.
        let metersPerDegreeLatitude = RouteGeometry.metersPerDegreeLatitude
        let latitudeSpan = area.radiusMeters / metersPerDegreeLatitude
        let longitudeSpan = area.radiusMeters
            / (metersPerDegreeLatitude * cos(latitude * .pi / 180))
        guard latitudeSpan.isFinite, longitudeSpan.isFinite, area.longitude.isFinite else { return nil }

        // Brought into −180...180 before the span is applied rather than
        // after, so the split in ``searchBoxes(for:)`` has only the one seam to
        // look for. A map can hand back a longitude that has wrapped several
        // times over while the hiker dragged east, and 540° is a real value
        // meaning 180°.
        let longitude = RouteGeometry.normalizedLongitude(area.longitude)
        return BoundingBox(
            south: max(-90, latitude - latitudeSpan),
            west: longitude - longitudeSpan,
            north: min(90, latitude + latitudeSpan),
            east: longitude + longitudeSpan
        )
    }

    /// The rectangle the hiker could see when they asked about `area`, or
    /// `nil` when it carries none or there is nothing in it to ask about.
    ///
    /// Exactly the span the map handed over: no floor and no square around it.
    /// The radius beside it is CloudKit's question, floored where that server
    /// stops telling distances apart — see ``CommunitySearchArea`` — and
    /// Overpass, which answers a box exactly, has no such floor to inherit.
    ///
    /// The ceiling still holds, measured the way
    /// ``CommunityQueryPolicy/visibleRadiusMeters(for:)`` measures the region
    /// the span came from — half the longer edge, on the ground — so the two
    /// cannot disagree about which rectangles are too wide. Longitude is
    /// continuous here for the reason ``circumscribingBox(for:)`` gives.
    static func visibleBox(for area: CommunitySearchArea) -> BoundingBox? {
        guard let span = area.visibleSpan,
              span.latitudeDelta > 0, span.longitudeDelta > 0,
              span.latitudeDelta.isFinite, span.longitudeDelta.isFinite,
              area.longitude.isFinite, abs(area.latitude) < polarLatitudeLimit
        else { return nil }
        let metersPerDegree = RouteGeometry.metersPerDegreeLatitude
        let halfHeight = span.latitudeDelta / 2 * metersPerDegree
        let halfWidth = span.longitudeDelta / 2 * metersPerDegree * cos(area.latitude * .pi / 180)
        guard max(halfHeight, halfWidth) <= maximumRadiusMeters else { return nil }
        let longitude = RouteGeometry.normalizedLongitude(area.longitude)
        return BoundingBox(
            south: max(-90, area.latitude - span.latitudeDelta / 2),
            west: longitude - span.longitudeDelta / 2,
            north: min(90, area.latitude + span.latitudeDelta / 2),
            east: longitude + span.longitudeDelta / 2
        )
    }

    /// The boxes a search of `area` asks Overpass about — the rectangle the
    /// hiker could see when the area carries one, the square around its circle
    /// when it does not: one box, or **two** where it crosses the antimeridian,
    /// or none where there is nothing to ask.
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
    /// boxes cost the same round trip as one — see ``areaRequest(in:)``.
    static func searchBoxes(for area: CommunitySearchArea) -> [BoundingBox] {
        let asked = area.visibleSpan == nil ? circumscribingBox(for: area) : visibleBox(for: area)
        guard let box = asked else { return [] }
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
}

// MARK: - The queries

nonisolated extension CuratedTrailQuery {
    /// What one area search sends: the query, the time it gives the server,
    /// and whether the routes come back with their lines.
    struct AreaRequest: Equatable, Sendable {
        let query: String
        let timeoutSeconds: Int
        /// Whether this is the whole search — every route in the box with its
        /// line, see ``listingWithLinesQuery(in:)`` — rather than the listing
        /// pass a second request completes.
        let drawsLines: Bool
    }

    /// The request a search of `boxes` makes, or `nil` when there is nothing
    /// to ask about.
    ///
    /// One request carrying the lines up to
    /// ``maximumOneRequestAreaSquareMeters`` of box, and the listing pass of
    /// two beyond it. See this file's header for why the line is drawn on the
    /// area: it is what the size of the lines scales with, and the one thing
    /// known before anything has been asked.
    static func areaRequest(in boxes: [BoundingBox]) -> AreaRequest? {
        let area = boxes.reduce(0) { $0 + areaSquareMeters(of: $1) }
        guard area <= maximumOneRequestAreaSquareMeters else {
            return listingQuery(in: boxes).map { query in
                AreaRequest(query: query, timeoutSeconds: listingTimeoutSeconds, drawsLines: false)
            }
        }
        return listingWithLinesQuery(in: boxes).map { query in
            AreaRequest(query: query, timeoutSeconds: geometryTimeoutSeconds, drawsLines: true)
        }
    }

    /// How much ground a search box covers, in square metres.
    ///
    /// Flat rather than spherical, because the boxes that decide anything are
    /// tens of kilometres across, where the two differ by less than the width
    /// of a road. Read off a box ``searchBoxes(for:)`` has already split, whose
    /// `east` is never west of its `west`.
    static func areaSquareMeters(of box: BoundingBox) -> Double {
        let metersPerDegree = RouteGeometry.metersPerDegreeLatitude
        let middle = (box.south + box.north) / 2
        let height = (box.north - box.south) * metersPerDegree
        let width = (box.east - box.west) * metersPerDegree * cos(middle * .pi / 180)
        return height * width
    }

    /// Every named hiking route whose relation touches `box`, tags and
    /// bounding box only: the first of a wide search's two passes.
    ///
    /// `["name"]` is part of the filter rather than something checked after
    /// the fact, because a route with no name is a row with nothing to say:
    /// 103 of 106 relations in the measured box carry one, so the filter costs
    /// almost nothing and saves decoding the rest. So is
    /// ``maximumMemberCount`` — see ``routeFilter(in:)``.
    ///
    /// `out tags bb` is the whole reason a wide browse can afford this — see
    /// the file header. Note it is `bb` and not `center`: the centre alone
    /// would place a pin, and the *box* is what decides whether a route is a
    /// day hike at all.
    ///
    /// A union of filters, and a union even when there is one box, because
    /// that is what lets an antimeridian search be a single request rather
    /// than two — see ``searchBoxes(for:)``. A union of one is exactly the
    /// query it encloses. `nil` for no boxes at all: a caller with nothing to
    /// ask about should not be making a request.
    static func listingQuery(in boxes: [BoundingBox]) -> String? {
        guard !boxes.isEmpty else { return nil }
        return """
        [out:json][timeout:\(listingTimeoutSeconds)];
        (
        \(boxes.map(routeFilter(in:)).joined(separator: "\n"))
        );
        out tags bb;
        """
    }

    /// The same routes as ``listingQuery(in:)``, each with its line: both
    /// passes of a small search, asked as one.
    ///
    /// `out geom` is what the geometry pass already asks for — the coordinates
    /// inline on each member way — and it carries every tag and the box as
    /// well, so this answers everything the two passes would. By box rather
    /// than by id, which is affordable only because ``areaRequest(in:)`` keeps
    /// it to small ones. The day-hike filter still runs on the answer: see
    /// ``CuratedTrailDecoding/trails(fromListingWithLines:)``.
    static func listingWithLinesQuery(in boxes: [BoundingBox]) -> String? {
        guard !boxes.isEmpty else { return nil }
        return """
        [out:json][timeout:\(geometryTimeoutSeconds)];
        (
        \(boxes.map(routeFilter(in:)).joined(separator: "\n"))
        );
        out geom;
        """
    }

    /// The one filter both shapes of search are written with, so they cannot
    /// disagree about which routes an area holds.
    ///
    /// The member count is a number every relation carries, so testing it
    /// takes the continental paths out of the set before `out` measures a box
    /// — or draws a line — from every one of their members. That output was
    /// where half of the listing pass's time went. See ``maximumMemberCount``.
    private static func routeFilter(in box: BoundingBox) -> String {
        "  rel[\"route\"=\"hiking\"][\"name\"](\(box.overpassLiteral))"
            + "(if: count_members() < \(maximumMemberCount));"
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
    /// How wide `box` is, in degrees of longitude, read the short way round.
    ///
    /// **Overpass has no antimeridian, and its bounding boxes say so.** `bb`
    /// is a plain minimum and maximum over the members' longitudes, so a route
    /// that steps across the date line comes back as `minlon −179.99,
    /// maxlon 179.99` — which read literally is a box around the entire world,
    /// and read as the mapper meant it is a sliver two hundredths of a degree
    /// wide. Nothing in the box itself distinguishes the two, and above 180°
    /// the short reading is the only one that can be a day hike: a route
    /// genuinely spanning more than half the planet is 20,000 km of walking
    /// either way round and ``isDayHike(box:)`` rejects it on the complement
    /// just as it would on the literal width.
    ///
    /// Stated once here because ``spanMeters(of:)`` and ``center(of:)`` have
    /// to agree about it. They used to agree by accident and only halfway:
    /// the span was already short, because `RouteGeometry.distanceMeters`
    /// normalises the delta it is handed, while the centre averaged the two
    /// numbers as they stood and put a Fijian trail's pin on longitude 0.
    static func longitudeSpanDegrees(of box: BoundingBox) -> Double {
        // Overpass emits `minlon <= maxlon`, so there is one direction to fix.
        let raw = box.east - box.west
        return raw > 180 ? raw - 360 : raw
    }

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
            to: CLLocationCoordinate2D(
                latitude: box.south,
                longitude: box.west + longitudeSpanDegrees(of: box)
            )
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
    ///
    /// Walked half a width east of `west` rather than averaged with `east`,
    /// which is the same arithmetic everywhere except across the date line and
    /// the whole difference there — see ``longitudeSpanDegrees(of:)``. This is
    /// the coordinate the row is sorted by, the pin stands at and
    /// ``CuratedTrailStore/trails(near:limit:)`` matches an area against, so a
    /// route that got the naive average was not merely drawn in the wrong
    /// place: it sorted as though it were 20,000 km away and could never be
    /// found in the cache again.
    static func center(of box: BoundingBox) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (box.south + box.north) / 2,
            longitude: RouteGeometry.normalizedLongitude(box.west + longitudeSpanDegrees(of: box) / 2)
        )
    }
}
