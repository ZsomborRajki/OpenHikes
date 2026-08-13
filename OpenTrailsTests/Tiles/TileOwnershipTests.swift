//
//  TileOwnershipTests.swift
//  OpenTrailsTests
//
//  Cache keys are purely geographic — two hikes in the same valley claim
//  literally the same tiles, and at the overview zoom every hike in the same
//  country does. So "delete this hike" can't mean "delete this hike's
//  tiles": it has to mean "delete the tiles nothing else still needs".
//
//  Getting this wrong is invisible until someone is out of signal: the
//  surviving hike still lists the tiles in its manifest, still reports them
//  as stored, and simply has no map where it used to.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import OpenTrails

@Suite("Tile ownership")
struct TileOwnershipTests {
    private let context: ModelContext

    init() throws {
        context = try Fixture.modelContext()
    }

    /// A hike some distance from the ridge fixture — far enough that even the
    /// overview zoom's tiles differ.
    private var alpineRoute: [RouteCoordinate] {
        (0..<5).map { RouteCoordinate(latitude: 47.63 + Double($0) * 0.002, longitude: 12.86, elevation: 600) }
    }

    private func download(_ hike: Hike, maxZoom: Int = 14) {
        hike.offlineDownloads.append(
            OfflineDownloadRecord(providerID: TileProvider.openStreetMap.id, scale: 2, maxZoom: maxZoom)
        )
    }

    @Test("a hike that never saved anything claims nothing")
    func nothingStored() async {
        let hike = Fixture.hike(in: context)
        #expect(!hike.hasStoredTiles)
        let ownership = TileOwnership(hike)
        #expect(!ownership.hasStoredTiles)
        #expect(await offMain { ownership.tileKeys() }.isEmpty)
    }

    /// The claim is recomputed from the route the same way the download
    /// enumerated it — that's what makes the manifest a few numbers instead
    /// of a list of thousands of keys.
    @Test("a bulk download's claim is recomputed from the route")
    func bulkDownloadClaim() async {
        let hike = Fixture.hike(in: context)
        download(hike)
        let ownership = TileOwnership(hike)
        #expect(ownership.hasStoredTiles)

        let claimed = await offMain { ownership.tileKeys() }
        let expected = Set(OfflineTileDownloader.tileKeys(
            for: Fixture.coordinates(Fixture.ridgeRoute),
            providerID: TileProvider.openStreetMap.id,
            providerMaxZoom: TileProvider.openStreetMap.maximumZ,
            maxZoom: 14,
            scale: 2
        ))
        #expect(claimed == expected)
    }

    /// Auto-saved tiles can't be recomputed — organic coverage isn't a
    /// bounding box — so they're recorded exactly and simply added in.
    @Test("auto-saved keys are claimed alongside the recomputed ones")
    func autoSavedClaim() async {
        let hike = Fixture.hike(in: context)
        download(hike)
        hike.autoSavedTileKeys = ["osm/18/1/1@2.0", "osm/18/1/2@2.0"]
        let ownership = TileOwnership(hike)

        let claimed = await offMain { ownership.tileKeys() }
        #expect(claimed.isSuperset(of: ["osm/18/1/1@2.0", "osm/18/1/2@2.0"]))
        #expect(claimed.count > 2)
    }

    /// The case the whole type exists for.
    @Test("tiles two hikes share are not freed when one is deleted")
    func sharedTilesSurvive() async {
        let doomed = Fixture.hike(title: "Doomed", in: context)
        let survivor = Fixture.hike(title: "Survivor", in: context)
        download(doomed)
        download(survivor)

        let deletionPlan = StoredTileDeletionPlan(removing: doomed, among: [doomed, survivor])
        let exclusive = await offMain { deletionPlan.exclusiveTileKeys() }
        #expect(exclusive.isEmpty, "two hikes on the same route claim the same tiles")
    }

    /// …and the converse: a hike elsewhere must actually reclaim its space,
    /// or "Delete" quietly frees nothing.
    @Test("a hike somewhere else reclaims all of its own tiles")
    func unsharedTilesAreFreed() async {
        let doomed = Fixture.hike(title: "Doomed", in: context)
        let elsewhere = Fixture.hike(title: "Elsewhere", route: alpineRoute, in: context)
        download(doomed)
        download(elsewhere)

        let doomedOwnership = TileOwnership(doomed)
        let deletionPlan = StoredTileDeletionPlan(removing: doomed, among: [doomed, elsewhere])
        let claimed = await offMain { doomedOwnership.tileKeys() }
        let exclusive = await offMain { deletionPlan.exclusiveTileKeys() }
        #expect(exclusive == claimed)
    }

    /// Partial overlap is the normal case: two trails in the same region
    /// share the overview tiles and nothing else.
    @Test("only the genuinely shared tiles are held back")
    func partialOverlap() async {
        let doomed = Fixture.hike(title: "Doomed", in: context)
        let neighbour = Fixture.hike(
            title: "Neighbour",
            // A few hundred metres north of the ridge fixture: different
            // close-in tiles, same overview tile.
            route: Fixture.ridgeRoute.map {
                RouteCoordinate(latitude: $0.latitude + 0.02, longitude: $0.longitude, elevation: $0.elevation)
            },
            in: context
        )
        download(doomed, maxZoom: 16)
        download(neighbour, maxZoom: 16)

        let doomedOwnership = TileOwnership(doomed)
        let neighbourOwnership = TileOwnership(neighbour)
        let claimed = await offMain { doomedOwnership.tileKeys() }
        let exclusive = await offMain { doomedOwnership.exclusiveTileKeys(against: [neighbourOwnership]) }

        #expect(!exclusive.isEmpty, "the close-in tiles are this hike's alone")
        #expect(exclusive.count < claimed.count, "the overview tiles are shared")
        let shared = await offMain { neighbourOwnership.tileKeys() }
        #expect(exclusive.isDisjoint(with: shared))
    }

    /// Hikes that never saved anything are skipped by the delete path
    /// (`hasStoredTiles`), and must not affect the answer either way.
    @Test("hikes with no stored tiles don't hold anything back")
    func emptySurvivorsDontBlock() async {
        let doomed = Fixture.hike(title: "Doomed", in: context)
        download(doomed)
        let bystander = Fixture.hike(title: "Bystander", in: context)

        let doomedOwnership = TileOwnership(doomed)
        let bystanderOwnership = TileOwnership(bystander)
        let claimed = await offMain { doomedOwnership.tileKeys() }
        let exclusive = await offMain { doomedOwnership.exclusiveTileKeys(against: [bystanderOwnership]) }
        #expect(exclusive == claimed)
    }

    /// A snapshot is taken on the main actor and then used off it — it has to
    /// keep answering from its own copy, not from a live model that may have
    /// changed (or been deleted) since.
    @Test("a snapshot answers from the state it captured")
    func snapshotIsIndependent() async {
        let hike = Fixture.hike(in: context)
        hike.autoSavedTileKeys = ["osm/18/1/1@2.0"]
        let ownership = TileOwnership(hike)

        hike.autoSavedTileKeys = []
        hike.route = []

        let claimed = await offMain { ownership.tileKeys() }
        #expect(claimed == ["osm/18/1/1@2.0"])
    }
}
