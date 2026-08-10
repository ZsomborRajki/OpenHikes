//
//  OfflineTileDownloaderTests.swift
//  OpenTrailsTests
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
import Testing
@testable import OpenTrails

@Suite("Offline tile enumeration")
struct OfflineTileEnumerationTests {
    private let route = Fixture.coordinates(Fixture.ridgeRoute)
    private let scale: CGFloat = 2

    private func keys(maxZoom: Int = 14, providerMaxZoom: Int = 19) -> [String] {
        OfflineTileDownloader.tileKeys(
            for: route,
            providerID: TileProvider.openStreetMap.id,
            providerMaxZoom: providerMaxZoom,
            maxZoom: maxZoom,
            scale: scale
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
        #expect(keys() == keys())
        #expect(Set(keys()).count == keys().count, "a tile should not be enumerated twice")
    }

    /// The renderer looks tiles up as `providerID/z/x/y@scale`. The
    /// downloader builds the same string from a different code path; if the
    /// two ever drift, every pre-downloaded tile becomes invisible to the map
    /// and gets fetched again.
    @Test("download keys are exactly the keys the renderer asks for")
    func keyFormatMatchesRenderer() {
        let path = MKTileOverlayPath(x: 8_723, y: 5_685, z: 14, contentScaleFactor: scale)
        let rendererKey = "\(TileProvider.openStreetMap.id)/\(path.cacheKey)"
        let downloaderKey = OfflineTileDownloader.Tile(z: path.z, x: path.x, y: path.y)
            .cacheKey(providerID: TileProvider.openStreetMap.id, scale: path.contentScaleFactor)
        #expect(rendererKey == downloaderKey)
        #expect(downloaderKey == "osm/14/8723/5685@2.0")
    }

    /// A different display scale is a different tile image, so the keys must
    /// not collide — a hike downloaded on a 2× device shouldn't report its
    /// tiles as present on a 3× one.
    @Test("scale is part of the identity of a tile")
    func scaleNamespacesKeys() {
        let at2x = OfflineTileDownloader.tileKeys(for: route, providerID: "osm", providerMaxZoom: 19, maxZoom: 12, scale: 2)
        let at3x = OfflineTileDownloader.tileKeys(for: route, providerID: "osm", providerMaxZoom: 19, maxZoom: 12, scale: 3)
        #expect(at2x.count == at3x.count)
        #expect(Set(at2x).isDisjoint(with: Set(at3x)))
    }

    @Test("provider is part of the identity of a tile")
    func providerNamespacesKeys() {
        let osm = OfflineTileDownloader.tileKeys(for: route, providerID: "osm", providerMaxZoom: 19, maxZoom: 12, scale: 2)
        let other = OfflineTileDownloader.tileKeys(for: route, providerID: "stadia_outdoors", providerMaxZoom: 20, maxZoom: 12, scale: 2)
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
                #expect(keys.contains("osm/\(z)/\(x)/\(y)@2.0"), "no tile covers the route at zoom \(z)")
            }
        }
    }

    /// Zoom levels run from the overview zoom up, without gaps — a missing
    /// level in the middle would be a band of blur at exactly that zoom.
    @Test("zoom levels are contiguous from the overview zoom upward")
    func contiguousZoomLevels() {
        let levels = zoomLevels(in: keys()).sorted()
        #expect(levels.first == OfflineTileDownloader.minZoom)
        #expect(levels == Array(levels.first!...levels.last!))
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

    /// The budget is documented as a cap on what a download will fetch
    /// ("capped at 4,000 tiles"), and the UI shows the number as a fait
    /// accompli ("Saving N tiles…") with no way to say no.
    ///
    /// The enumeration only applies the budget *between* zoom levels, and
    /// takes the shallowest level unconditionally — so a route whose overview
    /// zoom alone exceeds the budget blows straight through it. This route
    /// (a long point-to-point across central Europe, the kind of GPX a user
    /// might import from a road trip or a flight) is not a hike, but it is a
    /// file the importer accepts.
    @Test("the tile budget holds even for a route too big for the overview zoom")
    func hugeRouteRespectsBudget() {
        let sprawling = [
            CLLocationCoordinate2D(latitude: 40.0, longitude: 0.0),
            CLLocationCoordinate2D(latitude: 55.0, longitude: 40.0)
        ]
        let keys = OfflineTileDownloader.tileKeys(
            for: sprawling,
            providerID: "osm",
            providerMaxZoom: 19,
            maxZoom: 19,
            scale: 2
        )
        #expect(keys.count <= OfflineTileDownloader.tileBudget)
    }

    /// A route that crosses the antimeridian has a bounding box that spans
    /// the whole world once longitude is treated as a plain interval — so the
    /// enumeration walks the entire globe at the overview zoom and has no
    /// budget left for the zooms that would actually make the trail usable
    /// offline. Tile columns wrap (`SlippyTileMath.wrap` exists for exactly
    /// this reason); the bounding box doesn't.
    @Test("a route across the antimeridian saves its surroundings, not a band around the world")
    func antimeridianRoute() {
        let acrossTheLine = [
            CLLocationCoordinate2D(latitude: -17.70, longitude: 179.95),
            CLLocationCoordinate2D(latitude: -17.71, longitude: -179.95)
        ]
        let keys = OfflineTileDownloader.tileKeys(
            for: acrossTheLine,
            providerID: "osm",
            providerMaxZoom: 19,
            maxZoom: 16,
            scale: 2
        )
        let levels = zoomLevels(in: keys)
        #expect(keys.count < 500, "a ~10 km trail shouldn't enumerate a world-wide strip")
        #expect(levels.contains(16), "the trail is unusable offline without its close-in zooms")
    }
}

