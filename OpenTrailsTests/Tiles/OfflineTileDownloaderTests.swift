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
@testable import OpenTrails
import SwiftData
import Testing

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
        let first = keys()
        let second = keys()
        #expect(first == second)
        #expect(Set(keys()).count == keys().count, "a tile should not be enumerated twice")
    }

    @Test("a partial record claims only tiles verified on disk")
    func partialRecordUsesExactKeys() async {
        let exact = ["test/10/1/1@2.0", "test/10/1/2@2.0"]
        let record = OfflineDownloadRecord(
            providerID: "test",
            scale: 2,
            maxZoom: 19,
            savedTileKeys: exact
        )
        let stored = await offMain {
            OfflineTileDownloader.storedTileKeys(route: route, offlineDownloads: [record])
        }
        #expect(Set(stored) == Set(exact))
    }

    /// The renderer looks tiles up as `providerID/z/x/y@scale`. The
    /// downloader builds the same string from a different code path; if the
    /// two ever drift, every pre-downloaded tile becomes invisible to the map
    /// and gets fetched again.
    @Test("download keys are exactly the keys the renderer asks for")
    func keyFormatMatchesRenderer() {
        let path = MKTileOverlayPath(x: 8723, y: 5685, z: 14, contentScaleFactor: scale)
        let rendererKey = "\(TileProvider.openStreetMap.id)/\(path.cacheKey)"
        let downloaderKey = OfflineTileDownloader.Tile(z: path.z, x: path.x, y: path.y)
            .cacheKey(providerID: TileProvider.openStreetMap.id, scale: path.contentScaleFactor)
        #expect(rendererKey == downloaderKey)
        #expect(
            downloaderKey == TileCacheKey.namespaced(
                providerID: TileProvider.openStreetMap.id,
                z: path.z,
                x: path.x,
                y: path.y,
                scale: path.contentScaleFactor
            )
        )
        #expect(downloaderKey == "osm/14/8723/5685@2.0")
    }

    /// A different display scale is a different tile image, so the keys must
    /// not collide — a hike downloaded on a 2× device shouldn't report its
    /// tiles as present on a 3× one.
    @Test("scale is part of the identity of a tile")
    func scaleNamespacesKeys() {
        let at2x = OfflineTileDownloader.tileKeys(
            for: route, providerID: "osm", providerMaxZoom: 19, maxZoom: 12, scale: 2
        )
        let at3x = OfflineTileDownloader.tileKeys(
            for: route, providerID: "osm", providerMaxZoom: 19, maxZoom: 12, scale: 3
        )
        #expect(at2x.count == at3x.count)
        #expect(Set(at2x).isDisjoint(with: Set(at3x)))
    }

    @Test("provider is part of the identity of a tile")
    func providerNamespacesKeys() {
        let osm = OfflineTileDownloader.tileKeys(
            for: route, providerID: "osm", providerMaxZoom: 19, maxZoom: 12, scale: 2
        )
        let other = OfflineTileDownloader.tileKeys(
            for: route, providerID: "stadia_outdoors", providerMaxZoom: 20, maxZoom: 12, scale: 2
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
            CLLocationCoordinate2D(latitude: 55.0, longitude: 40.0),
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
        let acrossTheLine = Fixture.antimeridianRoute
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

    /// Picking the short way round the globe is only half of it — the arc has
    /// to be the one the trail is actually on. Covering 359.9° of empty ocean
    /// and 0.1° of nothing would satisfy a tile count just as well.
    @Test("an antimeridian route is covered on both sides of the line")
    func antimeridianCoversBothSides() {
        let acrossTheLine = Fixture.antimeridianRoute
        let keys = Set(OfflineTileDownloader.tileKeys(
            for: acrossTheLine, providerID: "osm", providerMaxZoom: 19, maxZoom: 16, scale: 2
        ))
        for z in zoomLevels(in: Array(keys)) {
            for coordinate in acrossTheLine {
                let x = SlippyTileMath.tileX(coordinate.longitude, z: z)
                let y = SlippyTileMath.tileY(coordinate.latitude, z: z)
                #expect(keys.contains("osm/\(z)/\(x)/\(y)@2.0"), "zoom \(z) misses \(coordinate.longitude)")
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
            for: sprawling, providerID: "osm", providerMaxZoom: 19, maxZoom: 19, scale: 2
        )
        #expect(!keys.isEmpty, "a route this size still has an overview worth saving")

        let levels = zoomLevels(in: keys).sorted()
        if let firstLevel = levels.first, let lastLevel = levels.last {
            #expect(lastLevel < OfflineTileDownloader.minZoom, "the usual overview zoom didn't fit")
            #expect(levels == Array(firstLevel...lastLevel), "and the levels it did take are contiguous")
        }
    }
}

@Suite("Offline download state")
struct OfflineDownloadStateTests {
    /// A source that can't reach anything: enough to drive the state machine
    /// without depending on a tile server (or on being online at all).
    private let unreachable = ActiveTileSource(
        providerID: "test_unreachable",
        urlTemplate: "http://127.0.0.1:9/{z}/{x}/{y}.png",
        maximumZ: 10
    )

    private let controlled = ActiveTileSource(
        providerID: "test_controlled",
        urlTemplate: "https://example.invalid/{z}/{x}/{y}.png",
        maximumZ: 12
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
    ///
    /// Connectivity and the fetch itself are both injected, so this says the
    /// same thing on a machine with no network as on one with — it used to be
    /// gated on `TileCache.shared.isOnline`, i.e. it silently didn't run.
    @Test("starting a download counts the tiles it's going to fetch")
    func startCountsTiles() {
        let downloader = OfflineTileDownloader(isOnline: { true }, saveTile: { _, _ in false })
        downloader.start(route: Fixture.coordinates(Fixture.ridgeRoute), source: unreachable, scale: 2)
        #expect(downloader.phase == .downloading)
        #expect(downloader.total > 0)
        downloader.cancel()
    }

    /// Cancelling has to leave the downloader genuinely idle — including
    /// after the abandoned run's in-flight fetches finish, which is the race
    /// the generation counter exists to close. A stale run reporting
    /// "finished" over a fresh one is the visible symptom.
    ///
    /// The tail is waited for rather than slept past: the saves are held open
    /// until the test lets them go, and `waitForCurrentRun()` then returns
    /// once the abandoned run has actually finished unwinding.
    @Test("a cancelled download stays cancelled while its tail unwinds")
    func cancelIsFinal() async {
        let held = HeldSaves()
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in await held.save() }
        )
        downloader.start(route: Fixture.coordinates(Fixture.ridgeRoute), source: unreachable, scale: 2)
        #expect(downloader.phase == .downloading)

        downloader.cancel()
        #expect(downloader.phase == .idle)
        #expect(downloader.completed == 0)
        #expect(downloader.total == 0)

        await held.release()
        await downloader.waitForCurrentRun()
        #expect(downloader.phase == .idle, "the abandoned run must not report over a cancellation")
        #expect(downloader.total == 0)
    }

    /// Cancel-then-restart is one tap away in the UI (the same button), so the
    /// second download's state must survive the first one's tail.
    @Test("restarting after a cancel isn't clobbered by the abandoned run")
    func restartAfterCancel() async {
        let held = HeldSaves()
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in await held.save() }
        )
        let route = Fixture.coordinates(Fixture.ridgeRoute)
        downloader.start(route: route, source: unreachable, scale: 2)
        downloader.cancel()
        downloader.start(route: route, source: unreachable, scale: 2)
        #expect(downloader.phase == .downloading)

        // Both runs' saves complete now, so the abandoned one's tail unwinds
        // alongside the live one rather than after it.
        await held.release()
        await downloader.waitForCurrentRun()

        // Finished on its own terms — but never knocked back to idle by the
        // run that was cancelled.
        #expect(downloader.phase != .idle)
        downloader.cancel()
    }

    @Test("a partial download fails and records only successful tiles")
    func partialDownloadIsNotReportedComplete() async {
        let attempts = AttemptCounter()
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in await attempts.succeedAlternating() }
        )

        downloader.start(route: Fixture.coordinates(Fixture.ridgeRoute), source: controlled, scale: 2)
        await downloader.waitForCurrentRun()

        #expect(downloader.isFailed)
        let record = downloader.completedRecord
        #expect(record?.savedTileKeys.isEmpty == false)
        #expect((record?.savedTileKeys.count ?? 0) < downloader.total)
        // The bar and the "Saved N of M" message read the same number.
        #expect(downloader.completed == record?.savedTileKeys.count)
        #expect(downloader.completed < downloader.total, "half the tiles saved is not a full bar")
    }

    /// The case that made this worth changing: every tile fails, the bar fills
    /// to 100%, and the message underneath it says "Saved 0 of N tiles."
    @Test("a download that saves nothing doesn't fill its progress bar")
    func failedDownloadReportsNoProgress() async {
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in false }
        )

        downloader.start(route: Fixture.coordinates(Fixture.ridgeRoute), source: controlled, scale: 2)
        await downloader.waitForCurrentRun()

        #expect(downloader.isFailed)
        #expect(downloader.total > 0, "precondition: it had tiles to try")
        #expect(downloader.completed == 0)
        #expect(downloader.progress == 0, "nothing saved is nothing to show")
    }

    /// And the other end: a download that really did save everything still
    /// reads as finished, so reporting successes hasn't made success
    /// unreachable.
    @Test("a complete download does fill its progress bar")
    func completeDownloadReportsFullProgress() async {
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in true }
        )

        downloader.start(route: Fixture.coordinates(Fixture.ridgeRoute), source: controlled, scale: 2)
        await downloader.waitForCurrentRun()

        #expect(downloader.completed == downloader.total)
        #expect(downloader.progress == 1)
    }

    @Test("a complete download keeps the compact deterministic record")
    func completeDownloadFinishes() async {
        let downloader = OfflineTileDownloader(
            isOnline: { true },
            saveTile: { _, _ in true }
        )

        downloader.start(route: Fixture.coordinates(Fixture.ridgeRoute), source: controlled, scale: 2)
        await downloader.waitForCurrentRun()

        #expect(downloader.phase == .finished)
        #expect(downloader.completedRecord?.savedTileKeys.isEmpty == true)
    }
}

