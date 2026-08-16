//
//  OpenHikesModelTests.swift
//  OpenHikesTests
//

@testable import OpenHikes
import SwiftData
import Testing

@Suite("OpenHikes model")
struct OpenHikesModelTests {
    private enum PersistentStoreFailure: Error {
        case unavailable
    }

    @Test("a persistent-store failure falls back to temporary storage")
    func persistentStoreFailureFallsBack() throws {
        let temporary = try Fixture.modelContainer()
        var fallbackWasUsed = false

        let load = try OpenHikesModel.loadContainer(
            persistent: {
                throw PersistentStoreFailure.unavailable
            },
            fallback: {
                fallbackWasUsed = true
                return temporary
            }
        )

        #expect(load.container === temporary)
        #expect(fallbackWasUsed)
        #expect(load.startupIssue != nil)
    }

    @Test("a healthy persistent store does not build a fallback")
    func persistentStoreWins() throws {
        let persistent = try Fixture.modelContainer()
        var fallbackWasUsed = false

        let load = try OpenHikesModel.loadContainer(
            persistent: { persistent },
            fallback: {
                fallbackWasUsed = true
                return try Fixture.modelContainer()
            }
        )

        #expect(load.container === persistent)
        #expect(!fallbackWasUsed)
        #expect(load.startupIssue == nil)
    }
}

/// The two sweeps `OpenHikesView.onAppear` runs at launch, and the one rule
/// they share: **a fetch that fails sweeps nothing.**
///
/// Both hand a claim set to code whose entire job is deleting what is not in
/// it — `TileCache.trimCache(claimedBy:)` and
/// `HikePhotoStore.reclaimOrphans(claimedBy:)` — and neither can tell an
/// honestly empty set from one produced by a failure. An empty set therefore
/// authorizes deleting every durably saved tile and every photo in the app,
/// which is why the claim assembly throws instead.
@Suite("Launch sweep claims")
struct LaunchSweepClaimTests {
    private enum FetchFailure: Error { case unavailable }

    @Test("a failed hike fetch yields no tile claim set at all")
    func failedTileFetchIsNotAnEmptySet() {
        #expect(throws: FetchFailure.self) {
            // [] would authorize deleting every durably saved tile.
            try OpenHikesModel.tileClaims { throw FetchFailure.unavailable }
        }
    }

    @Test("a failed hike fetch yields no photo claim set at all")
    func failedPhotoFetchIsNotAnEmptySet() {
        #expect(throws: FetchFailure.self) {
            // [] would authorize deleting every photo in the app.
            try OpenHikesModel.photoClaims { throw FetchFailure.unavailable }
        }
    }

    /// The other side of it: a store that genuinely holds nothing still
    /// answers, so a first launch is not mistaken for a broken one.
    @Test("an empty store still produces claim sets, just empty ones")
    func emptyStoreStillSweeps() throws {
        let context = try Fixture.modelContext()

        let claims = try OpenHikesModel.tileClaims {
            try context.fetch(FetchDescriptor<Hike>())
        }
        let claimed = try OpenHikesModel.photoClaims {
            try context.fetch(FetchDescriptor<Hike>())
        }

        #expect(claims.isEmpty)
        #expect(claimed.isEmpty)
    }

    /// Only hikes that actually hold tiles become claims — a hike with none
    /// has nothing to protect, and enumerating its route grid would be work
    /// for an empty answer.
    @Test("only hikes holding tiles are claimed, and every photo file is")
    func claimsCoverStoredTilesAndBothPhotoFiles() async throws {
        let context = try Fixture.modelContext()
        let withTiles = Fixture.hike(in: context, title: "Saved") { hike in
            hike.autoSavedTileKeys = ["osm/14/8723/5685@2.0"]
        }
        _ = Fixture.hike(in: context, title: "Nothing saved")
        let photo = HikePhoto()
        withTiles.photos.append(photo)

        let claims = try OpenHikesModel.tileClaims {
            try context.fetch(FetchDescriptor<Hike>())
        }
        let claimed = try OpenHikesModel.photoClaims {
            try context.fetch(FetchDescriptor<Hike>())
        }

        #expect(claims.count == 1)
        let claim = try #require(claims.first)
        let keys = try await offMain { try claim.tileKeys() }
        #expect(keys.contains("osm/14/8723/5685@2.0"))
        // Both files, not just the picture: a thumbnail left unclaimed is
        // deleted by the sweep and silently re-rendered on next view.
        #expect(claimed.contains(photo.fileName))
        #expect(claimed.contains(photo.thumbnailFileName))
    }
}
