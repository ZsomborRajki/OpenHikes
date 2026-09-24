//
//  OfflineTileDownloaderTests.swift
//  OpenHikesTests
//
//  Bulk download is the half of offline maps that runs ahead of time, and
//  its bookkeeping is deliberately *derived*: nothing records which tiles a
//  download saved, the set is recomputed from the route whenever it has to
//  be measured or deleted. That only works if the enumeration is exactly
//  reproducible and its keys are byte-identical to the ones the renderer
//  looks up — otherwise a hike reports 0 bytes saved and "Delete" frees
//  nothing.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Offline tile enumeration")
struct OfflineTileEnumerationTests {
    private let route = Fixture.coordinates(Fixture.ridgeRoute)

    private func keys(maxZoom: Int = 14, providerMaxZoom: Int = 19) -> [String] {
        OfflineTileDownloader.tileKeys(
            for: route,
            providerID: TileProvider.openStreetMap.id,
            providerMaxZoom: providerMaxZoom,
            maxZoom: maxZoom
        )
    }

    private func zoomLevels(in keys: [String]) -> Set<Int> {
        Set(keys.compactMap { Int($0.split(separator: "/").dropFirst().first ?? "") })
    }

    // MARK: The derived-bookkeeping contract

    /// The whole storage-accounting design rests on this: recomputing the
    /// set yields exactly what was saved.
    @Test("enumeration is reproducible")
    func deterministic() {
        let first = keys()
        let second = keys()
        #expect(first == second)
        #expect(Set(keys()).count == keys().count, "a tile should not be enumerated twice")
    }

    @Test("a partial record claims only tiles verified on disk")
    func partialRecordUsesExactKeys() async throws {
        let exact = ["test/10/1/1", "test/10/1/2"]
        let record = OfflineDownloadRecord(
            providerID: "test",
            maxZoom: 19,
            savedTileKeys: exact
        )
        let stored = try await offMain {
            try OfflineTileDownloader.storedTileKeys(route: route, offlineDownloads: [record])
        }
        #expect(Set(stored) == Set(exact))
    }

