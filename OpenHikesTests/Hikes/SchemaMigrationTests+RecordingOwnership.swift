//
//  SchemaMigrationTests+RecordingOwnership.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension SchemaMigrationTests {
    @Test("V2 drafts keep their data and default to unowned through migration")
    func versionTwoDoesNotInventRecordingOwnership() throws {
        try makeDirectory()
        defer { removeDirectory() }
        let hikeID = UUID()
        let photoID = UUID()
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        try writeVersionTwoDraft(hikeID: hikeID, photoID: photoID, date: date)

        do {
            let container = try ModelContainer.openHikes(url: hikesURL, localURL: localURL)
            let context = ModelContext(container)
            let hike = try #require(try fetchHike(hikeID, in: context))
            #expect(hike.isRecording)
            #expect(!hike.ownsRecordingDraft)
            #expect(hike.route.first?.boundary == .paused)
            #expect(hike.photos.first?.id == photoID)
            #expect(hike.photos.first?.matchEvidence == .timeAndPlace)
            #expect(hike.walks?.first?.coveredIntervals == [10, 250])
            #expect(hike.autoSavedTileKeys == ["osm/16/34567/22345"])
            #expect(hike.offlineDownloads.first?.savedTileKeys == ["osm/14/1/1"])
            #expect(hike.walkInProgress?.coverage.intervals == [10, 250])
            let sidecar = try #require(try hike.resolveLocalState())
            #expect(sidecar.hikeID == hikeID)
            #expect(!sidecar.ownsRecordingDraft, "existing sidecars must backfill false too")
            // Exercise the new column on the migrated store, then reopen it.
            hike.ownsRecordingDraft = true
            try context.save()
        }

        let container = try ModelContainer.openHikes(url: hikesURL, localURL: localURL)
        let context = ModelContext(container)
        let hike = try #require(try fetchHike(hikeID, in: context))
        #expect(hike.ownsRecordingDraft)
        #expect(hike.photos.first?.id == photoID)
        #expect(hike.walkInProgress?.hikeID == hikeID)
        #expect(try context.fetch(FetchDescriptor<HikeLocalState>()).count == 1)
    }

    private func writeVersionTwoDraft(hikeID: UUID, photoID: UUID, date: Date) throws {
        let container = try ModelContainer.openHikes(
            schemaVersion: OpenHikesSchemaV2.self,
            url: hikesURL,
            localURL: localURL
        )
        let context = ModelContext(container)
        let hike = OpenHikesSchemaV2.Hike(id: hikeID, title: "Legacy recording")
        hike.isRecording = true
        let point = Fixture.ridgeRoute[0]
        let coveredStart: Double = 10
        let coveredEnd: Double = 250
        hike.route = [.init(latitude: point.latitude, longitude: point.longitude, timestamp: date, boundary: .paused)]
        hike.photos = [
            .init(id: photoID, capturedAt: date, pathExtension: "jpeg", matchEvidence: .timeAndPlace),
        ]
        let walk = OpenHikesSchemaV2.HikeWalk(hikeID: hikeID)
        walk.coveredIntervals = [coveredStart, coveredEnd]
        walk.hike = hike
        context.insert(hike)
        context.insert(walk)
        let sidecar = OpenHikesSchemaV2.HikeLocalState(hikeID: hikeID)
        sidecar.autoSavedTileKeys = ["osm/16/34567/22345"]
        sidecar.offlineDownloads = [.init(providerID: "osm", maxZoom: 14, savedTileKeys: ["osm/14/1/1"], scale: 0)]
        sidecar.walkInProgress = .init(
            hikeID: hikeID,
            startedAt: date,
            coverage: .init(intervals: [coveredStart, coveredEnd], furthestDistanceMeters: coveredEnd),
            bankedActiveSeconds: 120,
            phaseID: "paused",
            phaseChangedAt: date,
            lastMatchedAt: date,
            lastFollowedDistanceMeters: coveredEnd,
            routeDistanceMeters: 1000
        )
        context.insert(sidecar)
        try context.save()
    }
}
