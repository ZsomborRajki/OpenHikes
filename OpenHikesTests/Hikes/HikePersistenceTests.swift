//
//  HikePersistenceTests.swift
//  OpenHikesTests
//
//  Every other suite builds its hikes in an in-memory store, which is the
//  right trade for testing behaviour — but it means the one thing that can
//  lose a user's data has to be exercised: opening a store that is already on
//  disk. Version-to-version coverage lives in `SchemaMigrationTests`; this
//  suite owns ordinary round trips and deletion durability.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@Suite("Hike persistence")
struct HikePersistenceTests {
    /// A store file of this test's own, deleted with the sandbox directory.
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hikestore-\(UUID().uuidString)", isDirectory: true)

    private var storeURL: URL {
        directory.appendingPathComponent("OpenHikes.store")
    }

    /// The sidecar's own file. Separate from ``storeURL`` because the two are
    /// separate stores — see ``HikeLocalState``.
    private var localStoreURL: URL {
        directory.appendingPathComponent("OpenHikesLocal.store")
    }

    private func makeDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A container over this test's own files. Deliberately *not*
    /// `isStoredInMemoryOnly` — the point is the disk.
    private func openContainer() throws -> ModelContainer {
        try ModelContainer.openHikes(url: storeURL, localURL: localStoreURL)
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
                autoFollowEnabled: false,
                trackDescription: "A ridge",
                author: "Someone",
                keywords: "ridge, loop"
            )
            hike.customName = "My Ridge"
            context.insert(hike)
            // After the insert, and only then: the tile columns live in the
            // sidecar store, and the passthroughs on ``Hike`` need a context
            // to reach it. A value that was never inserted has nowhere to put
            // them, which is why they are no longer initialiser arguments.
            hike.offlineDownloads = [
                OfflineDownloadRecord(providerID: "osm", scale: 2, maxZoom: 14, savedTileKeys: ["osm/14/1/1@2.0"])
            ]
            hike.autoSavedTileKeys = ["osm/16/9/9@2.0"]
            hike.autoSaveTilesEnabled = false
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
