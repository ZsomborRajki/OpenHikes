//
//  TileBoundingBoxTests.swift
//  OpenHikesTests
//
//  The tile columns a route's box spans, which an offline download takes and
//  the auto-save corridor admits. The box keeps a west edge and a span and
//  rebuilds its east edge by adding them, so the case that goes wrong is a
//  route whose east end lies exactly on a column's west edge: a span an ulp
//  short puts that end in the column before, and the column the route ends
//  in is left out. `CircularSpanTests` holds the arc itself; this holds what
//  a download is planned from.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing

@Suite("Tile bounding box")
struct TileBoundingBoxTests {
    private static func route(_ longitudes: [Double]) -> [CLLocationCoordinate2D] {
        longitudes.map { CLLocationCoordinate2D(latitude: 40.7, longitude: $0) }
    }

    /// -73.828125 is the west edge of column 302 at zoom 10, where the walk
    /// ends after starting in column 301.
    @Test("a route that ends on a column's west edge keeps that column")
    func eastEndOnAColumnEdge() throws {
        let box = try #require(TileBoundingBox(route: Self.route([-73.8390275, -73.828125])))

        let columns = box.columns(at: 10)
        #expect(columns.first == 301)
        #expect(columns.count == 2)
    }

    /// Each route ends on the west edge of a zoom 10 column, and so of a
    /// column at every deeper zoom: an ordinary walk, a walk across ±180°
    /// that ends on column 1 (-179.6484375), and a walk across Greenwich
    /// that ends on column 513 (0.3515625). Each lost the column it ends in
    /// at zoom 10 and at every deeper one once the start was exact and the
    /// span still 360 less the widest gap.
    @Test("both ends of a route are in its box at every zoom", arguments: [
        [-73.8390275, -73.828125],
        [179.6, -179.6484375],
        [-0.02, 0.3515625],
    ])
    func endsAreInTheBox(longitudes: [Double]) throws {
        let route = Self.route(longitudes)
        let box = try #require(TileBoundingBox(route: route))

        for z in 0...20 {
            let n = 1 << z
            for coordinate in route {
                let x = SlippyTileMath.wrap(SlippyTileMath.tileX(coordinate.longitude, z: z), to: n)
                let y = SlippyTileMath.tileY(coordinate.latitude, z: z)
                #expect(box.contains(z: z, x: x, y: y), "\(coordinate.longitude)° at zoom \(z)")
            }
        }
    }
}
