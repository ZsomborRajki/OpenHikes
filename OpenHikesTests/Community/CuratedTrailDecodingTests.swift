//
//  CuratedTrailDecodingTests.swift
//  OpenHikesTests
//
//  Turning two Overpass answers into rows and lines, and the half of that
//  which is not ordinary decoding.
//
//  A `route=hiking` relation is a **bag of ways**, not a path. Its members
//  arrive in whatever order somebody added them, each drawn in whatever
//  direction it was surveyed, so the line a hiker looks at exists only once
//  the endpoints have been matched up. The measurement that decided the design
//  says what response order is worth: over one Berchtesgaden box, joining
//  members in the order Overpass returned them produced a single connected
//  line for 46 of 97 relations, and matching endpoints across the whole set
//  produced one for 74.
//
//  That is why the stitching tests are the long half of this file. Each one is
//  a shape the real data holds — a way listed out of order, a way surveyed
//  backwards, a guidepost node sitting among the ways, a relation somebody is
//  still halfway through mapping — and each is built so that only one property
//  can explain the answer it gets. A test that merely watched a line come back
//  would pass against an implementation that took the first member and stopped.
//
//  Nothing here reaches the network, and nothing needs a seam to avoid it:
//  both entry points take `Data`, so a fixture *is* the bytes Overpass would
//  have sent. The malformed case at the bottom is one of those byte strings —
//  an overloaded Overpass answers with an HTML page under HTTP 200, which is a
//  normal operating condition rather than a bug, and has to arrive as a typed
//  error somebody can log and walk past.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Curated trail decoding")
struct CuratedTrailDecodingTests {
    // MARK: - The ground these fixtures walk over

