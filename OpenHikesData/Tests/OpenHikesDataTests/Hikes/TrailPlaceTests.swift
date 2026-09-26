//
//  TrailPlaceTests.swift
//  OpenHikesTests
//
//  The value a marked place is, and where along a line it sits.
//
//  The ordering is the half worth pinning. Nothing on screen says which
//  segment of a route a place was measured against — the list shows a
//  distance and the callout shows the same one — so a place attached to the
//  wrong crossing of a trail that doubles back looks exactly like a place
//  attached to the right one, and the only thing that can tell them apart is
//  a test that knows the geometry.
//

import CoreLocation
@testable import OpenHikesData
import Testing

@Suite("Trail places")
struct TrailPlaceTests {
    /// A north-running line at a longitude nothing else here uses, so a
    /// projection that fell through to a default would land visibly elsewhere.
    private enum Line {
        static let longitude = 12.98
        static let south = 47.60
        static let north = 47.62
    }

    private static func route(from south: Double, to north: Double) -> [RouteCoordinate] {
        [
            RouteCoordinate(latitude: south, longitude: Line.longitude),
            RouteCoordinate(latitude: north, longitude: Line.longitude),
        ]
    }

    private static func place(
        _ latitude: Double,
        _ longitude: Double = Line.longitude,
        name: String = "",
        symbol: TrailPlaceSymbol? = nil
    ) -> TrailPlace {
        TrailPlace(latitude: latitude, longitude: longitude, name: name, symbol: symbol)
    }

    // MARK: What it draws

    /// A place that claims nothing draws a plain pin rather than being given
    /// one of the eight — see ``TrailPlace`` for why an unstated symbol is a
    /// state rather than a missing value.
    @Test("a place with no symbol draws a plain pin")
    func placesWithNoSymbolDrawAPlainPin() {
        #expect(Self.place(Line.south).systemImageName == "mappin")
        #expect(Self.place(Line.south, symbol: .summit).systemImageName != "mappin")
    }

    /// The raw value is the stored id *and* the GPX `<sym>`, so it is the one
    /// string in this type that may never be translated or renamed.
    @Test("a symbol's raw value round-trips")
    func symbolRawValuesRoundTrip() {
        for symbol in TrailPlaceSymbol.allCases {
            #expect(TrailPlaceSymbol.named(symbol.rawValue) == symbol)
        }
        #expect(TrailPlaceSymbol.named("") == nil)
        #expect(TrailPlaceSymbol.named("Cave") == nil, "a case this build does not know is not a crash")
    }

    // MARK: Where it sits

    @Test("places are ordered by how far along the line they are met")
    func placesAreOrderedAlongTheLine() {
        let route = Self.route(from: Line.south, to: Line.north)
        let far = Self.place(Line.north - 0.002, name: "Far")
        let near = Self.place(Line.south + 0.002, name: "Near")

        let ordered = TrailPlaceOrder.ordered([far, near], along: route)

        #expect(ordered.map(\.place.name) == ["Near", "Far"])
        let first = ordered[0].anchor
        let second = ordered[1].anchor
        #expect(first != nil)
        #expect(second != nil)
        #expect((first?.distanceAlongRouteMeters ?? 0) < (second?.distanceAlongRouteMeters ?? 0))
    }

    /// A place a hiker dropped a long way from their line is not *at* any
    /// distance along it, and a row claiming otherwise would be worse than one
    /// that says nothing — see ``TrailPlaceAnchor/describableOffRouteMeters``.
    @Test("a place far off the line carries no distance")
    func placesFarOffTheLineCarryNoDistance() {
        let route = Self.route(from: Line.south, to: Line.north)
        // About a kilometre east of the line, which is four times the bound.
        let aside = Self.place(Line.south + 0.01, Line.longitude + 0.0134, name: "Aside")

        let ordered = TrailPlaceOrder.ordered([aside], along: route)

        #expect(ordered.count == 1)
        #expect(ordered[0].anchor == nil, "a figure nobody should read is worse than none")
        // How far *off* it is still holds, and is what *Places Around Trail*
        // sorts and filters by.
        let off = ordered[0].offRouteMeters ?? 0
        #expect(off > 900 && off < 1100)
        #expect(!ordered[0].isOnTheLine)
    }

