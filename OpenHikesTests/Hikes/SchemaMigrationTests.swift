//
//  SchemaMigrationTests.swift
//  OpenHikesTests
//
//  A previous-version store pair opened through the production migration
//  plan. The assertion spans both configurations because preserving either
//  row without their value-based join still loses the device's tile claims.
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

    private func makeDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeVersionOne(hikeID: UUID, date: Date) throws {
        let container = try ModelContainer.openHikes(
            schemaVersion: OpenHikesSchemaV1.self,
            url: hikesURL,
            localURL: localURL
        )
        let context = ModelContext(container)
        let hike = OpenHikesSchemaV1.Hike(
            id: hikeID,
            title: "Version one ridge",
            distanceMeters: 4200,
            date: date,
            route: Fixture.ridgeRoute
        )
        let localState = OpenHikesSchemaV1.HikeLocalState(hikeID: hikeID)
        localState.autoSavedTileKeys = ["osm/16/9/9@2.0"]
        localState.autoSaveTilesEnabled = false
        localState.offlineDownloads = [
            OfflineDownloadRecord(
                providerID: "osm",
                scale: 2,
                maxZoom: 14,
                savedTileKeys: ["osm/14/1/1@2.0"]
            ),
        ]
        context.insert(hike)
        context.insert(localState)
        try context.save()
    }

    @Test("version one migrates both stores and preserves their hikeID join")
    func previousVersionMigratesAsAStorePair() throws {
        try makeDirectory()
        defer { removeDirectory() }

        let hikeID = UUID()
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        try writeVersionOne(hikeID: hikeID, date: date)

        var usedFallback = false
        let load = try OpenHikesModel.loadContainer(
            persistent: { try ModelContainer.openHikes(url: hikesURL, localURL: localURL) },
            fallback: {
                usedFallback = true
                return try ModelContainer.openHikes(isStoredInMemoryOnly: true)
            }
        )
        let context = ModelContext(load.container)
        let hike = try #require(
            try context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })).first
        )
        let localState = try #require(
            try context.fetch(
                FetchDescriptor<HikeLocalState>(predicate: #Predicate { $0.hikeID == hikeID })
            ).first
        )

        #expect(!usedFallback)
        #expect(load.startupIssue == nil)
        let migrationPlan = try #require(load.container.migrationPlan)
        #expect(ObjectIdentifier(migrationPlan) == ObjectIdentifier(OpenHikesMigrationPlan.self))
        #expect(load.container.schema.version == OpenHikesSchemaV2.versionIdentifier)
        #expect(hike.title == "Version one ridge")
        #expect(hike.distanceMeters == 4200)
        #expect(hike.date == date)
        #expect(hike.route == Fixture.ridgeRoute)
        #expect(localState.autoSavedTileKeys == ["osm/16/9/9@2.0"])
        #expect(localState.offlineDownloads.first?.savedTileKeys == ["osm/14/1/1@2.0"])
        #expect(!localState.autoSaveTilesEnabled)
        #expect(try hike.resolveLocalState()?.hikeID == hikeID)
    }
}