    private static func point(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Five places up one meridian above Berchtesgaden, a hundredth of a
    /// degree — about 1112 m — apart.
    ///
    /// Deliberately on a single meridian rather than scattered: a run's length
    /// is then the number of legs in it times a known figure, so an assertion
    /// about *which* ways were assembled can be made about the length as well
    /// as the point count, and the two cannot both be satisfied by accident.
    private static let trailhead = point(47.600, 12.860)
    private static let bridge = point(47.610, 12.860)
    private static let meadow = point(47.620, 12.860)
    private static let hut = point(47.630, 12.860)
    private static let summit = point(47.640, 12.860)

    /// A way that touches none of the five above, on its own meridian.
    private static let strandedMeridian = 12.900
    private static let strandedFoot = point(47.600, strandedMeridian)
    private static let strandedHead = point(47.610, strandedMeridian)

    /// And a third piece, so a relation can be broken into three.
    private static let scatteredMeridian = 12.940
    private static let scatteredFoot = point(47.600, scatteredMeridian)
    private static let scatteredHead = point(47.610, scatteredMeridian)

    /// Where the one-point member sits — far from every line above, so its
    /// absence from an assembled route is a statement and not a coincidence.
    private static let strayLatitude = 47.700

    /// One leg of the chain on the ground, in metres: 0.01° of latitude is
    /// 1112 m on the sphere ``RouteGeometry`` measures against.
    private static let legMeters = 1112.0
    /// Five metres, which is finer than the difference any of these assertions
    /// turns on — one leg wrong moves a length by 1112.
    private static let lengthTolerance = 5.0
    /// About a decimetre, far finer than any two fixture points are apart.
    private static let coordinateTolerance = 0.000001

    /// Point counts for chains of four, three and two three-point ways, each
    /// sharing one point with the next.
    private static let wholeChainPoints = 9
    private static let threeWayPoints = 7
    private static let twoWayPoints = 5

    // MARK: - The bytes Overpass sends

    private static let relationID: Int64 = 1_001_234
    private static let namelessID: Int64 = 2_002_345
    private static let boundlessID: Int64 = 3_003_456
    private static let longDistanceID: Int64 = 4_004_567

    private static let boxSouth = 47.600
    private static let boxWest = 12.860
    private static let boxNorth = 47.640
    private static let boxEast = 12.870

    /// The tags a well-mapped Alpine route really carries.
    ///
    /// `osmc:symbol` is here in its measured shape — five colon-separated
    /// components of which only the **first** is the route's colour — because
    /// a fixture spelling it `"red"` would let a decoder that read the whole
    /// field pass.
    private static let fullTags = """
    {
        "route": "hiking",
        "name": "Almbachklamm",
        "ref": "411",
        "network": "lwn",
        "osmc:symbol": "red:red:white_bar:411:black",
        "from": "Marktschellenberg",
        "to": "Ettenberg",
        "operator": "Alpenverein"
    }
    """

    private static let alpineBounds = """
    {"minlat": \(boxSouth), "minlon": \(boxWest), "maxlat": \(boxNorth), "maxlon": \(boxEast)}
    """

    /// One member way as `out geom` writes one, with its coordinates inline.
    ///
    /// Three points rather than two, because a surveyed path bends and because
    /// an assembler that joined whole ways rather than their ends would still
    /// look right on two-point members. The middle point sits on the line
    /// between the ends, so a leg's measured length stays the figure above.
    private static func way(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> String {
        let middle = point(
            (start.latitude + end.latitude) / 2,
            (start.longitude + end.longitude) / 2
        )
        let geometry = [start, middle, end]
            .map { #"{"lat": \#($0.latitude), "lon": \#($0.longitude)}"# }
            .joined(separator: ", ")
        return #"{"type": "way", "ref": 55500, "role": "", "geometry": [\#(geometry)]}"#
    }

    /// A guidepost standing where the path leaves the road.
    ///
    /// Relation members are not all ways, and a node's position arrives as
    /// `lat`/`lon` rather than as a `geometry` array — so it decodes to no
    /// points at all, and is refused twice over.
    private static let guidepostMember = """
    {"type": "node", "ref": 3021789, "role": "guidepost", "lat": 47.6005, "lon": 12.8601}
    """

    /// A member way Overpass answered with a single coordinate. A point is not
    /// a line: it can be drawn nowhere and joined to nothing.
    private static let strayPointMember = """
    {"type": "way", "ref": 55501, "role": "", "geometry": [{"lat": \(strayLatitude), "lon": 12.95}]}
    """

    /// A member way with no `geometry` key at all, which is what an `out geom`
    /// answer holds for a way the server could not resolve.
    private static let geometrylessMember = """
    {"type": "way", "ref": 55502, "role": ""}
    """

    /// One `out geom` answer carrying one relation.
    ///
    /// Tags, bounds and member coordinates on the same element, because that
    /// is what `out geom` really returns — and the reason a hike can be opened
    /// without having been listed first.
    private static func geometryResponse(
        members: [String],
        tags: String = fullTags,
        bounds: String = alpineBounds
    ) -> Data {
        Data("""
        {
            "version": 0.6,
                "generator": "Overpass API 0.7.62",
                "elements": [
            {
                "type": "relation",
                    "id": \(relationID),
                        "bounds": \(bounds),
                        "members": [\(members.joined(separator: ", "))],
                        "tags": \(tags)
            }
                ]
        }
        """.utf8)
    }

    /// One `out tags bb` answer holding a relation for each way the listing
    /// pass can decide.
    ///
    /// One response rather than four, because that is how they arrive: a real
    /// box holds all of these at once, and the pass's job is to answer which
    /// of them is a row. Each of the three rejects is defective in exactly
    /// **one** way — the nameless one has a perfectly good box, the boundless
    /// one has a perfectly good name — so a test that watches one disappear is
    /// watching the reason it names and no other.
    ///
    /// The last is the case the day-hike filter exists for: a 63 km box, in
    /// the population that measured 57–531 km against a 20 km ceiling, where
    /// the longest kept route's box was 18.9 km and the shortest rejected
    /// one's 55.9. Its `distance` tag is present, which 2% of them are, and is
    /// read by nothing.
    private static let listingResponse = Data("""
    {
        "version": 0.6,
        "generator": "Overpass API 0.7.62",
        "elements": [
        {
            "type": "relation",
                "id": \(relationID),
                "bounds": \(alpineBounds),
                "tags": \(fullTags)
        },
        {
            "type": "relation",
                "id": \(namelessID),
                "bounds": \(alpineBounds),
                "tags": {"route": "hiking", "network": "lwn", "osmc:symbol": "yellow::yellow_diamond"}
        },
        {
            "type": "relation",
                "id": \(boundlessID),
                "tags": {"route": "hiking", "name": "Soleleitungsweg", "network": "lwn"}
        },
        {
            "type": "relation",
                "id": \(longDistanceID),
                "bounds": {"minlat": 47.4, "minlon": 12.4, "maxlat": 47.8, "maxlon": 13.0},
                "tags": {"route": "hiking", "name": "Maximiliansweg", "distance": "531 km"}
        }
        ]
    }
    """.utf8)

    /// What an overloaded Overpass sends instead of JSON, under HTTP 200.
    private static let overloadedServerPage = Data("""
    <!DOCTYPE html>
    <html><head><title>OSM3S Response</title></head>
    <body><p>Error: runtime error: open64: 0 Success /osm3s_v0.7.62_areas \
    Dispatcher_Client::request_read_and_idx::timeout.</p></body>
    </html>
    """.utf8)

    // MARK: - Reading an assembled line

    /// `route` with its ends put in a known order.
    ///
    /// Which end an assembled run starts from is not part of the contract: a
    /// relation is a bag of ways with no agreed direction, and a polyline
    /// drawn from the summit down is the same trail as one drawn from the car
    /// park up. Every fixture here climbs northwards, so orienting on latitude
    /// lets an assertion name a start and an end without pinning an
    /// implementation detail that is free to change.
    private static func northwards(_ route: [RouteCoordinate]) -> [RouteCoordinate] {
        guard let first = route.first,
              let last = route.last,
              first.latitude > last.latitude
        else { return route }
        return Array(route.reversed())
    }

    private static func isSame(_ point: RouteCoordinate, as coordinate: CLLocationCoordinate2D) -> Bool {
        abs(point.latitude - coordinate.latitude) < coordinateTolerance
            && abs(point.longitude - coordinate.longitude) < coordinateTolerance
    }

    private static func isMalformed(_ error: TrailGraphProviderError) -> Bool {
        if case .malformedGraph = error { return true }
        return false
    }

    // MARK: - The listing pass

    /// A route with no name is a row with nothing to say. The query already
    /// asks for `["name"]`, so this is the belt to that braces — a relation
    /// whose name is whitespace, or which arrives from a fixture, a cache or a
    /// future query that did not filter, must still not become a blank row.
    @Test("a route with no name is not a row")
    func namelessRouteIsDropped() throws {
        let trails = try CuratedTrailDecoding.trails(fromListing: Self.listingResponse)

        #expect(!trails.contains { $0.relationID == Self.namelessID })
    }

    /// The box is not decoration: it places the pin and it decides whether the
    /// route is a day hike at all. A relation without one can be neither
    /// shown on the map nor filtered, so there is nothing to do with it.
    @Test("a route with no bounding box is not a row")
    func boundlessRouteIsDropped() throws {
        let trails = try CuratedTrailDecoding.trails(fromListing: Self.listingResponse)

        #expect(!trails.contains { $0.relationID == Self.boundlessID })
    }

    /// The whole reason the listing pass filters at all. `route=hiking` holds
    /// the continental paths as well as the village loops, and an app that
    /// offered the Maximiliansweg as somewhere to walk on Saturday would be
    /// wrong about it in a way no other screen could correct.
    @Test("a continental path is not a day hike")
    func longDistanceRouteIsDropped() throws {
        let trails = try CuratedTrailDecoding.trails(fromListing: Self.listingResponse)

        #expect(!trails.contains { $0.relationID == Self.longDistanceID })
    }

    /// And the one that survives arrives whole. The tags are the row: the
    /// waymark a hiker reads off a signpost is in them, and it is the thing a
    /// curated route has that no uploaded hike does.
    @Test("a day hike decodes with its tags intact")
    func dayHikeDecodesWithItsTags() throws {
        let trails = try CuratedTrailDecoding.trails(fromListing: Self.listingResponse)
        let trail = try #require(trails.first { $0.relationID == Self.relationID })

        #expect(trails.count == 1, "one of the four relations in that box is a row")
        #expect(trail.name == "Almbachklamm")
        #expect(trail.tags["osmc:symbol"] == "red:red:white_bar:411:black")
        #expect(trail.tags["operator"] == "Alpenverein")
        #expect(trail.facts.waymark?.colour == .red, "the first component of osmc:symbol, not the whole field")
        #expect(trail.facts.waymark?.reference == "411")
        #expect(trail.box.south == Self.boxSouth)
        #expect(trail.box.east == Self.boxEast)
        #expect(
            trail.route.isEmpty,
            "the listing pass carries no geometry — that is what makes it 43.7 KB rather than 7.0 MB"
        )
    }

}

// MARK: - The geometry pass

/// Split from the suite's body for length alone — SwiftLint caps a type body
/// at 300 counted lines and the fixtures above are most of them. The division
/// is where it would be anyway: everything below is about assembling member
/// ways into one line, which is the half of this file worth reading.
extension CuratedTrailDecodingTests {
    // MARK: - The geometry pass: assembling one line

    /// The measurement this whole design rests on, as a test. These four ways
    /// are a single continuous walk on the ground, and no two of them are
    /// adjacent in the response: an assembler that joined members in the order
    /// they arrived would answer with four fragments and then drop the
    /// relation for being too broken to draw.
    @Test("member ways out of order still assemble into one run")
    func responseOrderIsNotUsable() throws {
        let data = Self.geometryResponse(members: [
            Self.way(from: Self.hut, to: Self.summit),
            Self.way(from: Self.trailhead, to: Self.bridge),
            Self.way(from: Self.meadow, to: Self.hut),
            Self.way(from: Self.bridge, to: Self.meadow),
        ])
        let trails = try CuratedTrailDecoding.trails(fromGeometry: data)
        let trail = try #require(trails[Self.relationID])
        let line = Self.northwards(trail.route)
        let start = try #require(line.first)
        let end = try #require(line.last)

        #expect(line.count == Self.wholeChainPoints, "four three-point ways sharing three points")
        #expect(Self.isSame(start, as: Self.trailhead))
        #expect(Self.isSame(end, as: Self.summit))
        #expect(abs(trail.distanceMeters - Self.legMeters * 4) < Self.lengthTolerance)
    }

    /// A way drawn in the opposite direction to its neighbours is the ordinary
    /// case, not the exotic one: nobody surveying a path agrees with anybody
    /// else about which way is forwards, and the middle way here ends where
    /// the first one ends.
    ///
    /// The fix is to flip it, and the failure it replaces is subtle — an
    /// assembler that only ever matched a way's *first* point would start a
    /// second run instead, leave two fragments of roughly equal length, and
    /// drop the relation. So the point count is the assertion: seven means one
    /// run through all three ways in the right order.
    @Test("a way surveyed backwards is flipped, not left behind")
    func aReversedWayIsFlipped() throws {
        let data = Self.geometryResponse(members: [
            Self.way(from: Self.trailhead, to: Self.bridge),
            // Drawn downhill, so its end and its neighbour's end are the same
            // point.
            Self.way(from: Self.meadow, to: Self.bridge),
            Self.way(from: Self.meadow, to: Self.hut),
        ])
        let trails = try CuratedTrailDecoding.trails(fromGeometry: data)
        let trail = try #require(trails[Self.relationID])
        let line = Self.northwards(trail.route)
        let start = try #require(line.first)
        let end = try #require(line.last)

        #expect(line.count == Self.threeWayPoints)
        #expect(Self.isSame(start, as: Self.trailhead))
        #expect(Self.isSame(end, as: Self.hut))
        #expect(abs(trail.distanceMeters - Self.legMeters * 3) < Self.lengthTolerance)
    }

    /// A run is grown from an arbitrary seed, and the way that happens to come
    /// first is as likely to be in the middle of the route as at either end of
    /// it. Here it is the middle one deliberately: an assembler that only
    /// extended forwards would answer with the meadow-to-summit half and lose
    /// the 2.2 km below the meadow — a line that is drawn, that looks like a
    /// trail, and that is wrong about where the walk begins.
    @Test("a run grows from both ends of the way it started at")
    func aRunGrowsBothWays() throws {
        let data = Self.geometryResponse(members: [
            Self.way(from: Self.meadow, to: Self.hut),
            Self.way(from: Self.trailhead, to: Self.bridge),
            Self.way(from: Self.hut, to: Self.summit),
            Self.way(from: Self.bridge, to: Self.meadow),
        ])
        let trails = try CuratedTrailDecoding.trails(fromGeometry: data)
        let trail = try #require(trails[Self.relationID])
        let line = Self.northwards(trail.route)
        let start = try #require(line.first)
        let end = try #require(line.last)

        #expect(line.count == Self.wholeChainPoints)
        #expect(Self.isSame(start, as: Self.trailhead), "the half below the seed is not optional")
        #expect(Self.isSame(end, as: Self.summit))
    }

    /// What else is in the bag. A hiking relation carries guideposts, viewpoint
    /// nodes and the occasional way the server answered with one coordinate or
    /// none — none of which is a line, and any of which becomes one if the
    /// decoder is credulous.
    ///
    /// The strongest assertion here is the negative one: the stray point sits
    /// 11 km north of every other fixture coordinate, so a run that swallowed
    /// it would draw a stroke across the Berchtesgadener Ache and nothing
    /// about the point count alone would say so.
    @Test("nodes and members too short to be a line are ignored")
    func nonLineMembersAreIgnored() throws {
        let data = Self.geometryResponse(members: [
            Self.guidepostMember,
            Self.strayPointMember,
            Self.geometrylessMember,
            Self.way(from: Self.trailhead, to: Self.bridge),
            Self.way(from: Self.bridge, to: Self.meadow),
        ])
        let trails = try CuratedTrailDecoding.trails(fromGeometry: data)
        let trail = try #require(trails[Self.relationID])
        let line = Self.northwards(trail.route)

        #expect(line.count == Self.twoWayPoints, "two ways, and nothing from the other three members")
        #expect(
            !line.contains { abs($0.latitude - Self.strayLatitude) < Self.coordinateTolerance },
            "a single coordinate is not a line and must not be drawn as one"
        )
        #expect(abs(trail.distanceMeters - Self.legMeters * 2) < Self.lengthTolerance)
    }

    // MARK: - The geometry pass: what is drawn and what is refused

    /// A relation with a piece left over. `CommunityRouteLine` is one polyline,
    /// so drawing both runs would put a straight stroke across the gap between
    /// them, and a hiker cannot tell that stroke from a trail.
    ///
    /// The longest run is 3336 m of 4448 — a 0.75 share, comfortably over the
    /// 0.6 floor — so the route is offered, and the stranded kilometre is not
    /// in what comes back. That the length agrees with the line that is
    /// actually drawn is the other half: a stated distance disagreeing with
    /// its own polyline is wrong in the one place anybody can check it.
    @Test("a relation with a leftover piece returns its longest run only")
    func onlyTheLongestRunIsDrawn() throws {
        let data = Self.geometryResponse(members: [
            Self.way(from: Self.trailhead, to: Self.bridge),
            Self.way(from: Self.bridge, to: Self.meadow),
            Self.way(from: Self.meadow, to: Self.hut),
            Self.way(from: Self.strandedFoot, to: Self.strandedHead),
        ])
        let trails = try CuratedTrailDecoding.trails(fromGeometry: data)
        let trail = try #require(trails[Self.relationID])
        let line = Self.northwards(trail.route)

        #expect(line.count == Self.threeWayPoints)
        #expect(
            !line.contains { abs($0.longitude - Self.strandedMeridian) < Self.coordinateTolerance },
            "the piece that does not join is left out rather than drawn across the gap"
        )
        #expect(abs(trail.distanceMeters - Self.legMeters * 3) < Self.lengthTolerance)
    }

