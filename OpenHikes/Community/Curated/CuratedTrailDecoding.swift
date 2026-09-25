//
//  CuratedTrailDecoding.swift
//  OpenHikes
//
//  Turning the two Overpass responses into rows and lines.
//
//  The decoding itself is ordinary. What is not, and what this file mostly
//  exists for, is **assembling a relation's member ways into one walkable
//  line** — because a `route=hiking` relation is a *set* of ways, not a path.
//  The ways arrive in whatever order somebody added them, each drawn in
//  whatever direction it was surveyed, and a route that is one continuous walk
//  on the ground is routinely a bag whose members only make sense once their
//  endpoints are matched up.
//
//  Measured on the 97 day-hike relations of one Berchtesgaden box: taking the
//  members **in the order Overpass returns them** and joining each to the
//  previous produces a single connected line for only **46** of them. Matching
//  endpoints across the whole set instead produces one for **74**, and for 76
//  of the rest the largest connected run is already 95% of the route. So
//  member order is not usable and endpoint matching is, which is the whole
//  design below.
//
//  What member order *does* carry is a `role`, and that one is not optional
//  reading: a relation holds the variants, the approaches and the summit
//  excursions alongside the path, and endpoint matching cannot tell them
//  apart. See ``CuratedTrailDecoding/mainRoles``.
//
//  ## Why the largest run, and why some routes are dropped
//
//  What survives is the longest connected run and nothing else, because
//  ``CommunityRouteLine`` is one polyline: drawing three disconnected runs as
//  one line puts a straight stroke across a valley the path does not cross,
//  and a hiker cannot tell that stroke from a trail. The distance on the row
//  is then measured from *exactly* the line that is drawn — the rule
//  ``CommunityImport`` already states for a published hike, that a stated
//  length disagreeing with its own polyline is wrong in the one place anybody
//  can see it.
//
//  That leaves the genuinely fragmented ones, and they are **dropped rather
//  than shown short**. A relation whose longest run is a third of it is not a
//  trail this app can draw; showing a third of the Almbachklamm under the
//  Almbachklamm's name, with its from/to and its waymark beside it, is a
//  quieter kind of wrong than showing nothing. ``minimumConnectedShare`` is
//  where that line is drawn, and it costs six of 97 in the measured box.
//

import Algorithms
import CoreLocation
import Foundation
import OpenHikesData
import OpenHikesShared

/// One hiking route as OpenStreetMap holds it, before it is a listing.
///
/// The listing pass and the geometry pass fill different halves of this and
/// are deliberately separable: the tags and the box arrive for every route in
/// the area, and the line arrives only for the few that survive the filter.
/// `Codable` because it is written to disk between launches — see
/// ``CuratedTrailStore``, which is the only thing that encodes one.
nonisolated struct CuratedTrail: Codable, Hashable, Sendable {
    var relationID: Int64
    var name: String
    var tags: [String: String]
    var box: CuratedTrailQuery.BoundingBox
    /// The assembled line, or empty until the geometry pass has run.
    var route: [RouteCoordinate]

    /// Where this route's pin stands.
    ///
    /// The box's centre until there is a line, and the box's centre
    /// afterwards too — see ``CuratedTrailQuery/centre(of:)`` for why a
    /// relation's first point is not a trailhead and must not be used as one.
    var coordinate: CLLocationCoordinate2D {
        CuratedTrailQuery.centre(of: box)
    }

    /// The length of the line that is actually drawn, in metres.
    ///
    /// Measured rather than read off the `distance` tag, which is present on
    /// 2% of relations and is sometimes a string like `"4.6 km"`. Zero until
    /// the geometry pass has run.
    var distanceMeters: Double {
        CommunityImport.routeLength(of: route)
    }

    /// What OpenStreetMap says about this route besides its line.
    var facts: CuratedTrailFacts {
        CuratedTrailFacts(tags: tags, route: route)
    }
}

