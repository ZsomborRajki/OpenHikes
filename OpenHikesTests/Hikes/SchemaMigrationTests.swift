//
//  SchemaMigrationTests.swift
//  OpenHikesTests
//
//  A previous-version store opened through the production migration plan.
//
//  This is where `Hike`'s inline declaration defaults are actually exercised.
//  Every non-optional column added since V1 carries one (`= []`, `= false`,
//  `= true`, `= [:]`) specifically so a lightweight migration can backfill it,
//  and the comments there record that without them the app fails to open for
//  anyone who already has hikes saved. That is a claim about a real store and
//  an older schema, so it is checked against exactly that: a store written by
//  ``OpenHikesSchemaV1``, then opened the way the app opens one.
//
//  The second test spans both configurations, because a migration that
//  preserves the hike row but loses its value-based join to the sidecar still
//  loses the device's tile claims.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("SwiftData schema migration")
struct SchemaMigrationTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("schema-migration-\(UUID().uuidString)", isDirectory: true)

    private var hikesURL: URL { directory.appendingPathComponent("Hikes.store") }
    private var localURL: URL { directory.appendingPathComponent("HikeLocalState.store") }

    /// `Fixture.ridgeRoute` in the shape V1 encodes. The frozen copy is a
    /// different Swift type by design — see ``OpenHikesSchemaV1``.
    private var versionOneRoute: [OpenHikesSchemaV1.RouteCoordinate] {
        Fixture.ridgeRoute.map { point in
            OpenHikesSchemaV1.RouteCoordinate(
                latitude: point.latitude,
                longitude: point.longitude,
                elevation: point.elevation,
                timestamp: point.timestamp
            )
        }
    }

    private func makeDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A store written by version one: the hike store alone, with the offline
    /// tile manifest still a column on the row. No sidecar file is created,
    /// because that version had none.
    private func writeVersionOne(hikeID: UUID, date: Date) throws {
        let container = try ModelContainer.openHikes(
            schemaVersion: OpenHikesSchemaV1.self,
            url: hikesURL,
            localURL: localURL
        )
        let context = ModelContext(container)
        let hike = OpenHikesSchemaV1.Hike(
            title: "Version one ridge",
            distanceMeters: 4200,
            id: hikeID,
            date: date,
            route: versionOneRoute
        )
        hike.tintHex = "#34C759FF"
        hike.offlineDownloads = [
            // The frozen V1 shape, written exactly as a store of that era
            // held it: `scale` was still a column and the saved key still
            // carried an `@2.0` suffix.
            OpenHikesSchemaV1.OfflineDownloadRecord(
                providerID: "osm",
                scale: 2,
                maxZoom: 14,
                savedTileKeys: ["osm/14/1/1@2.0"]
            ),
        ]
        context.insert(hike)
        try context.save()
    }

    /// Both stores the way the app opens them, through the launch path that
    /// decides whether the user gets their data or a temporary store.
    private func openThroughLaunchPath() throws -> (container: ModelContainer, usedFallback: Bool) {
        var usedFallback = false
        let load = try OpenHikesModel.loadContainer(
            persistent: { try ModelContainer.openHikes(url: hikesURL, localURL: localURL) },
            fallback: {
                usedFallback = true
                return try ModelContainer.openHikes(isStoredInMemoryOnly: true)
            }
        )
        #expect(
            !usedFallback,
            "a supported older store must migrate, not fall back: \(load.startupIssue?.underlyingDescription ?? "")"
        )
        #expect(load.startupIssue == nil)
        return (load.container, usedFallback)
    }

    private func fetchHike(_ id: UUID, in context: ModelContext) throws -> Hike? {
        try context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
    }

    @Test("a version one store opens and backfills the columns added since")
    func versionOneMigratesAndBackfillsDefaults() throws {
        try makeDirectory()
        defer { removeDirectory() }

        let hikeID = UUID()
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        try writeVersionOne(hikeID: hikeID, date: date)

        let opened = try openThroughLaunchPath()
        try #require(!opened.usedFallback)
        let context = ModelContext(opened.container)
        let migrated = try #require(try fetchHike(hikeID, in: context))

        // What the migration had to invent. Each of these is one of the inline
        // defaults `Hike` documents; dropping one fails the open instead.
        #expect(migrated.rawRoute.isEmpty, "a version one hike has no unmatched GPS trace")
        #expect(!migrated.isRecording, "a version one hike is already finished")
        #expect(migrated.autoFollowEnabled)
        #expect(migrated.customName == nil)
        #expect(migrated.surfaceMetersByCategory.isEmpty, "never analyzed, which is what opening it triggers")
        #expect(migrated.difficultyMetersByGrade.isEmpty)
        #expect(migrated.photos.isEmpty)
        #expect(
            migrated.routeLinePattern == .default,
            "a hike saved before line patterns existed keeps the line it was drawn with"
        )
        #expect(migrated.autoSavedTileKeys.isEmpty, "an old hike has auto-saved nothing yet")
        #expect(migrated.autoSaveTilesEnabled, "and gets the same default a new hike does")
        #expect(migrated.walks?.isEmpty ?? true, "a version one hike has never been walked")
        #expect(migrated.walkInProgress == nil, "and the sidecar's new column reads as no walk in progress")
        #expect(try context.fetch(FetchDescriptor<HikeWalk>()).isEmpty)

        // What it had to keep.
        #expect(migrated.title == "Version one ridge")
        #expect(migrated.distanceMeters == 4200)
        #expect(migrated.date == date)
        #expect(migrated.tintHex == "#34C759FF")
        #expect(migrated.route == Fixture.ridgeRoute)

        // And what it deliberately does not: the tile inventory moved out of
        // `Hike` and into ``HikeLocalState``'s own store when mirroring took
        // over, so a version one row's copy is dropped rather than carried
        // across. Tiles are re-fetchable by definition — this costs a
        // download, and it is the price of keeping a column that names *this*
        // device's files out of a row that syncs.
        #expect(
            migrated.offlineDownloads.isEmpty,
            "the version one tile manifest does not survive the move to the sidecar store"
        )
    }

    @Test("a migrated hike keeps its backfilled values and joins a new sidecar row")
    func migratedHikeJoinsTheSidecarAndPersists() throws {
        try makeDirectory()
        defer { removeDirectory() }

        let hikeID = UUID()
        try writeVersionOne(hikeID: hikeID, date: Date(timeIntervalSince1970: 1_700_000_000))

        // The migrating launch: claim tiles, which is the first thing to
        // create a row in the store version one did not have.
        do {
            let opened = try openThroughLaunchPath()
            try #require(!opened.usedFallback)
            let context = ModelContext(opened.container)
            let migrated = try #require(try fetchHike(hikeID, in: context))
            migrated.autoSavedTileKeys = ["osm/16/9/9@2.0"]
            migrated.autoSaveTilesEnabled = false
            try context.save()
        }

        // The next launch, which is the one that proves the backfill was
        // written back rather than materialised for the session that migrated.
        let opened = try openThroughLaunchPath()
        try #require(!opened.usedFallback)
        let context = ModelContext(opened.container)
        let reopened = try #require(try fetchHike(hikeID, in: context))

        #expect(reopened.route == Fixture.ridgeRoute)
        #expect(!reopened.isRecording)
        #expect(reopened.autoFollowEnabled)

        // The join is by value across two stores, so assert it from both ends:
        // the passthrough that twenty call sites read, and the sidecar row it
        // resolves to.
        #expect(reopened.autoSavedTileKeys == ["osm/16/9/9@2.0"])
        #expect(!reopened.autoSaveTilesEnabled)
        let sidecar = try #require(try reopened.resolveLocalState())
        #expect(sidecar.hikeID == hikeID)
        let byQuery = try context.fetch(
            FetchDescriptor<HikeLocalState>(predicate: #Predicate { $0.hikeID == hikeID })
        )
        #expect(byQuery.count == 1, "one sidecar row per hike, created by the first claim and not again")
    }
}