@MainActor
@Suite("Offline download state")
struct OfflineDownloadStateTests {
    /// A source that can't reach anything: enough to drive the state machine
    /// without depending on a tile server (or on being online at all).
    private let unreachable = ActiveTileSource(
        providerID: "test_unreachable",
        urlTemplate: "http://127.0.0.1:9/{z}/{x}/{y}.png",
        maximumZ: 10
    )

    @Test("a route with nothing to draw is refused with a reason")
    func refusesEmptyRoute() {
        let downloader = OfflineTileDownloader()
        downloader.start(route: [], source: unreachable, scale: 2)
        #expect(downloader.isFailed)
        #expect(downloader.phase == .failed("No route to save."))

        downloader.start(
            route: [CLLocationCoordinate2D(latitude: 47.63, longitude: 12.86)],
            source: unreachable,
            scale: 2
        )
        #expect(downloader.isFailed)
    }

    @Test("progress is zero until there's something to count")
    func progressStartsEmpty() {
        let downloader = OfflineTileDownloader()
        #expect(downloader.phase == .idle)
        #expect(downloader.progress == 0)
        #expect(downloader.total == 0)
        #expect(!downloader.isFailed)
    }

    @Test("a failed download can be reset back to idle")
    func resetAfterFailure() {
        let downloader = OfflineTileDownloader()
        downloader.start(route: [], source: unreachable, scale: 2)
        #expect(downloader.isFailed)
        downloader.reset()
        #expect(downloader.phase == .idle)
        #expect(downloader.total == 0)
    }

    /// Starting counts the work up front, which is what the "Saving N tiles…"
    /// note reports.
    @Test("starting a download counts the tiles it's going to fetch", .enabled(if: TileCache.shared.isOnline))
    func startCountsTiles() {
        let downloader = OfflineTileDownloader()
        downloader.start(route: Fixture.coordinates(Fixture.ridgeRoute), source: unreachable, scale: 2)
        #expect(downloader.phase == .downloading)
        #expect(downloader.total > 0)
        downloader.cancel()
    }

    /// Cancelling has to leave the downloader genuinely idle — including
    /// after the abandoned run's in-flight fetches finish, which is the race
    /// the generation counter exists to close. A stale run reporting
    /// "finished" over a fresh one is the visible symptom.
    @Test("a cancelled download stays cancelled while its tail unwinds", .enabled(if: TileCache.shared.isOnline))
    func cancelIsFinal() async throws {
        let downloader = OfflineTileDownloader()
        downloader.start(route: Fixture.coordinates(Fixture.ridgeRoute), source: unreachable, scale: 2)
        #expect(downloader.phase == .downloading)

        downloader.cancel()
        #expect(downloader.phase == .idle)
        #expect(downloader.completed == 0)
        #expect(downloader.total == 0)

        // Long enough for the abandoned children to fail and unwind.
        try await Task.sleep(for: .seconds(2))
        #expect(downloader.phase == .idle)
        #expect(downloader.total == 0)
    }

    /// Cancel-then-restart is one tap away in the UI (the same button), so the
    /// second download's state must survive the first one's tail.
    @Test("restarting after a cancel isn't clobbered by the abandoned run", .enabled(if: TileCache.shared.isOnline))
    func restartAfterCancel() async throws {
        let downloader = OfflineTileDownloader()
        let route = Fixture.coordinates(Fixture.ridgeRoute)
        downloader.start(route: route, source: unreachable, scale: 2)
        downloader.cancel()
        downloader.start(route: route, source: unreachable, scale: 2)
        #expect(downloader.phase == .downloading)

        try await Task.sleep(for: .seconds(1))
        // Either still running or finished on its own terms — but never
        // knocked back to idle by the run that was cancelled.
        #expect(downloader.phase != .idle)
        downloader.cancel()
    }
}