nonisolated enum CuratedTrailDecoding {
    /// The smallest share of a relation's assembled length that its longest
    /// connected run may be, for the route to be offered at all.
    ///
    /// See this file's header. Measured against one Berchtesgaden box: 0.6
    /// keeps 92 of 97 and drops six whose longest run is 0.32–0.58 of the
    /// route. Raising it to 0.8 costs another five for very little, and
    /// lowering it to 0.5 admits a route that is mostly missing.
    static let minimumConnectedShare: Double = 0.6

    /// How close two way ends must be to be the same place, in decimal
    /// degrees of rounding.
    ///
    /// Seven places is about a centimetre, and the matching is exact at that
    /// resolution rather than a distance comparison. That is not an
    /// approximation of a tolerance — it is the right test: ways in a relation
    /// **share OSM nodes**, and Overpass emits a shared node's coordinate
    /// identically on both ways carrying it. Measured against a 30-metre
    /// distance-based matcher over the same box, exact matching assembles 74
    /// single-run routes against its 75, for a fraction of the work: endpoint
    /// lookup becomes a dictionary hit rather than a scan of every remaining
    /// way, which is what keeps a 133-way relation from being quadratic.
    static let coordinatePlaces: Double = 1e7

    /// The member roles that are the route itself rather than something
    /// hanging off it.
    ///
    /// A `route=hiking` relation does not only hold the path: it also holds
    /// the `alternative` that rejoins it two valleys later, the `approach`
    /// from the car park, the `excursion` up to the summit and back. Those
    /// are real ways at real coordinates, and a matcher that only looks at
    /// endpoints cannot tell them from the route — it will happily follow a
    /// variant, and then the drawn line and the ``CuratedTrail/distanceMeters``
    /// measured from it describe a walk nobody tagged.
    ///
    /// They cost the fragmented ones too. Several disconnected `approach`
    /// spurs each become their own run, inflating the denominator in
    /// ``assemble(_:)`` until a perfectly connected route falls under
    /// ``minimumConnectedShare`` and is dropped as too broken to draw.
    ///
    /// An allowlist rather than a list of branch roles to reject, because the
    /// vocabulary of things that hang off a route is open and the vocabulary
    /// of things that *are* one is not: empty is the overwhelming majority,
    /// `forward` and `backward` are the one-way halves of a route that splits
    /// around an obstacle, and `main` is the explicit spelling of empty.
    static let mainRoles: Set<String> = ["", "forward", "backward", "main"]
}

// MARK: - The listing pass

nonisolated extension CuratedTrailDecoding {
    /// The routes in an `out tags bb` response that are worth offering.
    ///
    /// Filtered here rather than by the caller because the two reasons to
    /// reject are both properties of the decoded element: a route with no
    /// usable name has nothing to put in a row, and one whose box is too big
    /// is not a day hike — see ``CuratedTrailQuery/isDayHike(box:)``.
    static func trails(fromListing data: Data) throws -> [CuratedTrail] {
        let response = try OverpassRequest.decode(Response.self, from: data)
        return response.elements.compactMap { element -> CuratedTrail? in
            guard element.type == "relation",
                  let bounds = element.bounds,
                  let name = BoundedText.bounded(element.tags["name"], to: .title)
            else { return nil }
            let box = CuratedTrailQuery.BoundingBox(
                south: bounds.minlat,
                west: bounds.minlon,
                north: bounds.maxlat,
                east: bounds.maxlon
            )
            guard CuratedTrailQuery.isDayHike(box: box) else { return nil }
            return CuratedTrail(
                relationID: element.id,
                name: name,
                tags: element.tags,
                box: box,
                route: []
            )
        }
    }
}

// MARK: - The geometry pass

