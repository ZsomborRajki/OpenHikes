//
//  CuratedTrailQueryTests.swift
//  OpenHikesTests
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

/// The arithmetic a curated search does before it asks OpenStreetMap anything.
///
/// A suite of its own for the reason ``CuratedTrailQuery`` is a type of its
/// own: every decision it makes — how wide a box is worth asking for, which
/// routes are day hikes, which pass carries geometry — is invisible in the
/// answer. A box drawn a third too narrow and a box drawn correctly both
/// return a list of plausible-looking hikes; the difference only surfaces
/// later, as routes the hiker can see on the map and cannot find in the list.
///
/// Nothing here touches the network, and nothing here needs to. The queries
/// are strings and the filter is spherical geometry, which is exactly why the
/// two were split out of the fetching actor in the first place.
@Suite("Curated trail query")
struct CuratedTrailQueryTests {
    /// Metres in one degree of latitude on the sphere ``RouteGeometry``
    /// measures against.
    ///
    /// Deliberately *not* ``CuratedTrailQuery``'s own 111,320: that is a
    /// WGS-84 mean, and this is the radius the haversine actually uses. The
    /// 0.1% between them is the difference between a box builder that agrees
    /// with ``CuratedTrailQuery/spanMeters(of:)`` to within a metre and one
    /// that agrees to within twenty — and a test that wants to say *a route
    /// 19.9 km across* has to be able to build exactly that, or the assertion
    /// is about the builder's rounding rather than about the ceiling.
    private static let metresPerDegree: Double = 6_371_008.8 * .pi / 180

    /// About ten centimetres, in degrees.
    ///
    /// Two coordinates this close are the same place on the ground; the slack
    /// exists only because the midpoint of two binary fractions rarely lands
    /// exactly on the decimal one a test would like to write down.
    private static let coordinateTolerance = 0.000001

    /// Somewhere in the Berchtesgaden box every measured figure in
    /// ``CuratedTrailQuery`` came from.
    private static func area(
        latitude: Double = 47.63,
        longitude: Double = 12.86,
        radiusMeters: Double = 10_000
    ) -> CommunitySearchArea {
        CommunitySearchArea(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            radiusMeters: radiusMeters
        )
    }

    /// A square box whose true diagonal on the ground is `diagonalMeters`.
    ///
    /// Built from the same sphere ``RouteGeometry`` measures on and with the
    /// width taken at the box's southern edge — which is the edge
    /// ``CuratedTrailQuery/spanMeters(of:)`` measures — so the box this hands
    /// back really is the size it was asked for, at any latitude. That is what
    /// lets a test place a route a hundred metres either side of the day-hike
    /// line and mean it.
    private static func box(
        diagonalMeters: Double,
        at latitude: Double = 47.63,
        longitude: Double = 12.86
    ) -> CuratedTrailQuery.BoundingBox {
        let edge = diagonalMeters / sqrt(2)
        let latitudeSpan = edge / metresPerDegree
        let longitudeSpan = edge / (metresPerDegree * cos(latitude * .pi / 180))
        return CuratedTrailQuery.BoundingBox(
            south: latitude,
            west: longitude,
            north: latitude + latitudeSpan,
            east: longitude + longitudeSpan
        )
    }

    /// Whether two measurements agree closely enough to be the same statement.
    private static func isClose(_ lhs: Double, _ rhs: Double, within tolerance: Double) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    /// The relation ids a geometry query names, read back out of the query.
    ///
    /// Parsed rather than compared against a re-joined string, so that the
    /// test states what Overpass will read — a list of ids between `rel(id:`
    /// and the closing bracket — instead of restating the implementation's own
    /// `joined(separator:)` and agreeing with itself.
    private static func idList(in query: String?) -> [String] {
        guard let query,
              let start = query.range(of: "rel(id:"),
              let end = query.range(of: ")", range: start.upperBound..<query.endIndex)
        else { return [] }
        return query[start.upperBound..<end.lowerBound]
            .split(separator: ",")
            .map(String.init)
    }

    // MARK: - Which areas are worth asking about

