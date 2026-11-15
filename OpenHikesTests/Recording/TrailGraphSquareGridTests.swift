//
//  TrailGraphSquareGridTests.swift
//  OpenHikesTests
//
//  Which square answers for a region of the trail graph, and what its record
//  is called — a storage contract, because every installed build asks for the
//  names it knows. The grid spells the slippy map's arithmetic itself, for the
//  tool, so the cases here hold it to the app's.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Trail graph square grid")
struct TrailGraphSquareGridTests {
    /// Points the provider's regions are asked about, from the equator to the
    /// edge of the slippy map, either side of Greenwich and of the
    /// antimeridian.
    static let points: [(Double, Double)] = [
        (47.63, 12.86), (0, 0), (-33.9, 151.2), (64.1, -21.9), (85.05, 179.99),
        (-85.05, -179.99), (35.36, 138.73), (-54.8, -68.3), (46.5, 7.98), (51.5, -0.12),
    ]

    @Test("a square's rows and columns are the slippy map's, as the provider counts them")
    func theTileArithmeticIsTheApps() {
        for (latitude, longitude) in Self.points {
            for zoom in [TrailGraphSquareGrid.squareZoom, TrailGraphSquareGrid.regionZoom] {
                let count = 1 << zoom
                #expect(
                    TrailGraphSquareGrid.tileX(longitude, zoom: zoom)
                        == SlippyTileMath.clamp(SlippyTileMath.tileX(longitude, z: zoom), to: count),
                    "column at \(latitude), \(longitude), zoom \(zoom)"
                )
                #expect(
                    TrailGraphSquareGrid.tileY(latitude, zoom: zoom)
                        == SlippyTileMath.clamp(SlippyTileMath.tileY(latitude, z: zoom), to: count),
                    "row at \(latitude), \(longitude), zoom \(zoom)"
                )
            }
        }
    }

    /// Every region the provider asks about lies in one square, which is the
    /// square the region's own corner is in.
    @Test("a region lies in the square its points are filed under")
    func aRegionLiesInItsSquare() throws {
        let provider = OverpassTrailGraphProvider(directory: nil)
        for (latitude, longitude) in Self.points {
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            let region = try #require(provider.region(containing: coordinate))
            let square = try #require(TrailGraphSquareGrid.square(forRegionX: region.x, y: region.y, zoom: region.zoom))

            #expect(square == TrailGraphSquare(
                x: TrailGraphSquareGrid.tileX(longitude, zoom: TrailGraphSquareGrid.squareZoom),
                y: TrailGraphSquareGrid.tileY(latitude, zoom: TrailGraphSquareGrid.squareZoom)
            ))
        }
        #expect(TrailGraphSquareGrid.square(forRegionX: 1, y: 1, zoom: 11) == nil, "not a region of the graph")
        #expect(TrailGraphSquareGrid.square(forRegionX: 4096, y: 0, zoom: 12) == nil, "past the last column")
    }

    @Test("a box is filed under every square it touches")
    func aBoxTouchesItsSquares() {
        let inside = TrailGraphSquareGrid.squares(touchingSouth: 47.62, west: 12.86, north: 47.63, east: 12.87)
        let across = TrailGraphSquareGrid.squares(touchingSouth: 47.62, west: 12.65, north: 47.63, east: 12.66)

        #expect(inside == [TrailGraphSquare(x: 548, y: 357)])
        #expect(Set(across.map(\.x)) == [547, 548], "12.656° is a square's western edge at zoom 10")
        #expect(TrailGraphSquareGrid.squares(touchingSouth: 48, west: 13, north: 47, east: 14).isEmpty)
    }

    @Test("a record name reads back as its square, and nothing else does")
    func recordNamesReadBack() {
        let square = TrailGraphSquare(x: 548, y: 357)

        #expect(TrailGraphSquareGrid.recordName(for: square) == "graph1_z10_548_357")
        #expect(TrailGraphSquareGrid.square(named: "graph1_z10_548_357") == square)
        #expect(TrailGraphSquareGrid.manifestRecordName == "graph1_manifest")
        #expect(TrailGraphSquareGrid.square(named: "graph1_manifest") == nil)
        #expect(TrailGraphSquareGrid.square(named: "graph1_z11_548_357") == nil, "another zoom's square")
        #expect(TrailGraphSquareGrid.square(named: "graph1_z10_1024_0") == nil, "past the last column")
        #expect(TrailGraphSquareGrid.square(named: "routes1_z10_548_357") == nil, "the layer's names are its own")
        #expect(TrailGraphSquareGrid.square(named: "places1_137_192") == nil)
    }
}
