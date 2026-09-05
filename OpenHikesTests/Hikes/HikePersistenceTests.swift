//
//  HikePersistenceTests.swift
//  OpenHikesTests
//
//  Every other suite builds its hikes in an in-memory store, which is the
//  right trade for testing behaviour — but it means the one thing that can
//  lose a user's data has to be exercised: opening a store that is already on
//  disk. This suite owns ordinary round trips and deletion durability, at the
//  current schema version.
//
//  Opening an *older* store — and with it the inline-default contract that
//  `Hike`'s comments describe, which only a store missing those columns can
//  exercise — lives in `SchemaMigrationTests`.
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
                OfflineDownloadRecord(providerID: "osm", maxZoom: 14, savedTileKeys: ["osm/14/1/1@2.0"])
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

    /// A finished walk is a row of its own in the mirrored store, hung off
    /// its hike: every column survives a reopen, and the hike's cascade takes
    /// it when the hike goes.
    @Test("a walk written to disk comes back whole and cascades with its hike")
    func walkSurvivesAReopenAndCascades() throws {
        try makeDirectory()
        defer { removeDirectory() }

        let hikeID = UUID()
        let walkID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_750_000_000)
        do {
            let container = try openContainer()
            let context = ModelContext(container)
            let hike = Hike(title: "Ridge Loop", distanceMeters: 2000, id: hikeID, route: Fixture.ridgeRoute)
            context.insert(hike)
            let walk = HikeWalk(
                hikeID: hikeID,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(3600),
                activeSeconds: 3000,
                coveredIntervals: [0, 800, 1200, 1500],
                furthestDistanceMeters: 1500,
                routeDistanceMeters: 2000,
                endReason: .reachedEnd,
                id: walkID
            )
            context.insert(walk)
            walk.hike = hike
            try context.save()
        }

        do {
            let container = try openContainer()
            let context = ModelContext(container)
            let reopened = try #require(
                try context.fetch(FetchDescriptor<HikeWalk>(predicate: #Predicate { $0.id == walkID })).first
            )
            #expect(reopened.hikeID == hikeID)
            #expect(reopened.hike?.id == hikeID)
            #expect(reopened.startedAt == startedAt)
            #expect(reopened.endedAt == startedAt.addingTimeInterval(3600))
            #expect(reopened.activeSeconds == 3000)
            #expect(reopened.coveredIntervals == [0, 800, 1200, 1500])
            #expect(reopened.furthestDistanceMeters == 1500)
            #expect(reopened.routeDistanceMeters == 2000)
            #expect(reopened.endReason == .reachedEnd)
            #expect(abs(reopened.coveredFraction - 0.55) < 0.0001)

            let hike = try #require(
                try context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })).first
            )
            #expect(hike.walks?.map(\.id) == [walkID])
            context.delete(hike)
            try context.save()
        }

        let container = try openContainer()
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<HikeWalk>()).isEmpty, "the cascade took the walk with the hike")
    }

    /// A walk's phase is a commit rather than a report. The sidecar is the
    /// only thing that survives the process, so a Pause the store refuses
    /// must leave the walk following everywhere — otherwise the next launch
    /// reads a walk that was never paused, and banks the whole stop as active
    /// time on a screen that had said Paused since the tap.
    @Test("a Pause the store refuses does not come back as a paused walk")
    func refusedPauseIsNotDurable() throws {
        try makeDirectory()
        defer { removeDirectory() }

        let hikeID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let now = startedAt.addingTimeInterval(600)
        do {
            let container = try openContainer()
            let context = ModelContext(container)
            let hike = Hike(title: "Ridge Loop", distanceMeters: 2000, id: hikeID, route: Fixture.ridgeRoute)
            context.insert(hike)
            hike.walkInProgress = TrailWalkRecord(
                hikeID: hikeID,
                routeDistanceMeters: 2000,
                startedAt: startedAt
            )
            try context.save()
        }

        do {
            let container = try openContainer()
            let session = TrailWalkSession(
                context: ModelContext(container),
                clock: { now },
                save: { _ in throw CocoaError(.fileWriteUnknown) }
            )
            session.restoreAtLaunch()
            #expect(session.phase == .following, "precondition: it adopted the open walk")

            #expect(!session.pause(), "a store that refuses the write refuses the pause")
            #expect(session.phase == .following, "and the walk is left as the disk still has it")
        }

        do {
            let container = try openContainer()
            let context = ModelContext(container)
            #expect(try walkedHike(hikeID, in: context).walkInProgress?.phase == .following)
            // The other half of the claim: a Pause the store takes is durable.
            let session = TrailWalkSession(context: context, clock: { now })
            session.restoreAtLaunch()
            #expect(session.pause())
        }

        let context = ModelContext(try openContainer())
        #expect(try walkedHike(hikeID, in: context).walkInProgress?.phase == .paused)
    }

    /// The hike a walk hangs off, refetched from a freshly opened store.
    private func walkedHike(_ id: UUID, in context: ModelContext) throws -> Hike {
        try #require(
            try context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
        )
    }

    /// An end reason this build does not know decodes as no reason rather
    /// than failing the row — the same degradation `routeLinePatternID` has.
    @Test("an unknown end reason degrades rather than failing to decode")
    func unknownEndReasonDegrades() {
        let walk = HikeWalk(
            hikeID: UUID(),
            startedAt: .now,
            endedAt: .now,
            activeSeconds: 0,
            coveredIntervals: [],
            furthestDistanceMeters: 0,
            routeDistanceMeters: 100,
            endReason: .ended
        )
        walk.endReasonID = "teleported"
        #expect(walk.endReason == nil)
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
