//
//  HikePersistenceTests.swift
//  OpenHikesTests
//
//  Every other suite builds its hikes in an in-memory store, which is the
//  right trade for testing behaviour — but it means the one thing that can
//  lose a user's data has never been exercised: opening a store that is
//  already on disk.
//
//  `Hike`'s non-optional columns added after the first release carry inline
//  declaration defaults (`= []`, `= false`, `= true`, `= [:]`) specifically
//  so SwiftData's lightweight migration can backfill them on existing rows;
//  the comment there records that without them the app fails to open with
//  "missing attribute values on mandatory destination attribute" for anyone
//  who already has hikes saved. That is a claim about a real store and an
//  older schema, so it is checked here against exactly that: a store written
//  by the previous shape of the model, then opened by the current one.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

/// `Hike` as it was before auto-save, auto-follow, and recording drafts
/// existed. The same entity name with those later attributes absent makes a
/// store written by it a genuine "existing install" for the current model.
enum HikeSchemaBeforeAutoSave: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Hike.self] }

    @Model
    final class Hike {
        var id = UUID()
        var title: String = ""
        var distanceMeters: Double = 0
        var date = Date.now
        var tintHex: String = "#34C759"
        var routeWidth: Double = 3
        var symbol: String = "figure.hiking"
        var route: [RouteCoordinate] = []
        var offlineDownloads: [OfflineDownloadRecord] = []
        var trackDescription: String?
        var author: String?
        var keywords: String?

        init(
            title: String,
            distanceMeters: Double,
            id: UUID = UUID(),
            date: Date = .now,
            route: [RouteCoordinate] = []
        ) {
            self.id = id
            self.title = title
            self.distanceMeters = distanceMeters
            self.date = date
            self.route = route
        }
    }
}

@Suite("Hike persistence")
struct HikePersistenceTests {
    /// A store file of this test's own, deleted with the sandbox directory.
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hikestore-\(UUID().uuidString)", isDirectory: true)

    private var storeURL: URL {
        directory.appendingPathComponent("OpenHikes.store")
    }