nonisolated extension CuratedTrailDecoding {
    /// Each relation in an `out geom` response, complete, keyed by relation id.
    ///
    /// Complete because `out geom` carries the relation's `tags` and `bounds`
    /// alongside its members' coordinates — so one request answers everything
    /// about a route and there is never a second one to reconcile against.
    /// That is also what lets a hike be opened without having been listed
    /// first: the geometry pass is self-sufficient.
    ///
    /// **Partial by contract**, the same promise
    /// ``CommunityTransporting/outlines(for:)`` makes: a relation whose ways
    /// could not be assembled into one sufficiently connected run is absent
    /// from the answer rather than present with a broken line. A caller draws
    /// what it got.
    ///
    /// The day-hike filter is deliberately *not* applied here. It belongs to
    /// the listing pass, where it decides what to offer; by the time a line is
    /// being fetched the hiker has already chosen this route, and refusing to
    /// draw what they opened would be the filter overreaching.
    static func trails(fromGeometry data: Data) throws -> [Int64: CuratedTrail] {
        let response = try OverpassRequest.decode(Response.self, from: data)
        var trails: [Int64: CuratedTrail] = [:]
        for element in response.elements where element.type == "relation" {
            guard let bounds = element.bounds,
                  let name = BoundedText.bounded(element.tags["name"], to: .title)
            else { continue }
            let line = assemble(routeWays(of: element))
            guard line.count > 1 else { continue }
            trails[element.id] = CuratedTrail(
                relationID: element.id,
                name: name,
                tags: element.tags,
                box: CuratedTrailQuery.BoundingBox(
                    south: bounds.minlat,
                    west: bounds.minlon,
                    north: bounds.maxlat,
                    east: bounds.maxlon
                ),
                route: line.map(RouteCoordinate.init)
            )
        }
        return trails
    }

    /// The member ways of `element` that make up the route itself.
    ///
    /// Roled first — see ``mainRoles`` — and only then reduced to
    /// coordinates, because a branch way is indistinguishable from the route
    /// once it is a bag of points.
    ///
    /// **Falls back to every way when no member carries a main role.** The
    /// allowlist is drawn from the roles this feature was measured against,
    /// and a region tagged in a convention nobody here has seen would
    /// otherwise lose its line entirely. Drawing a route assembled from
    /// unfamiliar roles is a smaller wrong than dropping a trail that is
    /// tagged, named and waymarked.
    static func routeWays(of element: Element) -> [[CLLocationCoordinate2D]] {
        let ways = element.members.filter { $0.type == "way" }
        let main = ways.filter { mainRoles.contains($0.role) }
        return (main.isEmpty ? ways : main)
            .map { member in
                member.geometry.compactMap { point -> CLLocationCoordinate2D? in
                    guard Mercator.isRepresentable(
                        latitude: point.lat,
                        longitude: point.lon
                    ) else { return nil }
                    return CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
                }
            }
            .filter { $0.count > 1 }
    }

    /// The longest connected run through `ways`, or **empty** when no run is a
    /// large enough share of the whole.
    ///
    /// Empty rather than `nil` because the two mean the same thing to every
    /// caller — there is no line to draw — and an optional collection makes a
    /// reader check for both.
    ///
    /// Endpoint matching across the entire set rather than in member order —
    /// see this file's header for the measurement that decided it. The
    /// dictionary of unused ends is what keeps this linear: growing a run asks
    /// "is there an unused way starting or ending exactly here?", which is a
    /// lookup, where a tolerance-based matcher has to scan.
    static func assemble(
        _ ways: [[CLLocationCoordinate2D]]
    ) -> [CLLocationCoordinate2D] {
        guard !ways.isEmpty else { return [] }
        var endsByKey: [Endpoint: [Int]] = [:]
        for (index, way) in ways.enumerated() {
            guard let first = way.first, let last = way.last else { continue }
            endsByKey[Endpoint(first), default: []].append(index)
            endsByKey[Endpoint(last), default: []].append(index)
        }

        var used = [Bool](repeating: false, count: ways.count)
        var runs: [[CLLocationCoordinate2D]] = []
        for seed in ways.indices where !used[seed] {
            used[seed] = true
            runs.append(grow(from: ways[seed], ways: ways, endsByKey: endsByKey, used: &used))
        }

        let lengths = runs.map(routeLength)
        let total = lengths.reduce(0, +)
        guard total > 0,
              let best = zip(runs, lengths).max(by: { $0.1 < $1.1 }),
              best.1 / total >= minimumConnectedShare
        else { return [] }
        return best.0
    }
}

// MARK: - Growing one run