    /// And the relation nobody has finished mapping. Three pieces, none
    /// touching another, so the best run is a third of the route — well under
    /// the 0.6 floor that costs six of 97 in the measured box.
    ///
    /// **Absent, not short.** Showing a third of the Almbachklamm under the
    /// Almbachklamm's name, with its waymark and its from/to beside it, is a
    /// quieter kind of wrong than showing nothing, and the assertion is on the
    /// whole answer rather than on the route's length precisely so that a
    /// broken line cannot come back in some other shape. The relation is
    /// otherwise perfect — same name, same tags, same box as the route in the
    /// test above, which is what is offered at a 0.75 share — so its share is
    /// the only thing that can explain its absence.
    @Test("a relation too fragmented to draw is absent, not shortened")
    func aFragmentedRelationIsDropped() throws {
        let data = Self.geometryResponse(members: [
            Self.way(from: Self.trailhead, to: Self.bridge),
            Self.way(from: Self.strandedFoot, to: Self.strandedHead),
            Self.way(from: Self.scatteredFoot, to: Self.scatteredHead),
        ])
        let trails = try CuratedTrailDecoding.trails(fromGeometry: data)

        #expect(trails[Self.relationID] == nil)
        #expect(trails.isEmpty, "a relation this app cannot draw is not in the answer at all")
    }

