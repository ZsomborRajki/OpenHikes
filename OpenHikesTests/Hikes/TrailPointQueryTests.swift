//
//  TrailPointQueryTests.swift
//  OpenHikesTests
//
//  What the maker asks OpenStreetMap for what is near a drawn trail, and —
//  mostly — what it does not.
//
//  Every claim in ``TrailPointQuery``'s header is a claim about a *request*,
//  and a request is invisible in the result: an app that asked for
//  `tourism=information` would answer with a map full of guideposts and every
//  test about the rows would still pass. So what is pinned here is the query
//  text itself, the exclusions by name, and the ceiling that makes the
//  measured figures in that file true.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail point query")
struct TrailPointQueryTests {
    private static let berchtesgaden = CLLocationCoordinate2D(latitude: 47.62, longitude: 12.97)

    private static func area(radiusMeters: Double) -> CommunitySearchArea {
        CommunitySearchArea(coordinate: berchtesgaden, radiusMeters: radiusMeters)
    }

    private static func query(radiusMeters: Double = 8000) -> String? {
        TrailPointQuery.query(in: TrailPointQuery.searchBoxes(for: area(radiusMeters: radiusMeters)))
    }

    // MARK: - What is asked for

    /// The eleven filters, and the shape that makes an area-mapped hut arrive
    /// as one coordinate rather than as an outline.
    @Test("the query asks for every kind of place and for their centres")
    func theQueryAsksForEveryKind() throws {
        let text = try #require(Self.query())

        for kind in TrailPointQuery.kinds {
            #expect(
                text.contains("[\"\(kind.key)\"=\"\(kind.value)\"]"),
                "\(kind.key)=\(kind.value) should be asked for"
            )
        }
        #expect(text.contains("out tags center;"), "a way's centre is what a pin stands at")
        #expect(text.contains("[out:json][timeout:\(TrailPointQuery.timeoutSeconds)];"))
    }

    /// **A switch turned off in the maker leaves its tags out of the request**,
    /// which is the half of that switch no result can show: an app that asked
    /// for shelters and dropped them afterwards would draw the same map while
    /// downloading every hut in the valley.
    @Test("a kind switched off is not in the request")
    func aSwitchedOffKindIsNotAsked() throws {
        let boxes = TrailPointQuery.searchBoxes(for: Self.area(radiusMeters: 8000))
        let shown = Set(TrailPointQuery.searchableSymbols).subtracting([.shelter])
        let text = try #require(TrailPointQuery.query(in: boxes, symbols: shown))

        for kind in TrailPointQuery.kinds {
            let filter = "[\"\(kind.key)\"=\"\(kind.value)\"]"
            if kind.symbol == .shelter {
                #expect(!text.contains(filter), "\(kind.key)=\(kind.value) is switched off")
            } else {
                #expect(text.contains(filter), "\(kind.key)=\(kind.value) is still asked for")
            }
        }
    }

    /// Every switch off is nothing to ask about, and asking Overpass for an
    /// empty union would spend a slot to be told nothing.
    @Test("with every kind switched off there is no request to make")
    func everyKindOffAsksNothing() {
        let boxes = TrailPointQuery.searchBoxes(for: Self.area(radiusMeters: 8000))

        #expect(TrailPointQuery.query(in: boxes, symbols: []) == nil)
        #expect(
            TrailPointQuery.query(in: boxes, symbols: [.junction, .caution]) == nil,
            "symbols no kind is drawn as ask for nothing either"
        )
    }

    /// The maker draws one switch per entry, so this is the list of rows: every
    /// symbol a kind is drawn as, once each, in the tie-break order.
    @Test("the switchable symbols are the ones a search can find")
    func theSwitchableSymbols() {
        #expect(TrailPointQuery.searchableSymbols == [.summit, .water, .shelter, .viewpoint, .camp, .parking])
    }

    /// **The exclusion that is 57% of the bytes.** `tourism=information` is
    /// 579 of the 1,206 elements every candidate tag returns over the measured
    /// box and 6% of them carry a name: they are the boards and the guideposts,
    /// they cluster at every junction, and on screen they are a wall of
    /// identical pins over the line the hiker is drawing.
    ///
    /// The other three are left out because this app has no glyph that would
    /// be honest about them — see ``TrailPointQuery``'s header.
    @Test("the noisy and the unglyphed kinds are never asked for")
    func theExcludedKindsAreNeverAsked() throws {
        let text = try #require(Self.query())

        for excluded in ["information", "toilets", "cave_entrance", "picnic_site"] {
            #expect(!text.contains(excluded), "\(excluded) is deliberately not asked for")
        }
    }

    /// Nodes for nine of the eleven, and `nwr` only where the thing is
    /// normally a building. Measured: asking `nwr` for everything adds 749
    /// elements over the Berchtesgaden box, 695 of which are car parks drawn
    /// as polygons.
    @Test("areas are asked for only where a place is normally a building")
    func areasAreAskedForOnlyWhereTheyAreBuildings() throws {
        let text = try #require(Self.query())

        #expect(text.contains("nwr[\"tourism\"=\"alpine_hut\"]"), "a hut is a building")
        #expect(text.contains("nwr[\"amenity\"=\"shelter\"]"))
        #expect(text.contains("nwr[\"tourism\"=\"camp_site\"]"))
        #expect(text.contains("node[\"amenity\"=\"parking\"]"), "and a car park is not")
        #expect(!text.contains("nwr[\"amenity\"=\"parking\"]"))
        #expect(text.contains("node[\"natural\"=\"peak\"]"))
    }

    // MARK: - How wide

    /// The ceiling is what makes this file's measured figures the worst case:
    /// 10 km circumscribes a 20 × 20 km box, within a per cent of the box
    /// everything was measured over.
    @Test("a search wider than the ceiling asks nothing at all")
    func aWideSearchAsksNothing() {
        let boxes = TrailPointQuery.searchBoxes(
            for: Self.area(radiusMeters: TrailPointQuery.maximumRadiusMeters + 1)
        )

        #expect(boxes.isEmpty)
        #expect(TrailPointQuery.query(in: boxes) == nil, "and there is no request to make")
    }

    /// A quarter of the community list's own ceiling, and deliberately: that
    /// one lists relations, whose count grows slowly with area, and this lists
    /// features, whose count grows with it directly.
    @Test("the ceiling is tighter than the curated one")
    func theCeilingIsTighterThanTheCuratedOne() {
        #expect(TrailPointQuery.maximumRadiusMeters < CuratedTrailQuery.maximumRadiusMeters)

        let atCuratedCeiling = Self.area(radiusMeters: CuratedTrailQuery.maximumRadiusMeters)
        #expect(!CuratedTrailQuery.searchBoxes(for: atCuratedCeiling).isEmpty)
        #expect(
            TrailPointQuery.searchBoxes(for: atCuratedCeiling).isEmpty,
            "the same area is a trail search and not a place search"
        )
    }

    /// The date line is ``CuratedTrailQuery``'s arithmetic, reused rather than
    /// copied — so a search at 179.9° asks about both halves of its circle in
    /// one request rather than silently losing one of them.
    @Test("a search across the antimeridian asks about both halves, once")
    func aSearchAcrossTheAntimeridianAsksAboutBothHalves() throws {
        let area = CommunitySearchArea(
            coordinate: CLLocationCoordinate2D(latitude: 60, longitude: 179.98),
            radiusMeters: 9000
        )

        let boxes = TrailPointQuery.searchBoxes(for: area)
        let text = try #require(TrailPointQuery.query(in: boxes))

        #expect(boxes.count == 2)
        #expect(
            text.components(separatedBy: "node[\"natural\"=\"peak\"]").count - 1 == 2,
            "one filter per box, in one union"
        )
    }

    // MARK: - Which symbol

    /// The mapping the whole feature rests on: a row and a pin are built from
    /// the symbol, because four fifths of these places have no name.
    @Test(
        "each kind of place is drawn as the symbol it is",
        arguments: [
            (["natural": "peak"], TrailPlaceSymbol.summit),
            (["natural": "saddle"], .summit),
            (["waterway": "waterfall"], .water),
            (["natural": "spring"], .water),
            (["amenity": "drinking_water"], .water),
            (["tourism": "alpine_hut"], .shelter),
            (["tourism": "wilderness_hut"], .shelter),
            (["amenity": "shelter"], .shelter),
            (["tourism": "viewpoint"], .viewpoint),
            (["tourism": "camp_site"], .camp),
            (["amenity": "parking"], .parking),
        ]
    )
    func eachKindIsDrawnAsItsSymbol(tags: [String: String], symbol: TrailPlaceSymbol) {
        #expect(TrailPointQuery.symbol(for: tags) == symbol)
    }

    /// One element routinely carries several of these — a summit with a bench
    /// and a view — and the same search must draw the same map twice. The
    /// order ``TrailPointQuery/kinds`` is written in is the tie-break, and a
    /// summit wins.
    @Test("a peak that is also a viewpoint is a summit")
    func aPeakThatIsAlsoAViewpointIsASummit() {
        let tags = ["natural": "peak", "tourism": "viewpoint", "amenity": "bench"]

        #expect(TrailPointQuery.symbol(for: tags) == .summit)
    }

    /// **The tie-break is among the switches that are on.** With *Summits*
    /// off in the maker, that same peak was asked for as a viewpoint, and a
    /// hiker who kept *Viewpoints* on is owed it — drawn as a summit, the
    /// finder would throw it away as a kind they turned off.
    @Test("with summits switched off, a peak that is also a viewpoint is a viewpoint")
    func aPeakWithSummitsOffIsAViewpoint() {
        let tags = ["natural": "peak", "tourism": "viewpoint", "amenity": "bench"]
        let summitsOff = Set(TrailPointQuery.searchableSymbols).subtracting([.summit])

        #expect(TrailPointQuery.symbol(for: tags, among: summitsOff) == .viewpoint)
        #expect(
            TrailPointQuery.symbol(for: tags, among: summitsOff.subtracting([.viewpoint])) == nil,
            "with both off it is nothing this search asked for"
        )
    }

    /// Two of the eight symbols get no mapping on purpose: the only OSM answer
    /// for a junction *is* the guidepost this deliberately never asks for, and
    /// a hazard is a judgement about a place rather than a tag on one.
    @Test("junction and caution are never answered for")
    func junctionAndCautionAreNeverAnswered() {
        let mapped = Set(TrailPointQuery.kinds.map(\.symbol))

        #expect(!mapped.contains(.junction))
        #expect(!mapped.contains(.caution))
    }

    /// Reachable even though everything was asked for by one of these filters:
    /// a mirror can answer with more than was asked, and a place this cannot
    /// name is not offered.
    @Test("an element carrying none of the tags has no symbol")
    func anUnknownElementHasNoSymbol() {
        #expect(TrailPointQuery.symbol(for: ["tourism": "information"]) == nil)
        #expect(TrailPointQuery.symbol(for: [:]) == nil)
    }
}