    /// Marking a place before drawing anything is a reasonable thing to do
    /// first, so it has to survive having nothing to be measured against.
    @Test("places with no line keep the order they were marked in")
    func placesWithNoLineKeepTheirOrder() {
        let ordered = TrailPlaceOrder.ordered(
            [Self.place(Line.north, name: "First"), Self.place(Line.south, name: "Second")],
            along: []
        )

        #expect(ordered.map(\.place.name) == ["First", "Second"])
        #expect(ordered.allSatisfy { $0.anchor == nil })
    }

    /// Nearest to the line wins, not first along it. A trail that doubles back
    /// passes a spot twice, and the crossing the hiker means is the one it
    /// actually touches.
    @Test("a place on a trail that doubles back takes the nearer crossing")
    func doublingBackTakesTheNearerCrossing() throws {
        // North, then back south a little to the east: the return leg passes
        // much closer to the place than the outward one does.
        let route = [
            RouteCoordinate(latitude: Line.south, longitude: Line.longitude),
            RouteCoordinate(latitude: Line.north, longitude: Line.longitude),
            RouteCoordinate(latitude: Line.south, longitude: Line.longitude + 0.004),
        ]
        let beside = Self.place(Line.south + 0.002, Line.longitude + 0.0035)

        let anchors = TrailPlaceOrder.anchors(of: [beside], along: route)
        let anchor = try #require(anchors[beside.id])

        // The outward leg is ~260 m away at that latitude; the return leg is a
        // few tens of metres. The nearer one is what the figure is measured on,
        // which puts the place late along the line rather than early.
        let total = RouteGeometry.distanceMeters(
            from: route[0].clCoordinate,
            to: route[1].clCoordinate
        )
        #expect(anchor.distanceAlongRouteMeters > total, "the return leg is the nearer crossing")
        #expect(anchor.describesTheRoute)
    }

    // MARK: What a save keeps

    /// A save keeps the places the line passes and nothing a search merely
    /// found near it — see ``TrailPlaceAnchor/touchedOffRouteMeters``.
    ///
    /// At this latitude a thousandth of a degree of longitude is about 75 m,
    /// so the two are either side of the bound with room to spare.
    @Test("only the places the line passes are touched")
    func onlyPlacesOnTheLineAreTouched() {
        let route = Self.route(from: Line.south, to: Line.north)
        let onIt = Self.place(Line.south + 0.004, name: "Spring")
        let byTheDoor = Self.place(Line.south + 0.008, Line.longitude + 0.0004, name: "Hut")
        let upASidePath = Self.place(Line.south + 0.012, Line.longitude + 0.001, name: "Viewpoint")
        let acrossTheValley = Self.place(Line.north, Line.longitude + 0.0134, name: "Summit")

        let touched = TrailPlaceOrder.touched(
            [acrossTheValley, byTheDoor, upASidePath, onIt],
            along: route
        )

        // In the order they were given: ordering is ``ordered(_:along:)``'s job,
        // and a save writes rows that are ranked when they are read.
        #expect(touched.map(\.name) == ["Hut", "Spring"])
    }

    /// Nothing is on a line that is not there.
    @Test("no place is touched by a route of fewer than two points")
    func nothingIsTouchedWithoutALine() {
        let spring = Self.place(Line.south)

        #expect(TrailPlaceOrder.touched([spring], along: []).isEmpty)
        #expect(TrailPlaceOrder.touched([spring], along: [spring.routeCoordinate]).isEmpty)
    }
}

private extension RouteCoordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
