//
//  WatchWalkHealthExportTests+ImportedLine.swift
//  OpenHikesTests
//
//  The workout written from the line its import handed on (#1372).
//
//  The export used to fetch the hike into the main context and read its line
//  there, and the line is external storage, so that decoded all of it on the
//  main actor. Seen the way ``HikeDetailLineTests`` sees a screen: the test
//  holds the hike in the main context with its line never read, so an export
//  that read the line there would leave it warm, and a read of it afterwards
//  would come back at once rather than take the whole decode. From iOS 27,
//  for the reason in that suite's header.
//
//  The export no longer looks the hike up at all, so a hike deleted under it
//  is ``HikeWorkoutExport``'s to notice, before the write and after it.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

extension WatchWalkHealthExportTests {
    @available(iOS 27.0, *)
    @Test("a long walk is written from the line its import handed on, decoding none of it on the main actor")
    func aLongWalkDecodesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "watch-health-line/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = try Harness(savesToHealth: .on, container: ModelContainer.openHikes(
            url: directory.appending(path: "OpenHikes.store"),
            localURL: directory.appending(path: "OpenHikesLocal.store")
        ))
        let walk = Self.longWalk(fixes: HikeDetailLineTests.longPoints)
        let outcome = await WatchWalkImport.store(walk, in: harness.container)
        let hike = try Self.savedHike(from: outcome, in: harness.container.mainContext)

        await harness.export.export(walk, after: outcome)

        let read = HikeDetailLineTests.mainActorRead(of: hike)
        #expect(read.points == HikeDetailLineTests.longPoints)
        #expect(read.duration >= .milliseconds(5), "a line the export read comes back at once: \(read.duration)")
        let request = try #require(harness.writer.written.first)
        #expect(request.route == hike.route, "the line the hike was saved with")
        #expect(request.distanceMeters == hike.distanceMeters, "and the length measured along it")
    }

    @Test("a hike deleted between its import and its export is neither written nor marked")
    func aHikeDeletedBeforeItsExportIsLeftAlone() async throws {
        let harness = try Harness(savesToHealth: .on)
        let context = harness.container.mainContext
        let walk = WatchWalkImportTests.Fixture.walk()
        let outcome = await WatchWalkImport.store(walk, in: harness.container)
        let hike = try Self.savedHike(from: outcome, in: context)
        let hikeID = hike.id
        try HikeDeletion.delete([hike])

        await harness.export.export(walk, after: outcome)

        #expect(harness.writer.written.isEmpty)
        #expect(HikeLocalState.existing(for: hikeID, in: context) == nil, "no sidecar comes back for it")
    }

    @Test("a hike deleted while Health writes its walk has the workout taken back out")
    func aHikeDeletedDuringTheWriteIsTakenBack() async throws {
        let container = try WatchWalkImportTests.Fixture.modelContainer()
        let context = container.mainContext
        let writer = HeldWorkoutWriter()
        let export = WatchWalkHealthExport(
            writer: writer,
            container: container,
            defaults: Harness.defaults(savesToHealth: .on),
            weatherState: { .idle }
        )
        let walk = WatchWalkImportTests.Fixture.walk()
        let outcome = await WatchWalkImport.store(walk, in: container)
        let hike = try Self.savedHike(from: outcome, in: context)
        let hikeID = hike.id

        let exporting = Task { await export.export(walk, after: outcome) }
        await writer.untilWriting()
        try HikeDeletion.delete([hike], workouts: writer)
        await settleDelegateHop(until: "the deletion to ask while the write is held") {
            writer.deleted == [hikeID]
        }
        writer.finish()
        await exporting.value

        #expect(writer.deleted == [hikeID, hikeID], "asked as it committed, and again once Health answered")
        #expect(HikeLocalState.existing(for: hikeID, in: context) == nil, "no sidecar comes back for it")
    }

    /// The hike `outcome` saved, fetched into `context` with its line unread.
    private static func savedHike(from outcome: WatchWalkImportOutcome, in context: ModelContext) throws -> Hike {
        guard case .imported(let saved) = outcome else {
            Issue.record("Expected the walk to be imported")
            throw NotImported()
        }
        return try #require(try WatchWalkImportTests.Fixture.hike(saved.hikeID, in: context))
    }

    private struct NotImported: Error {}

    /// About a metre of latitude.
    private static let fixSpacingDegrees = 0.00001

    /// A metre or so a fix, one fix a second.
    private static func longWalk(fixes count: Int) -> WatchRecordedWalk {
        let start = WatchWalkImportTests.Fixture.start
        let fixes = (0..<count).map { index in
            WatchRecordedFix(
                latitude: WatchWalkImportTests.Fixture.latitude + Double(index) * fixSpacingDegrees,
                longitude: WatchWalkImportTests.Fixture.longitude,
                timestamp: start.addingTimeInterval(Double(index)),
                horizontalAccuracy: 5
            )
        }
        return WatchRecordedWalk(
            sessionID: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(Double(count - 1)),
            distanceMeters: 0,
            activeSeconds: Double(count - 1),
            fixes: fixes
        )
    }
}
