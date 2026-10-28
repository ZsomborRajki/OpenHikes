//
//  OfflineDownloadClaimRetryTests.swift
//  OpenHikesTests
//
//  A refused claim must be retryable on the same hike, without losing other
//  pending work or reporting a manifest that exists only in a detached sidecar.
//  Reopening both stores distinguishes that quiet failure from durable coverage.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Offline download claim retries")
struct OfflineDownloadClaimRetryTests {
    private static let record = OfflineDownloadRecord(
        providerID: "stadia_outdoors",
        maxZoom: 12,
        savedTileKeys: ["stadia_outdoors/12/1/1"]
    )

    @Test("a refused first claim can be retried and survives fresh contexts and a reopen")
    func firstClaimCanBeRetriedAfterRefusal() throws {
        let sandbox = try StoreSandbox()
        let id = try sandbox.withStore { context in
            let hike = Fixture.hike(in: context)
            try context.save()
            #expect(try context.fetch(FetchDescriptor<HikeLocalState>()).isEmpty)

            #expect(throws: OfflineDownloadClaim.Failure.notSaved) {
                try OfflineDownloadClaim.commit(Self.record, for: hike) { _ in
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            #expect(hike.offlineDownloads.isEmpty)

            try OfflineDownloadClaim.commit(Self.record, for: hike)
            let fresh = ModelContext(context.container)
            let rows = try fresh.fetch(FetchDescriptor<HikeLocalState>())
            #expect(rows.count == 1)
            #expect(rows.first?.offlineDownloads == [Self.record])
            return hike.id
        }

        try sandbox.withStore { context in
            let hike = try #require(
                try context.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
            )
            #expect(hike.offlineDownloads == [Self.record])
            #expect(try context.fetch(FetchDescriptor<HikeLocalState>()).count == 1)
        }
    }

    @Test("a refused claim restores only its own manifest", arguments: [false, true])
    func refusalPreservesUnrelatedPendingWork(hasSidecar: Bool) throws {
        let context = try Fixture.modelContext()
        let target = Fixture.hike(in: context)
        let renamed = Fixture.hike(in: context, title: "Original")
        let previous = hasSidecar ? [
            OfflineDownloadRecord(providerID: "stadia_outdoors", maxZoom: 10)
        ] : []
        if hasSidecar { target.offlineDownloads = previous }
        try context.save()
        renamed.title = "Renamed while downloading"
        let inserted = Fixture.hike(in: context, title: "Unsaved insertion")

        #expect(throws: OfflineDownloadClaim.Failure.notSaved) {
            try OfflineDownloadClaim.commit(Self.record, for: target) { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        }
        #expect(target.offlineDownloads == previous)
        #expect(renamed.title == "Renamed while downloading")
        #expect(inserted.modelContext === context)

        try context.save()
        let fresh = ModelContext(context.container)
        let hikes = try fresh.fetch(FetchDescriptor<Hike>())
        #expect(hikes.count == 3)
        #expect(hikes.first { $0.id == renamed.id }?.title == "Renamed while downloading")
        #expect(hikes.first { $0.id == inserted.id }?.title == "Unsaved insertion")
        #expect(hikes.first { $0.id == target.id }?.offlineDownloads == previous)
    }
}
