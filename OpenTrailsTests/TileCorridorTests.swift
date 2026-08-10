//
//  TileCorridorTests.swift
//  OpenTrailsTests
//
//  The corridor is what keeps auto-save honest: it saves tiles the user
//  browses, but only the ones near the trail they're browsing. Too tight and
//  a hike's offline map has holes exactly where the user zoomed in; too
//  loose and panning across a country quietly fills the 3,000-tile budget
//  with scenery the trail never touches.
//

import CoreLocation
import Foundation
import Testing
@testable import OpenTrails

@Suite("Tile corridor")
struct TileCorridorTests {
    /// The corridor as `AutoSaveTileStore` builds it, around the ridge route.
    private let corridor = TileCorridor(
        route: Fixture.coordinates(Fixture.ridgeRoute),
        bufferMeters: AutoSaveTileStore.corridorBufferMeters
    )

    /// The tile containing a coordinate, at a given zoom.
    private func tile(at coordinate: CLLocationCoordinate2D, z: Int) -> (z: Int, x: Int, y: Int) {
        (z, SlippyTileMath.tileX(coordinate.longitude, z: z), SlippyTileMath.tileY(coordinate.latitude, z: z))
    }

    /// `metres` north/east of a coordinate — rough, but exact enough to sit
    /// confidently inside or outside a 1.5 km buffer.
    private func offset(_ coordinate: CLLocationCoordinate2D, northMeters: Double, eastMeters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: coordinate.latitude + northMeters / 111_320,
            longitude: coordinate.longitude + eastMeters / (111_320 * cos(coordinate.latitude * .pi / 180))
        )
    }

    @Test("every tile the trail runs through is in the corridor", arguments: [12, 14, 16, 18])
    func trailTilesIncluded(z: Int) {
        for coordinate in Fixture.coordinates(Fixture.ridgeRoute) {
            let tile = tile(at: coordinate, z: z)
            #expect(corridor.overlaps(z: z, x: tile.x, y: tile.y))
        }
    }

    /// The buffer is the point: a user zooming in beside the trail should
    /// still be filling their offline map, not browsing for nothing.
    @Test("tiles just off the trail are still in the corridor")
    func bufferIncludesNearbyTiles() {
        let z = 16
        let anchor = Fixture.coordinates(Fixture.ridgeRoute)[2]
        for (north, east) in [(800.0, 0.0), (0.0, 800.0), (-800.0, 0.0), (0.0, -800.0), (700.0, 700.0)] {
            let tile = tile(at: offset(anchor, northMeters: north, eastMeters: east), z: z)
            #expect(corridor.overlaps(z: z, x: tile.x, y: tile.y), "\(north)m N / \(east)m E should be inside the corridor")
        }
    }

    /// And the limit is the other half of the point.
    @Test("tiles well beyond the buffer are excluded")
    func farTilesExcluded() {
        let z = 16
        let anchor = Fixture.coordinates(Fixture.ridgeRoute)[2]
        for (north, east) in [(6_000.0, 0.0), (0.0, 6_000.0), (-6_000.0, 0.0), (0.0, -6_000.0)] {
            let tile = tile(at: offset(anchor, northMeters: north, eastMeters: east), z: z)
            #expect(!corridor.overlaps(z: z, x: tile.x, y: tile.y), "\(north)m N / \(east)m E should be outside the corridor")
        }
    }

    /// Another country is not near the trail, at any zoom the map can reach.
    @Test("a tile on the far side of the world is never in the corridor", arguments: [10, 14, 19])
    func elsewhereExcluded(z: Int) {
        let tile = tile(at: CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86), z: z)
        #expect(!corridor.overlaps(z: z, x: tile.x, y: tile.y))
    }

    /// Membership is by overlap, not by center: a tile that merely clips the
    /// corridor's edge still gets saved, so there's no missing tile at the
    /// boundary of a saved area.
    @Test("a tile that only clips the corridor is still included")
    func edgeTilesIncluded() {
        let z = 14
        let anchor = Fixture.coordinates(Fixture.ridgeRoute)[0]
        let tile = tile(at: anchor, z: z)
        // At z14 a tile is ~2.4 km across at this latitude, and the corridor
        // extends 1.5 km past the route — so the neighbouring tiles overlap
        // it even though their centers are outside.
        #expect(corridor.overlaps(z: z, x: tile.x - 1, y: tile.y))
        #expect(corridor.overlaps(z: z, x: tile.x, y: tile.y - 1))
    }

    /// A wider buffer can only ever add tiles.
    @Test("a bigger buffer never excludes what a smaller one accepted")
    func bufferIsMonotonic() {
        let z = 15
        let tight = TileCorridor(route: Fixture.coordinates(Fixture.ridgeRoute), bufferMeters: 200)
        let wide = TileCorridor(route: Fixture.coordinates(Fixture.ridgeRoute), bufferMeters: 5_000)
        let anchor = tile(at: Fixture.coordinates(Fixture.ridgeRoute)[0], z: z)
        for dx in -6...6 {
            for dy in -6...6 {
                if tight.overlaps(z: z, x: anchor.x + dx, y: anchor.y + dy) {
                    #expect(wide.overlaps(z: z, x: anchor.x + dx, y: anchor.y + dy))
                }
            }
        }
    }

    /// A hike with no points has nowhere to be near. `AutoSaveController`
    /// only ever activates hikes with more than one point, so this is a
    /// belt-and-braces check that an empty corridor can't be built into
    /// something that accepts the world.
    @Test("an empty route's corridor accepts nothing around a real trail")
    func emptyRoute() {
        let empty = TileCorridor(route: [], bufferMeters: AutoSaveTileStore.corridorBufferMeters)
        let z = 14
        for coordinate in Fixture.coordinates(Fixture.ridgeRoute) {
            let tile = tile(at: coordinate, z: z)
            #expect(!empty.overlaps(z: z, x: tile.x, y: tile.y))
        }
    }
}