/// Holds every stubbed save open until the test lets it go.
///
/// What a cancellation test needs is fetches that are genuinely still in
/// flight when `cancel()` lands, and then a way to know their tail has
/// finished unwinding. Sleeping supplies neither: it only makes both *likely*,
/// at the cost of the sleep on every run.
private actor HeldSaves {
    private var isReleased = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func save() async -> Bool {
        if !isReleased {
            await withCheckedContinuation { waiting.append($0) }
        }
        return true
    }

    func release() {
        isReleased = true
        let resumed = waiting
        waiting.removeAll()
        for continuation in resumed { continuation.resume() }
    }
}

private actor AttemptCounter {
    private var attempts = 0

    func succeedAlternating() -> Bool {
        attempts += 1
        return !attempts.isMultiple(of: 2)
    }
}

@Suite("Offline download manifest")
struct OfflineDownloadManifestTests {
    private let context: ModelContext

    init() throws {
        context = try Fixture.modelContext()
    }

    @Test("retries merge exact partial coverage")
    func partialRetriesMerge() {
        let hike = Fixture.hike(in: context)
        hike.mergeOfflineDownload(
            OfflineDownloadRecord(
                providerID: "test",
                scale: 2,
                maxZoom: 12,
                savedTileKeys: ["test/12/1/1@2.0"]
            )
        )
        hike.mergeOfflineDownload(
            OfflineDownloadRecord(
                providerID: "test",
                scale: 2,
                maxZoom: 12,
                savedTileKeys: ["test/12/1/2@2.0"]
            )
        )

        #expect(hike.offlineDownloads.count == 1)
        #expect(
            Set(hike.offlineDownloads[0].savedTileKeys ?? [])
                == ["test/12/1/1@2.0", "test/12/1/2@2.0"]
        )
    }

    @Test("a complete retry replaces partial coverage")
    func completeRetryReplacesPartial() {
        let hike = Fixture.hike(in: context)
        hike.mergeOfflineDownload(
            OfflineDownloadRecord(
                providerID: "test",
                scale: 2,
                maxZoom: 12,
                savedTileKeys: ["test/12/1/1@2.0"]
            )
        )
        hike.mergeOfflineDownload(
            OfflineDownloadRecord(providerID: "test", scale: 2, maxZoom: 12)
        )

        #expect(hike.offlineDownloads.count == 1)
        #expect(hike.offlineDownloads[0].savedTileKeys.isEmpty)
    }

    @Test("a record without partial keys decodes as complete coverage")
    func completeRecordDecodes() throws {
        let data = Data(#"{"providerID":"test","scale":2,"maxZoom":12,"savedTileKeys":[]}"#.utf8)
        let record = try JSONDecoder().decode(OfflineDownloadRecord.self, from: data)
        #expect(record.savedTileKeys.isEmpty)
    }
}
