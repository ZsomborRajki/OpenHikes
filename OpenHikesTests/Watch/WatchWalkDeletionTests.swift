//
//  WatchWalkDeletionTests.swift
//  OpenHikesTests
//
//  A walk from the watch that the hiker has since deleted, arriving again.
//
//  The watch keeps a walk until a receipt comes back, so a receipt lost on the
//  way, a transfer still outstanding or a watch relaunch can deliver the same
//  walk after its hike has gone. The ledger the import checks used to be the
//  hike's own sidecar, which the deletion takes with it — so the retry read as
//  a new walk, and the deleted hike came back (#1115). These go through
//  ``HikeDeletion``, the one sequence every whole-hike deletion uses, rather
//  than restating it.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Testing

@MainActor
@Suite("Walks from the watch whose hike was deleted")
struct WatchWalkDeletionTests {
    private typealias Fixture = WatchWalkImportTests.Fixture

    /// Saves `walk`, then deletes the hike it became the way the list's swipe
    /// does, and answers the deleted hike's id.
    private func importThenDelete(
        _ walk: WatchRecordedWalk,
        in container: ModelContainer
    ) async throws -> UUID {
        let first = await WatchWalkImport.store(walk, in: container)
        guard case .imported(let hikeID) = first else {
            Issue.record("Expected the first arrival to be imported, got \(first)")
            throw Unexpected()
        }
        let context = container.mainContext
        let hike = try #require(try Fixture.hike(hikeID, in: context))
        try HikeDeletion.delete([hike])
        #expect(try Fixture.hikeCount(in: container) == 0)
        return hikeID
    }

    @Test("a redelivery after the hike was deleted earns a receipt and recreates nothing")
    func aDeletedWalkStaysDeleted() async throws {
        let container = try Fixture.modelContainer()
        let walk = Fixture.walk()
        _ = try await importThenDelete(walk, in: container)

        let again = await WatchWalkImport.store(walk, in: container)

        #expect(try Fixture.hikeCount(in: container) == 0, "the deletion stays a deletion")
        #expect(again == .deleted)
        #expect(again.deservesReceipt, "and the watch is still told to let the walk go")
    }

    @Test("the deletion is remembered across a reopen of both stores")
    func theDeletionSurvivesAReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-walk-deletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("OpenHikes.store")
        let localURL = directory.appendingPathComponent("OpenHikesLocal.store")
        let walk = Fixture.walk()

        do {
            let container = try ModelContainer.openHikes(url: storeURL, localURL: localURL)
            _ = try await importThenDelete(walk, in: container)
        }

        let reopened = try ModelContainer.openHikes(url: storeURL, localURL: localURL)
        let again = await WatchWalkImport.store(walk, in: reopened)

        #expect(try Fixture.hikeCount(in: reopened) == 0)
        #expect(again == .deleted)
        #expect(again.deservesReceipt)
    }

    @Test("another walk is still imported after one was deleted")
    func anotherWalkIsUnaffected() async throws {
        let container = try Fixture.modelContainer()
        _ = try await importThenDelete(Fixture.walk(), in: container)

        let other = await WatchWalkImport.store(Fixture.walk(), in: container)

        guard case .imported = other else {
            Issue.record("Expected a different walk to be imported, got \(other)")
            return
        }
        #expect(try Fixture.hikeCount(in: container) == 1)
    }

    /// The deletion and its record are one commit: a refusal puts the hike
    /// back, so the redelivery is the ordinary repeat of a hike still here.
    @Test("a refused deletion leaves the walk recognised as the hike it still is")
    func aRefusedDeletionRemembersNothing() async throws {
        let container = try Fixture.modelContainer()
        let walk = Fixture.walk()
        let first = await WatchWalkImport.store(walk, in: container)
        guard case .imported(let hikeID) = first else {
            Issue.record("Expected the first arrival to be imported, got \(first)")
            return
        }
        let hike = try #require(try Fixture.hike(hikeID, in: container.mainContext))

        #expect(throws: Fixture.RefusedSave.self) {
            try HikeDeletion.delete([hike]) { _ in throw Fixture.RefusedSave() }
        }

        let again = await WatchWalkImport.store(walk, in: container)
        #expect(again == .alreadyImported(hikeID))
        #expect(try Fixture.hikeCount(in: container) == 1)
    }

    /// A read that failed says nothing about whether the hike was deleted, so
    /// the walk is refused and stays on the watch rather than being made again.
    @Test("a redelivery whose deletion read fails is refused rather than saved again")
    func aFailedDeletionReadIsNotAMiss() async throws {
        let container = try Fixture.modelContainer()
        let walk = Fixture.walk()
        _ = try await importThenDelete(walk, in: container)
        var ledger = WatchWalkImport.Ledger.store
        ledger.wasDeleted = { _, _ in throw Fixture.RefusedFetch() }

        let refused = await WatchWalkImport.store(walk, in: container, ledger: ledger)

        #expect(refused == .refused(.notSaved))
        #expect(!refused.deservesReceipt)
        #expect(try Fixture.hikeCount(in: container) == 0)

        // The control: once the store reads again, the deletion is found.
        let again = await WatchWalkImport.store(walk, in: container)
        #expect(again == .deleted)
    }

    private struct Unexpected: Error {}
}