    private func makeDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A container over this test's own file. Deliberately *not*
    /// `isStoredInMemoryOnly` — the point is the disk.
    private func openContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Hike.self,
            configurations: .openHikes(url: storeURL)
        )
    }

    private func openLegacyContainer() throws -> ModelContainer {
        try ModelContainer(
            for: HikeSchemaBeforeAutoSave.Hike.self,
            configurations: .openHikes(url: storeURL)
        )
    }

    // MARK: Round trip

    /// The baseline: everything a hike carries survives being written, the
    /// container being torn down, and the file being opened again.
    @Test("a hike written to disk comes back whole")
    func hikeSurvivesAReopen() throws {
        try makeDirectory()
        defer { removeDirectory() }

        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        do {
            let container = try openContainer()
            let context = ModelContext(container)
            let hike = Hike(
                title: "Ridge Loop",
                distanceMeters: 1234.5,
                id: id,
                date: date,
                tintHex: "#FF9500FF",
                routeWidth: 7,
                routeLinePatternID: RouteLinePattern.dotted.rawValue,
                symbol: "mountain.2",
                route: Fixture.ridgeRoute,
                rawRoute: Array(Fixture.ridgeRoute.reversed()),
                isRecording: true,
                offlineDownloads: [
                    OfflineDownloadRecord(providerID: "osm", scale: 2, maxZoom: 14, savedTileKeys: ["osm/14/1/1@2.0"])
                ],
                autoSavedTileKeys: ["osm/16/9/9@2.0"],
                autoSaveTilesEnabled: false,
                autoFollowEnabled: false,
                trackDescription: "A ridge",
                author: "Someone",
                keywords: "ridge, loop"
            )
            hike.customName = "My Ridge"
            context.insert(hike)
            try context.save()
        }

        let container = try openContainer()
        let context = ModelContext(container)
        let reopened = try #require(
            try context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
        )

        #expect(reopened.title == "Ridge Loop")
        #expect(reopened.customName == "My Ridge")
        #expect(reopened.displayTitle == "My Ridge")
        #expect(reopened.distanceMeters == 1234.5)
        #expect(reopened.date == date)
        #expect(reopened.tintHex == "#FF9500FF")
        #expect(reopened.routeWidth == 7)
        #expect(reopened.routeLinePattern == .dotted)
        #expect(reopened.symbol == "mountain.2")
        #expect(reopened.rawRoute == Array(Fixture.ridgeRoute.reversed()))
        #expect(reopened.isRecording)
        #expect(reopened.trackDescription == "A ridge")
        #expect(reopened.author == "Someone")
        #expect(reopened.keywords == "ridge, loop")

        // The two manifests are what free a hike's tiles; losing either strands
        // durable files nothing will ever reclaim.
        #expect(reopened.autoSavedTileKeys == ["osm/16/9/9@2.0"])
        #expect(reopened.offlineDownloads.count == 1)
        #expect(reopened.offlineDownloads.first?.savedTileKeys == ["osm/14/1/1@2.0"])

        // And the per-hike toggles, which are the user's and not the app's.
        #expect(reopened.autoSaveTilesEnabled == false)
        #expect(reopened.autoFollowEnabled == false)
    }

    /// The route is stored inline as `[RouteCoordinate]`, optionals and all —
    /// a point with no elevation and no timestamp is ordinary in a GPX file.
    @Test("the stored route survives point for point")
    func routeSurvivesAReopen() throws {
        try makeDirectory()
        defer { removeDirectory() }

        let id = UUID()
        let route = Fixture.ridgeRoute + [RouteCoordinate(latitude: 37.34, longitude: -122.03)]
        do {
            let container = try openContainer()
            let context = ModelContext(container)
            context.insert(Hike(title: "Ridge", distanceMeters: 1, id: id, route: route))
            try context.save()
        }

        let container = try openContainer()
        let context = ModelContext(container)
        let reopened = try #require(
            try context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
        )

        #expect(reopened.route == route, "including the elevations, the timestamps, and their absence")
    }

    @Test("route points written before motion metadata still decode")
    func legacyRouteCoordinateDecodesWithoutMotion() throws {
        let data = Data(
            #"{"latitude":47.63,"longitude":12.86}"#.utf8
        )
        let point = try JSONDecoder().decode(
            RouteCoordinate.self,
            from: data
        )

        #expect(point.motion == nil)
    }

    // MARK: Migration

    /// The case `Hike`'s comment is about: a store written before the
    /// auto-save and auto-follow columns existed. Opening it with the current
    /// model must migrate rather than throw, and must leave the older hike
    /// with the defaults a new one would have.
    @Test("a store from before auto-save opens and backfills its defaults")
    func lightweightMigrationBackfillsDefaults() throws {
        try makeDirectory()
        defer { removeDirectory() }

        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let container = try openLegacyContainer()
            let context = ModelContext(container)
            let legacy = HikeSchemaBeforeAutoSave.Hike(
                title: "Imported last year",
                distanceMeters: 4200,
                id: id,
                date: date,
                route: Fixture.ridgeRoute
            )
            legacy.tintHex = "#34C759FF"
            legacy.offlineDownloads = [OfflineDownloadRecord(providerID: "osm", scale: 2, maxZoom: 12)]
            context.insert(legacy)
            try context.save()
        }

        let container = try openContainer()
        let context = ModelContext(container)
        let migrated = try #require(
            try context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
        )

        // What the migration had to invent.
        #expect(migrated.rawRoute.isEmpty, "an imported legacy hike has no recorded GPS trace")
        #expect(!migrated.isRecording, "an imported legacy hike is already finished")
        #expect(migrated.autoSavedTileKeys.isEmpty, "an old hike has auto-saved nothing yet")
        #expect(migrated.autoSaveTilesEnabled, "and gets the same default a new hike does")
        #expect(migrated.autoFollowEnabled)
        #expect(
            migrated.routeLinePattern == .default,
            "a hike saved before line patterns existed keeps the line it was drawn with"
        )

        // What it had to keep.
        #expect(migrated.title == "Imported last year")
        #expect(migrated.distanceMeters == 4200)
        #expect(migrated.date == date)
        #expect(migrated.tintHex == "#34C759FF")
        #expect(migrated.route == Fixture.ridgeRoute)
        #expect(migrated.offlineDownloads.first?.providerID == "osm")
    }

    /// And the migration is durable: the backfilled values are written back,
    /// not just materialised in memory for the session that migrated.
    @Test("backfilled defaults are still there on the next launch")
    func migratedDefaultsPersist() throws {
        try makeDirectory()
        defer { removeDirectory() }

        let id = UUID()
        do {
            let container = try openLegacyContainer()
            let context = ModelContext(container)
            context.insert(
                HikeSchemaBeforeAutoSave.Hike(title: "Old", distanceMeters: 10, id: id, route: Fixture.ridgeRoute)
            )
            try context.save()
        }
        do {
            let container = try openContainer()
            let context = ModelContext(container)
            let migrated = try #require(
                try context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
            )
            migrated.autoSavedTileKeys = ["osm/16/1/1@2.0"]
            try context.save()
        }

        let container = try openContainer()
        let context = ModelContext(container)
        let reopened = try #require(
            try context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
        )
        #expect(reopened.autoSavedTileKeys == ["osm/16/1/1@2.0"])
        #expect(reopened.autoSaveTilesEnabled)
        #expect(!reopened.isRecording)
    }

    /// Deleting is the other half of owning a file: the row has to actually go,
    /// or a "deleted" hike comes back on the next launch still claiming tiles.
    @Test("a deleted hike stays deleted")
    func deletionSurvivesAReopen() throws {
        try makeDirectory()
        defer { removeDirectory() }

        let id = UUID()
        do {
            let container = try openContainer()
            let context = ModelContext(container)
            let hike = Hike(title: "Doomed", distanceMeters: 1, id: id, route: Fixture.ridgeRoute)
            context.insert(hike)
            try context.save()
            context.delete(hike)
            try context.save()
        }

        let container = try openContainer()
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<Hike>()).isEmpty)
    }
}