nonisolated private extension CuratedTrailDecoding {
    /// A way end, quantised so two ways sharing an OSM node hash alike.
    struct Endpoint: Hashable {
        let latitude: Int64
        let longitude: Int64

        init(_ coordinate: CLLocationCoordinate2D) {
            latitude = Int64((coordinate.latitude * coordinatePlaces).rounded())
            longitude = Int64((coordinate.longitude * coordinatePlaces).rounded())
        }
    }

    /// Extends `seed` at both ends for as long as an unused way joins on.
    ///
    /// Both ends, because a run is grown from an arbitrary seed: the way this
    /// started from is as likely to be in the middle of the route as at either
    /// end of it, and growing forwards only would cut every route at whichever
    /// way happened to come first.
    static func grow(
        from seed: [CLLocationCoordinate2D],
        ways: [[CLLocationCoordinate2D]],
        endsByKey: [Endpoint: [Int]],
        used: inout [Bool]
    ) -> [CLLocationCoordinate2D] {
        var run = seed
        var growing = true
        while growing {
            growing = false
            if let tail = run.last {
                let next = take(at: Endpoint(tail), ways: ways, endsByKey: endsByKey, used: &used)
                if !next.isEmpty {
                    // Oriented so the joining end is the one already in the
                    // run, then its first point dropped — it is the point we
                    // are standing on.
                    let oriented = Endpoint(next.last ?? tail) == Endpoint(tail)
                        ? Array(next.reversed())
                        : next
                    run.append(contentsOf: oriented.dropFirst())
                    growing = true
                    continue
                }
            }
            if let head = run.first {
                let previous = take(
                    at: Endpoint(head),
                    ways: ways,
                    endsByKey: endsByKey,
                    used: &used
                )
                if !previous.isEmpty {
                    let oriented = Endpoint(previous.first ?? head) == Endpoint(head)
                        ? Array(previous.reversed())
                        : previous
                    run.insert(contentsOf: oriented.dropLast(), at: 0)
                    growing = true
                }
            }
        }
        return run
    }

    /// Claims an unused way touching `endpoint`, or answers empty.
    static func take(
        at endpoint: Endpoint,
        ways: [[CLLocationCoordinate2D]],
        endsByKey: [Endpoint: [Int]],
        used: inout [Bool]
    ) -> [CLLocationCoordinate2D] {
        guard let candidates = endsByKey[endpoint] else { return [] }
        for index in candidates where !used[index] {
            used[index] = true
            return ways[index]
        }
        return []
    }

    static func routeLength(_ points: [CLLocationCoordinate2D]) -> Double {
        guard points.count > 1 else { return 0 }
        return points.adjacentPairs().reduce(0) { total, pair in
            total + RouteGeometry.distanceMeters(from: pair.0, to: pair.1)
        }
    }
}

// MARK: - The wire format

nonisolated extension CuratedTrailDecoding {
    struct Bounds: Decodable {
        let minlat: Double
        let minlon: Double
        let maxlat: Double
        let maxlon: Double
    }

    struct GeometryPoint: Decodable {
        let lat: Double
        let lon: Double
    }

    /// A relation member. Unlike ``OverpassTrailGraphProvider/OverpassMember``
    /// this carries `geometry`, which is what `out geom` puts inline and what
    /// makes the second pass one request rather than three.
    ///
    /// It also carries `role`, which is not decoration: see
    /// ``CuratedTrailDecoding/mainRoles`` for what a route relation uses it
    /// to say and why ignoring it draws a walk nobody tagged.
    struct Member: Decodable {
        let type: String
        let role: String
        let geometry: [GeometryPoint]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
            role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
            geometry = try container.decodeIfPresent([GeometryPoint].self, forKey: .geometry) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case type = "type"
            case role = "role"
            case geometry = "geometry"
        }
    }

    struct Element: Decodable {
        let type: String
        let id: Int64
        let tags: [String: String]
        let bounds: Bounds?
        let members: [Member]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            id = try container.decode(Int64.self, forKey: .id)
            tags = try container.decodeIfPresent([String: String].self, forKey: .tags) ?? [:]
            bounds = try container.decodeIfPresent(Bounds.self, forKey: .bounds)
            members = try container.decodeIfPresent([Member].self, forKey: .members) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case type = "type"
            case id = "id"
            case tags = "tags"
            case bounds = "bounds"
            case members = "members"
        }
    }

    nonisolated struct Response: OverpassAnswer {
        let elements: [Element]
        /// What the server has to say about a query it did not finish. See
        /// ``OverpassRequest/decode(_:from:)`` for why reading it is not
        /// optional, and why a failure leaves as a typed error the caller can
        /// log and walk past, keeping the published half of the browse list
        /// standing.
        let remark: String?
    }
}