    /// Why the geometry pass is one request and not two. `out geom` puts the
    /// relation's tags and bounds on the same element as its members, so a
    /// trail opened from a notification, a deep link or a cold start needs no
    /// listing to have run first and has nothing to reconcile against.
    ///
    /// The pin is the tell. It stands at the centre of the box, which only the
    /// bounds can give — the line's own first point is the trailhead 2.2 km
    /// south of it, and is a point no relation agrees means anything.
    @Test("one out-geom answer carries the tags and the box as well as the line")
    func theGeometryPassIsSelfSufficient() throws {
        let data = Self.geometryResponse(members: [
            Self.way(from: Self.trailhead, to: Self.bridge),
            Self.way(from: Self.bridge, to: Self.meadow),
            Self.way(from: Self.meadow, to: Self.hut),
            Self.way(from: Self.hut, to: Self.summit),
        ])
        let trails = try CuratedTrailDecoding.trails(fromGeometry: data)
        let trail = try #require(trails[Self.relationID])

        #expect(trail.name == "Almbachklamm")
        #expect(trail.tags["network"] == "lwn")
        #expect(trail.box.south == Self.boxSouth)
        #expect(trail.box.north == Self.boxNorth)
        #expect(
            trail.coordinate.latitude == (Self.boxSouth + Self.boxNorth) / 2,
            "the box's centre, not the line's end"
        )
        #expect(trail.facts.waymark?.displayName == "Red waymark 411")
        #expect(trail.facts.journey == "Marktschellenberg to Ettenberg")
        #expect(trail.facts.shape == .pointToPoint, "ends 4.4 km apart, which the geometry answers and no tag does")
        #expect(!trail.route.isEmpty)
    }

    // MARK: - What an overloaded server sends

    /// Not a defensive test. Overpass is volunteer-run, and an overloaded one
    /// answers with an **HTML** page under HTTP 200 — observed repeatedly while
    /// this feature was being measured — so this is a normal operating
    /// condition on an ordinary afternoon.
    ///
    /// Both passes, because both decode through the same door: whichever
    /// request is in flight when the server gives up has to come back as
    /// something the caller can log and walk past, leaving the published half
    /// of the browse list standing.
    @Test("an HTML page from an overloaded server is a malformed graph")
    func anHTMLPageIsAMalformedGraph() throws {
        let listing = #expect(throws: TrailGraphProviderError.self) {
            _ = try CuratedTrailDecoding.trails(fromListing: Self.overloadedServerPage)
        }
        let geometry = #expect(throws: TrailGraphProviderError.self) {
            _ = try CuratedTrailDecoding.trails(fromGeometry: Self.overloadedServerPage)
        }

        #expect(Self.isMalformed(try #require(listing)))
        #expect(Self.isMalformed(try #require(geometry)))
    }
}
