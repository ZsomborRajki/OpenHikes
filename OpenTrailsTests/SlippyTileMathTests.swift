//
//  SlippyTileMathTests.swift
//  OpenTrailsTests
//
//  Tile indexing is the join between three things that must agree exactly:
//  what the renderer asks the tile server for, what the bulk downloader
//  saves, and what the auto-save corridor decides is "near the trail". A
//  disagreement here doesn't crash — it just means the tiles a user saved for
//  their hike aren't the ones the map asks for when they're out of signal.
//
//  The projection itself is covered in OpenTrailsShared's MercatorTests; what
//  is checked here is this layer's own job: scaling to a zoom level, and the
//  deliberately different treatment of x (cyclic — wraps) and y (bounded —
//  clamps).
//

import Foundation
import Testing
@testable import OpenTrails

@Suite("Slippy tile math")
struct SlippyTileMathTests {
    /// Zoom 0 is one tile for the whole world; every coordinate lands in it.
    @Test("the world is one tile at zoom 0", arguments: [
        (0.0, 0.0), (85.0, 179.9), (-85.0, -179.9), (47.63, 12.86)
    ])
    func zoomZero(latitude: Double, longitude: Double) {
        #expect(SlippyTileMath.tileX(longitude, z: 0) == 0)
        #expect(SlippyTileMath.tileY(latitude, z: 0) == 0)
    }

    /// The four quadrants at zoom 1, which is the whole convention in one
    /// test: x grows east from the antimeridian, y grows *south* from the top.
    @Test("zoom 1 splits the world into the expected quadrants")
    func quadrants() {
        #expect(SlippyTileMath.tileX(-0.1, z: 1) == 0)   // London, west of Greenwich
        #expect(SlippyTileMath.tileY(51.5, z: 1) == 0)   // northern hemisphere
        #expect(SlippyTileMath.tileX(151.2, z: 1) == 1)  // Sydney, eastern hemisphere
        #expect(SlippyTileMath.tileY(-33.9, z: 1) == 1)  // southern hemisphere
    }

    /// Null island sits on the corner where all four center tiles meet, so
    /// the floor lands it in the south-east one at every zoom.
    @Test("the origin lands on the middle of the grid", arguments: [1, 5, 10, 19])
    func origin(z: Int) {
        #expect(SlippyTileMath.tileX(0, z: z) == 1 << (z - 1))
        #expect(SlippyTileMath.tileY(0, z: z) == 1 << (z - 1))
    }

    /// A point inside a tile has to resolve back to that tile — otherwise a
    /// corridor built from tile edges (see `TileCorridor.overlaps`) would be
    /// testing a different patch of ground than the one being saved.
    ///
    /// Sampled at tile centers rather than corners on purpose: a coordinate
    /// exactly on a shared edge is ambiguous by a rounding ulp, and neither
    /// neighbour is the wrong answer (see `edgesLandOnEitherNeighbour`).
    @Test("a point inside a tile resolves back to that tile", arguments: [10, 14, 17, 19, 22])
    func centersRoundTrip(z: Int) {
        let n = 1 << z
        for index in stride(from: 0, to: n, by: max(1, n / 97)) {
            let midLon = (SlippyTileMath.lon(x: index, z: z) + SlippyTileMath.lon(x: index + 1, z: z)) / 2
            let midLat = (SlippyTileMath.lat(y: index, z: z) + SlippyTileMath.lat(y: index + 1, z: z)) / 2
            #expect(SlippyTileMath.tileX(midLon, z: z) == index)
            #expect(SlippyTileMath.tileY(midLat, z: z) == index)
        }
    }

    /// The shared edge between two tiles belongs to one of them — which one
    /// is a rounding detail, but it must never be a third tile, because that
    /// would mean the grid has a seam.
    @Test("a tile edge lands on one of the two tiles that share it", arguments: [10, 14, 19])
    func edgesLandOnEitherNeighbour(z: Int) {
        let n = 1 << z
        for index in stride(from: 1, to: n, by: max(1, n / 97)) {
            #expect([index - 1, index].contains(SlippyTileMath.tileX(SlippyTileMath.lon(x: index, z: z), z: z)))
            #expect([index - 1, index].contains(SlippyTileMath.tileY(SlippyTileMath.lat(y: index, z: z), z: z)))
        }
    }

    /// Tile rows/columns increase monotonically as you move east/south, at
    /// every zoom the providers serve.
    @Test("indices are monotonic in both axes", arguments: [10, 14, 19, 22])
    func monotonic(z: Int) {
        var lastX = -1
        for longitude in stride(from: -180.0, through: 179.0, by: 7.5) {
            let x = SlippyTileMath.tileX(longitude, z: z)
            #expect(x >= lastX)
            lastX = x
        }
        var lastY = -1
        for latitude in stride(from: 85.0, through: -85.0, by: -3.5) {
            let y = SlippyTileMath.tileY(latitude, z: z)
            #expect(y >= lastY)
            lastY = y
        }
    }

    // MARK: Normalizing what MapKit hands out

    /// x is cyclic: MapKit keeps counting columns as the map is panned around
    /// the world, and those have to fold back onto the real grid rather than
    /// pile up at the edge (which is what produced blank tiles and 400s from
    /// the tile server).
    @Test("columns wrap around the world")
    func wrap() {
        #expect(SlippyTileMath.wrap(0, to: 4) == 0)
        #expect(SlippyTileMath.wrap(3, to: 4) == 3)
        #expect(SlippyTileMath.wrap(4, to: 4) == 0)
        #expect(SlippyTileMath.wrap(9, to: 4) == 1)
        #expect(SlippyTileMath.wrap(-1, to: 4) == 3)
        #expect(SlippyTileMath.wrap(-8, to: 4) == 0)
    }

    @Test("wrapping always lands inside the grid", arguments: [1, 4, 1024])
    func wrapStaysInRange(n: Int) {
        for value in -3 * n ... 3 * n {
            #expect((0..<n).contains(SlippyTileMath.wrap(value, to: n)))
        }
    }

    /// y is bounded: latitude doesn't wrap, so a row past the poles is pinned
    /// to the edge row instead of reappearing on the other side of the world.
    @Test("rows clamp to the grid")
    func clamp() {
        #expect(SlippyTileMath.clamp(-5, to: 4) == 0)
        #expect(SlippyTileMath.clamp(0, to: 4) == 0)
        #expect(SlippyTileMath.clamp(3, to: 4) == 3)
        #expect(SlippyTileMath.clamp(4, to: 4) == 3)
        #expect(SlippyTileMath.clamp(99, to: 4) == 3)
    }

    /// The projection clamps rather than trapping, so even nonsense latitudes
    /// produce an index the tile grid can hold — this is what stops a
    /// malformed GPX from taking the app down through `Int(floor(...))`.
    @Test("extreme latitudes still produce a usable row", arguments: [90.0, -90.0, 1e9, -1e9])
    func extremeLatitudes(latitude: Double) {
        let z = 19
        let y = SlippyTileMath.tileY(latitude, z: z)
        #expect((0..<(1 << z)).contains(SlippyTileMath.clamp(y, to: 1 << z)))
    }
}