    /// The ceiling is about what a volunteer-run API should be asked for in
    /// one request, so the refusal has to be silent and total rather than a
    /// truncated answer: the listing pass scales with the area of the box, and
    /// a continental one is megabytes of rows that the day-hike filter would
    /// then throw away.
    @Test("an area wider than the ceiling is not asked about at all")
    func continentalAreaHasNoBox() {
        #expect(CuratedTrailQuery.circumscribingBox(
            for: Self.area(radiusMeters: CuratedTrailQuery.maximumRadiusMeters + 1)
        ) == nil)
        #expect(CuratedTrailQuery.circumscribingBox(for: Self.area(radiusMeters: 150_000)) == nil)
        // Inclusive at the line, because the constant is documented as the
        // widest search this will ask about rather than the first it will not.
        #expect(CuratedTrailQuery.circumscribingBox(
            for: Self.area(radiusMeters: CuratedTrailQuery.maximumRadiusMeters)
        ) != nil)
    }

    /// A zero radius is a point and a negative one is a box whose north edge
    /// is south of its south edge — which Overpass does not reject, it simply
    /// answers with nothing while the app waits for it. Neither is a question,
    /// so neither becomes a request.
    @Test("an area with no width is not a question")
    func emptyAreaHasNoBox() {
        #expect(CuratedTrailQuery.circumscribingBox(for: Self.area(radiusMeters: 0)) == nil)
        #expect(CuratedTrailQuery.circumscribingBox(for: Self.area(radiusMeters: -1)) == nil)
    }

    /// `cos(latitude)` is the divisor that turns metres into degrees of
    /// longitude, and it runs to zero at the pole: a search a few hundred
    /// metres from it would ask for a box wrapping the entire world. There is
    /// no hiking to miss up there, so the honest answer is no box rather than
    /// a clamped one that quietly asks about everything.
    @Test("near the poles there is no box to draw")
    func polarAreaHasNoBox() {
        #expect(CuratedTrailQuery.circumscribingBox(for: Self.area(latitude: 89.5)) == nil)
        #expect(CuratedTrailQuery.circumscribingBox(for: Self.area(latitude: -89.5)) == nil)
        #expect(CuratedTrailQuery.circumscribingBox(for: Self.area(latitude: 89)) == nil)
        // Svalbard is still a place somebody walks, and it is inside the line.
        #expect(CuratedTrailQuery.circumscribingBox(for: Self.area(latitude: 78)) != nil)
    }

    /// The choice that keeps the list honest about what it claims to describe.
    /// A box inscribed in the search circle would leave routes visible on the
    /// map out of the list beneath it; this one puts its *edges* on the circle,
    /// so its corners reach out past the radius — the harmless direction, since
    /// a route just beyond the circle is still somewhere the hiker can see.
    @Test("the box circumscribes the search circle rather than fitting inside it")
    func boxCircumscribesTheCircle() {
        let area = Self.area()
        guard let box = CuratedTrailQuery.circumscribingBox(for: area) else {
            Issue.record("a ten-kilometre search is well inside the ceiling")
            return
        }
        let edgeTolerance = area.radiusMeters / 100

        let northEdge = RouteGeometry.distanceMeters(
            from: area.coordinate,
            to: CLLocationCoordinate2D(latitude: box.north, longitude: area.longitude)
        )
        let eastEdge = RouteGeometry.distanceMeters(
            from: area.coordinate,
            to: CLLocationCoordinate2D(latitude: area.latitude, longitude: box.east)
        )
        #expect(Self.isClose(northEdge, area.radiusMeters, within: edgeTolerance))
        #expect(Self.isClose(eastEdge, area.radiusMeters, within: edgeTolerance))

        // An inscribed box would put this corner *on* the circle, at exactly
        // the radius. This one is a diagonal out from it.
        let corner = RouteGeometry.distanceMeters(
            from: area.coordinate,
            to: CLLocationCoordinate2D(latitude: box.north, longitude: box.east)
        )
        #expect(corner > area.radiusMeters)
        #expect(Self.isClose(corner, area.radiusMeters * sqrt(2), within: area.radiusMeters / 50))
    }

    /// A degree of longitude is 111 km at the equator and 56 km at 60°N, so
    /// the same walk needs twice the degrees the further north it is. Without
    /// the `cos(latitude)` divisor the box would be the same shape everywhere
    /// and the Norwegian hiker would be handed half the area they asked for.
    @Test("the same radius is a wider box in longitude the further north it is")
    func longitudeSpanWidensWithLatitude() {
        guard let equator = CuratedTrailQuery.circumscribingBox(for: Self.area(latitude: 0, longitude: 0)),
              let nordic = CuratedTrailQuery.circumscribingBox(for: Self.area(latitude: 60, longitude: 0))
        else {
            Issue.record("both of these are ordinary ten-kilometre searches")
            return
        }

        // Latitude is unaffected: a degree north is a degree north anywhere.
        let equatorHeight = equator.north - equator.south
        let nordicHeight = nordic.north - nordic.south
        #expect(Self.isClose(nordicHeight, equatorHeight, within: equatorHeight / 10_000))

        let equatorWidth = equator.east - equator.west
        let nordicWidth = nordic.east - nordic.west
        #expect(nordicWidth > equatorWidth)
        // cos 60° is exactly a half, so the box is exactly twice as wide.
        #expect(Self.isClose(nordicWidth, 2 * equatorWidth, within: equatorWidth / 100))
    }

    // MARK: - Which routes are day hikes

    /// The measurement the ceiling was chosen from. Of the 97 routes that
    /// survived in the Berchtesgaden box, the widest sits 18.9 km across and
    /// the narrowest thing rejected is 55.9 km — so the line has a wide margin
    /// on both sides and is not balanced on a tie. If a future change moves it
    /// far enough to disturb either of these, it has changed what the feature
    /// claims a day hike is.
    @Test("the widest kept route and the narrowest rejected one both clear the line")
    func theLineIsNotBalancedOnATie() {
        #expect(CuratedTrailQuery.isDayHike(box: Self.box(diagonalMeters: 18_900)))
        #expect(!CuratedTrailQuery.isDayHike(box: Self.box(diagonalMeters: 55_900)))
    }

    /// The line itself, from either side. A hundred metres is far tighter than
    /// anything in the measured data, and is here to pin the ceiling to the
    /// documented 20 km rather than to whatever it drifts to.
    @Test("a route just inside twenty kilometres is a day hike and one just outside is not")
    func dayHikeLineSitsAtTwentyKilometres() {
        #expect(CuratedTrailQuery.isDayHike(box: Self.box(diagonalMeters: 19_900)))
        #expect(!CuratedTrailQuery.isDayHike(box: Self.box(diagonalMeters: 20_100)))
        #expect(CuratedTrailQuery.maximumSpanMeters == 20_000)
    }

    /// The reason the span is great-circle on each edge rather than a
    /// hypotenuse in degree space. The same 19 km walk is measured the same in
    /// Norway as in the Alps; the naive version at the end of this test is what
    /// the filter *would* have said about the Norwegian one — 30 km, rejected,
    /// for a route that is nothing of the sort.
    @Test("a day hike is the same size in Norway as in the Alps")
    func spanIsMeasuredOnTheGroundRatherThanInDegrees() {
        let alpine = Self.box(diagonalMeters: 19_000)
        let nordic = Self.box(diagonalMeters: 19_000, at: 60, longitude: 10.75)

        #expect(Self.isClose(CuratedTrailQuery.spanMeters(of: alpine), 19_000, within: 20))
        #expect(Self.isClose(CuratedTrailQuery.spanMeters(of: nordic), 19_000, within: 20))
        #expect(CuratedTrailQuery.isDayHike(box: alpine))
        #expect(CuratedTrailQuery.isDayHike(box: nordic))

        let degreeHypotenuse = hypot(
            nordic.north - nordic.south,
            nordic.east - nordic.west
        ) * Self.metresPerDegree
        #expect(degreeHypotenuse > CuratedTrailQuery.maximumSpanMeters)
    }

    /// Overpass hands back numbers somebody typed into a public database, and
    /// a box that will not resolve to a distance must fall out of the list
    /// rather than through the comparison — `NaN <= 20_000` is false either
    /// way, but only the explicit check says that was meant.
    @Test("a box with no numbers in it is not a day hike")
    func nonFiniteBoxIsRejected() {
        let box = CuratedTrailQuery.BoundingBox(south: .nan, west: 12.86, north: .nan, east: 13)
        #expect(!CuratedTrailQuery.isDayHike(box: box))
    }

    /// Where a curated route's pin stands, and a rule deliberately unlike the
    /// published one: a relation's members are in whatever order they were
    /// added, so its "first" point is not a trailhead and means nothing. The
    /// centre of the box is at least a true statement about where the route is.
    @Test("a curated pin stands in the middle of the route's box")
    func centreIsTheBoxMidpoint() {
        let box = CuratedTrailQuery.BoundingBox(south: 47.5, west: 12.8, north: 47.7, east: 13)
        let centre = CuratedTrailQuery.centre(of: box)
        #expect(Self.isClose(centre.latitude, 47.6, within: Self.coordinateTolerance))
        #expect(Self.isClose(centre.longitude, 12.9, within: Self.coordinateTolerance))
    }

    /// Overpass's `bb` is a plain minimum and maximum over the members'
    /// longitudes, so a route that steps across the date line comes back as
    /// `−179.99 … 179.99` — a box around the whole world that means a sliver
    /// two hundredths of a degree wide. Averaging the two numbers put the pin
    /// on longitude 0, in the Gulf of Guinea: 20,000 km from the trail, which
    /// is where the list then sorted it and where the store then failed to
    /// find it again.
    @Test("a route across the date line is pinned on the line, not on zero")
    func centreOfAnAntimeridianBoxStaysOnTheLine() {
        let box = CuratedTrailQuery.BoundingBox(
            south: 66.0,
            west: -179.99,
            north: 66.01,
            east: 179.99
        )
        let centre = CuratedTrailQuery.centre(of: box)
        #expect(Self.isClose(centre.latitude, 66.005, within: Self.coordinateTolerance))
        // Either spelling of the line: −180 and 180 are the same meridian, and
        // ``CuratedTrailQuery`` normalises into −180...180.
        #expect(Self.isClose(abs(centre.longitude), 180, within: 0.01))
    }

    /// The width the filter reads is the short way round, which is what makes
    /// the sliver above a day hike at all — and what keeps this from letting
    /// anything else through: a route genuinely spanning more than half the
    /// planet is thousands of kilometres wide on the complement too.
    @Test("the date line is crossed at its true width, and nothing else is")
    func antimeridianSpanIsTheShortWayRound() {
        let sliver = CuratedTrailQuery.BoundingBox(
            south: 66.0,
            west: -179.99,
            north: 66.01,
            east: 179.99
        )
        #expect(CuratedTrailQuery.isDayHike(box: sliver))

        // Half the northern hemisphere, arriving in the same shape. The
        // complement is 160°, which at this latitude is thousands of
        // kilometres and nowhere near a day's walk.
        let continental = CuratedTrailQuery.BoundingBox(
            south: 66.0,
            west: -100,
            north: 67,
            east: 100
        )
        #expect(!CuratedTrailQuery.isDayHike(box: continental))
    }

    /// An ordinary box is unaffected, which is the half of this worth pinning:
    /// the wrap correction may only ever fire across the seam.
    @Test("an ordinary box is read exactly as it was before")
    func ordinaryBoxKeepsItsWidth() {
        let box = CuratedTrailQuery.BoundingBox(south: 47.5, west: 12.8, north: 47.7, east: 13)
        #expect(Self.isClose(
            CuratedTrailQuery.longitudeSpanDegrees(of: box),
            0.2,
            within: Self.coordinateTolerance
        ))
    }

    // MARK: - The two queries

    /// The whole economy of the feature is in one verb. `out geom` over this
    /// box measured 7.0 MB; `out tags bb` measured 43.7 KB and still carries
    /// the bounding box the day-hike filter needs. A listing pass that ever
    /// grows a `geom` is a browse that downloads seven megabytes before it
    /// draws a row.
    @Test("the listing pass asks for tags and a box, never for geometry")
    func listingQueryIsTheCheapPass() throws {
        let query = try #require(CuratedTrailQuery.listingQuery(
            in: [CuratedTrailQuery.BoundingBox(south: 47, west: 12, north: 48, east: 13)]
        ))
        #expect(query.contains("out tags bb"))
        #expect(!query.contains("out geom"))
        // `bb` and not `center`: a centre would place a pin, and the box is
        // what decides whether the route is a day hike at all.
        #expect(!query.contains("center"))
        #expect(query.contains("[\"route\"=\"hiking\"]"))
        // Filtered rather than checked afterwards — an unnamed route is a row
        // with nothing to say, and 103 of the measured 106 carry a name.
        #expect(query.contains("[\"name\"]"))
    }

    /// Overpass reads its bounding box as south, west, north, east — which is
    /// neither the order MapKit uses nor the one a coordinate is written in.
    /// Getting it wrong does not fail: it asks about a different, usually
    /// empty, part of the world and the list simply comes back short.
    @Test("the bounding box reaches Overpass in south, west, north, east order")
    func listingQuerySpellsTheBoxInOverpassOrder() throws {
        let query = try #require(CuratedTrailQuery.listingQuery(
            in: [CuratedTrailQuery.BoundingBox(south: 47, west: 12, north: 48, east: 13)]
        ))
        #expect(query.contains("(47.0,12.0,48.0,13.0)"))
    }

    // MARK: - The date line

    /// The seam a clamp used to swallow. At 60°N a 40 km radius is 0.72° of
    /// longitude, so a hiker at 179.8° had everything from 180° to −179.48°
    /// dropped — while the published half, which reaches CloudKit through
    /// `distanceToLocation:`, answered about the whole circle. Two halves of
    /// one list describing two different areas is the one thing a merge may
    /// not do.
    @Test("a search crossing the date line eastwards asks about both sides")
    func eastwardCrossingSplitsIntoTwoBoxes() throws {
        let boxes = CuratedTrailQuery.searchBoxes(
            for: Self.area(latitude: 60, longitude: 179.8, radiusMeters: 40_000)
        )

        #expect(boxes.count == 2)
        let east = try #require(boxes.first)
        let west = try #require(boxes.last)
        #expect(east.west > 179 && east.east == 180)
        #expect(west.west == -180 && west.east < -179)
        // No degrees are lost and none are asked about twice: the two spans
        // add up to the one span the circle actually covers.
        let span = (east.east - east.west) + (west.east - west.west)
        let whole = try #require(CuratedTrailQuery.circumscribingBox(
            for: Self.area(latitude: 60, longitude: 179.8, radiusMeters: 40_000)
        ))
        #expect(Self.isClose(span, whole.east - whole.west, within: 1e-9))
    }

    @Test("a search crossing the date line westwards asks about both sides")
    func westwardCrossingSplitsIntoTwoBoxes() throws {
        let boxes = CuratedTrailQuery.searchBoxes(
            for: Self.area(latitude: 60, longitude: -179.8, radiusMeters: 40_000)
        )

        #expect(boxes.count == 2)
        let east = try #require(boxes.first)
        let west = try #require(boxes.last)
        #expect(east.west > 179 && east.east == 180)
        #expect(west.west == -180 && west.east < -179)
    }

    /// The overwhelmingly common case stays one box, because a split that
    /// happened everywhere would double the filters in every query for a
    /// seam almost nobody stands on.
    @Test("an ordinary search is still one box")
    func anOrdinarySearchIsOneBox() {
        #expect(CuratedTrailQuery.searchBoxes(for: Self.area()).count == 1)
        #expect(CuratedTrailQuery.searchBoxes(
            for: Self.area(radiusMeters: CuratedTrailQuery.maximumRadiusMeters * 2)
        ).isEmpty)
    }

    /// A map hands back whatever longitude the hiker dragged to, and dragging
    /// east three times round the world is a real thing a finger does. 540° is
    /// 180°, and a box built from the raw figure would ask Overpass about a
    /// place that does not exist.
    @Test("a longitude that has wrapped round the world is brought back")
    func awrappedLongitudeIsNormalised() throws {
        let wrapped = try #require(CuratedTrailQuery.circumscribingBox(
            for: Self.area(latitude: 47.63, longitude: 12.98 + 360)
        ))
        let plain = try #require(CuratedTrailQuery.circumscribingBox(
            for: Self.area(latitude: 47.63, longitude: 12.98)
        ))

        #expect(Self.isClose(wrapped.west, plain.west, within: 1e-9))
        #expect(Self.isClose(wrapped.east, plain.east, within: 1e-9))
    }

    /// Two boxes, and still **one** request: Overpass takes a union of
    /// filters, so the seam costs a second filter rather than a second round
    /// trip to a volunteer-run API.
    @Test("both sides of the date line go in one query")
    func bothSidesShareOneQuery() throws {
        let boxes = CuratedTrailQuery.searchBoxes(
            for: Self.area(latitude: 60, longitude: 179.8, radiusMeters: 40_000)
        )
        let query = try #require(CuratedTrailQuery.listingQuery(in: boxes))

        #expect(query.components(separatedBy: "out tags bb").count == 2, "one output statement")
        #expect(query.components(separatedBy: #"["route"="hiking"]"#).count == 3, "two filters")
        for box in boxes {
            #expect(query.contains(box.overpassLiteral))
        }
    }

    @Test("no box is no query at all")
    func noBoxesIsNoQuery() {
        #expect(CuratedTrailQuery.listingQuery(in: []) == nil)
    }

    /// A request for nothing is still a round trip to a volunteer-run API, and
    /// still a spinner in front of the hiker. A caller with no surviving
    /// routes has no question to ask.
    @Test("nothing to ask about is no request at all")
    func emptyGeometryQueryIsNil() {
        #expect(CuratedTrailQuery.geometryQuery(ids: []) == nil)
    }

    /// By id rather than by box, which is what keeps the expensive pass
    /// bounded — it runs over the routes that already survived the filter,
    /// never over everything the area holds. Order is preserved because the
    /// list arrives sorted by distance and the first rows drawn should be the
    /// nearest ones.
    @Test("the geometry pass names its relations by id, in the order it was given")
    func geometryQueryJoinsIDs() {
        guard let query = CuratedTrailQuery.geometryQuery(ids: [12, 7, 9]) else {
            Issue.record("three relations to fetch is a request")
            return
        }
        #expect(query.contains("out geom"))
        #expect(Self.idList(in: query) == ["12", "7", "9"])
    }

    /// The cap is the other half of that bound. Measured cost of this pass at
    /// the batch limit is about 420 KB for routes of median size and 1.4 MB
    /// for the largest twenty-five in one box — so a dense area handing over
    /// every route it found is precisely the case that must not become one
    /// enormous request.
    @Test("a search with more routes than the batch asks for only the batch")
    func geometryQueryIsCapped() {
        let limit = CuratedTrailQuery.geometryBatchLimit
        let query = CuratedTrailQuery.geometryQuery(ids: (1...(limit + 10)).map(Int64.init))
        let ids = Self.idList(in: query)

        #expect(ids.count == limit)
        #expect(ids.first == "1")
        #expect(ids.last == String(limit))
        #expect(!ids.contains(String(limit + 1)))
    }

    // MARK: - How the two ceilings relate

    /// They used to be two numbers, 40 km here and 150 km there, and the band
    /// between them was written down as intended behaviour. It was a gap: the
    /// pill was enabled inside it, a tap spent a CloudKit query, and the
    /// curated half answered `[]` with no failure to report — so a hiker
    /// looking at 100 km of map got no trails and nothing saying that zooming
    /// in was the answer.
    ///
    /// One number now, and this is the one, because Overpass is the source
    /// that minds being asked. The assertion is worth keeping in this
    /// direction: it is this file's figure that the map's ceiling follows, and
    /// a change here is meant to move both.
    @Test("the map's ceiling is the curated one")
    func theTwoCeilingsAreOne() {
        #expect(CommunityQueryPolicy.maximumRadiusMeters == CuratedTrailQuery.maximumRadiusMeters)
        // And the floor every map query is clamped up to is inside it, or a
        // zoomed-right-in search would return no curated rows even though it
        // is the smallest question the map can ask.
        #expect(CommunityQueryPolicy.minimumRadiusMeters <= CuratedTrailQuery.maximumRadiusMeters)
    }
}