    /// The renderer looks tiles up as `providerID/z/x/y`. The
    /// downloader builds the same string from a different code path; if the
    /// two ever drift, every pre-downloaded tile becomes invisible to the map
    /// and gets fetched again.
    @Test("download keys are exactly the keys the renderer asks for")
    func keyFormatMatchesRenderer() {
        let path = MKTileOverlayPath(x: 8723, y: 5685, z: 14, contentScaleFactor: 2)
        let rendererKey = "\(TileProvider.openStreetMap.id)/\(path.cacheKey)"
        let downloaderKey = OfflineTileDownloader.Tile(z: path.z, x: path.x, y: path.y)
            .cacheKey(providerID: TileProvider.openStreetMap.id)
        #expect(rendererKey == downloaderKey)
        #expect(
            downloaderKey == TileCacheKey.namespaced(
                providerID: TileProvider.openStreetMap.id,
                z: path.z,
                x: path.x,
                y: path.y
            )
        )
        #expect(downloaderKey == "osm/14/8723/5685")
    }

    /// Display scale is *not* part of a tile's identity, and this is the
    /// regression guard for the bug that proved it had to stop being one.
    ///
    /// MapKit documents `contentScaleFactor` as "typically either 1.0 or 2.0"
    /// and never hands the renderer a 3, while SwiftUI's `displayScale` — what
    /// the download path used to read — is 3.0 on every Plus/Pro/Pro Max. A
    /// key carrying either value therefore made a downloaded tile invisible to
    /// the map on those devices. A renderer path is the only thing in the app
    /// that has ever carried a scale, so a path at 3× and a path at 2× naming
    /// the same tile must produce one key, and the downloader must produce it
    /// too.
    @Test("display scale is not part of the identity of a tile")
    func scaleDoesNotNamespaceKeys() {
        let at2x = MKTileOverlayPath(x: 8723, y: 5685, z: 14, contentScaleFactor: 2)
        let at3x = MKTileOverlayPath(x: 8723, y: 5685, z: 14, contentScaleFactor: 3)
        #expect(at2x.cacheKey == at3x.cacheKey)
        #expect(
            OfflineTileDownloader.Tile(z: 14, x: 8723, y: 5685).cacheKey(providerID: "osm")
                == "osm/\(at3x.cacheKey)"
        )
    }

    @Test("provider is part of the identity of a tile")
    func providerNamespacesKeys() {
        let osm = OfflineTileDownloader.tileKeys(
            for: route, providerID: "osm", providerMaxZoom: 19, maxZoom: 12
        )
        let other = OfflineTileDownloader.tileKeys(
            for: route, providerID: "stadia_outdoors", providerMaxZoom: 20, maxZoom: 12
        )
        #expect(Set(osm).isDisjoint(with: Set(other)))
    }

    // MARK: Coverage

    /// The promise of the feature: after a download, every part of the trail
    /// has a tile at every zoom that was saved.
    @Test("every point of the route is covered at every enumerated zoom")
    func coversTheWholeRoute() {
        let keys = Set(keys())
        for z in zoomLevels(in: Array(keys)) {
            for coordinate in route {
                let x = SlippyTileMath.tileX(coordinate.longitude, z: z)
                let y = SlippyTileMath.tileY(coordinate.latitude, z: z)
                #expect(keys.contains("osm/\(z)/\(x)/\(y)"), "no tile covers the route at zoom \(z)")
            }
        }
    }

    /// Zoom levels run from the overview zoom up, without gaps — a missing
    /// level in the middle would be a band of blur at exactly that zoom.
    @Test("zoom levels are contiguous from the overview zoom upward")
    func contiguousZoomLevels() {
        let levels = zoomLevels(in: keys()).sorted()
        #expect(levels.first == OfflineTileDownloader.minZoom)
        if let firstLevel = levels.first, let lastLevel = levels.last {
            #expect(levels == Array(firstLevel...lastLevel))
        }
    }

    @Test("the requested depth is honoured, up to the provider's own maximum")
    func depthClamping() {
        #expect(zoomLevels(in: keys(maxZoom: 13)).max() == 13)
        // Deeper than the provider actually serves: clamped to what exists.
        #expect(zoomLevels(in: keys(maxZoom: 22, providerMaxZoom: 14)).max() == 14)
        // Shallower than the overview zoom: the overview is still saved.
        #expect(zoomLevels(in: keys(maxZoom: 2)) == [OfflineTileDownloader.minZoom])
    }

    /// Deeper zooms cost 4× per level, so the budget is what stops a whole
    /// trail's worth of z19 tiles from being attempted.
    @Test("a normal hike stays inside the tile budget")
    func normalRouteFitsBudget() {
        let deep = keys(maxZoom: 19)
        #expect(deep.count <= OfflineTileDownloader.tileBudget)
        #expect(deep.count > keys(maxZoom: 12).count, "deeper zooms should add tiles")
    }

    /// The budget is a soft cap on what a download will fetch (4,000 tiles),
    /// and the UI shows the number as a fait accompli ("Saving N tiles…") with
    /// no way to say no — so it has to bind at the overview zoom as well as
    /// between zoom levels. This route (a long point-to-point across Europe,
    /// the kind of GPX a user might import from a road trip or a flight) is
    /// not a hike, but it is a file the importer accepts.
    @Test("the tile budget holds even for a route too big for the overview zoom")
    func hugeRouteRespectsBudget() {
        let sprawling = [
            CLLocationCoordinate2D(latitude: 40.0, longitude: 0.0),
            CLLocationCoordinate2D(latitude: 55.0, longitude: 40.0),
        ]
        let keys = OfflineTileDownloader.tileKeys(
            for: sprawling,
            providerID: "osm",
            providerMaxZoom: 19,
            maxZoom: 19
        )
        #expect(keys.count <= OfflineTileDownloader.tileBudget)
    }

    /// Read as a plain `min`/`max` interval, a route across the antimeridian
    /// has a bounding box spanning the whole world — the enumeration would
    /// walk the globe at the overview zoom and have no budget left for the
    /// zooms that make the trail usable offline. `TileBoundingBox` takes the
    /// shorter of the two arcs instead, and the columns it hands back run
    /// through `SlippyTileMath.wrap`.
    @Test("a route across the antimeridian saves its surroundings, not a band around the world")
    func antimeridianRoute() {
        let acrossTheLine = Fixture.antimeridianRoute
        let keys = OfflineTileDownloader.tileKeys(
            for: acrossTheLine,
            providerID: "osm",
            providerMaxZoom: 19,
            maxZoom: 16
        )
        let levels = zoomLevels(in: keys)
        #expect(keys.count < 500, "a ~10 km trail shouldn't enumerate a world-wide strip")
        #expect(levels.contains(16), "the trail is unusable offline without its close-in zooms")
    }

    /// Picking the short way round the globe is only half of it — the arc has
    /// to be the one the trail is actually on. Covering 359.9° of empty ocean
    /// and 0.1° of nothing would satisfy a tile count just as well.
    @Test("an antimeridian route is covered on both sides of the line")
    func antimeridianCoversBothSides() {
        let acrossTheLine = Fixture.antimeridianRoute
        let keys = Set(OfflineTileDownloader.tileKeys(
            for: acrossTheLine, providerID: "osm", providerMaxZoom: 19, maxZoom: 16
        ))
        for z in zoomLevels(in: Array(keys)) {
            for coordinate in acrossTheLine {
                let x = SlippyTileMath.tileX(coordinate.longitude, z: z)
                let y = SlippyTileMath.tileY(coordinate.latitude, z: z)
                #expect(keys.contains("osm/\(z)/\(x)/\(y)"), "zoom \(z) misses \(coordinate.longitude)")
            }
        }
    }

    /// Making the budget bind on the shallowest level too can't mean returning
    /// nothing: `start()` reports an empty enumeration as "Nothing to save.",
    /// which for a continental route is both wrong and unactionable. A coarser
    /// overview is the honest answer.
    @Test("a route too big for the overview zoom falls back to a shallower one")
    func hugeRouteFallsBackToAShallowerOverview() {
        let sprawling = [
            CLLocationCoordinate2D(latitude: 40.0, longitude: 0.0),
            CLLocationCoordinate2D(latitude: 55.0, longitude: 40.0),
        ]
        let keys = OfflineTileDownloader.tileKeys(
            for: sprawling, providerID: "osm", providerMaxZoom: 19, maxZoom: 19
        )
        #expect(!keys.isEmpty, "a route this size still has an overview worth saving")

        let levels = zoomLevels(in: keys).sorted()
        if let firstLevel = levels.first, let lastLevel = levels.last {
            #expect(lastLevel < OfflineTileDownloader.minZoom, "the usual overview zoom didn't fit")
            #expect(levels == Array(firstLevel...lastLevel), "and the levels it did take are contiguous")
        }
    }
}
