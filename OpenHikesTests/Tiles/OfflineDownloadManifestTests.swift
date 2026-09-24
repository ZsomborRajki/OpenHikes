//
//  OfflineDownloadManifestTests.swift
//  OpenHikesTests
//
//  "Offline download manifest", split out of OfflineTileDownloaderTests.swift
//  so that a file declares one @Suite. That file's header still holds the
//  context the two share.
//

import CoreLocation
import Foundation
import MapKit
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

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
                maxZoom: 12,
                savedTileKeys: ["test/12/1/1"]
            )
        )
        hike.mergeOfflineDownload(
            OfflineDownloadRecord(
                providerID: "test",
                maxZoom: 12,
                savedTileKeys: ["test/12/1/2"]
            )
        )

        #expect(hike.offlineDownloads.count == 1)
        #expect(
            Set(hike.offlineDownloads[0].savedTileKeys)
                == ["test/12/1/1", "test/12/1/2"]
        )
    }

    @Test("a complete retry replaces partial coverage")
    func completeRetryReplacesPartial() {
        let hike = Fixture.hike(in: context)
        hike.mergeOfflineDownload(
            OfflineDownloadRecord(
                providerID: "test",
                maxZoom: 12,
                savedTileKeys: ["test/12/1/1"]
            )
        )
        hike.mergeOfflineDownload(
            OfflineDownloadRecord(providerID: "test", maxZoom: 12)
        )

        #expect(hike.offlineDownloads.count == 1)
        #expect(hike.offlineDownloads[0].savedTileKeys.isEmpty)
    }

    @Test("a record without partial keys decodes as complete coverage")
    func completeRecordDecodes() throws {
        let data = Data(#"{"providerID":"test","maxZoom":12,"savedTileKeys":[]}"#.utf8)
        let record = try JSONDecoder().decode(OfflineDownloadRecord.self, from: data)
        #expect(record.savedTileKeys.isEmpty)
    }
}
