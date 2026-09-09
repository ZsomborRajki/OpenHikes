//
//  HikeRecorderTests+Ownership.swift
//  OpenHikesTests
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension HikeRecorderTests {
    /// A synced draft is indistinguishable from a legacy draft without a
    /// journal. Browsing its map can create a sidecar on the receiving phone.
    private func foreignDraft(withLocalTiles: Bool) throws -> (UUID, HikePhoto) {
        let photo = HikePhoto(capturedAt: clock.now)
        let hike = Hike(
            title: "Other phone's recording",
            distanceMeters: 0,
            isRecording: true,
            photos: [photo]
        )
        container.mainContext.insert(hike)
        if withLocalTiles {
            hike.autoSavedTileKeys = ["osm/16/34567/22345"]
        }
        try container.mainContext.save()
        return (hike.id, photo)
    }

    private func expectForeignDraft(_ id: UUID, photo: HikePhoto) throws {
        let fresh = ModelContext(container)
        let hike = try #require(
            try fresh.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first
        )
        #expect(hike.isRecording)
        #expect(hike.photos == [photo])
    }

    @Test("empty-journal recovery preserves unknown drafts and photos", arguments: [false, true])
    func emptyJournalPreservesForeignDraft(withLocalTiles: Bool) async throws {
        let (id, photo) = try foreignDraft(withLocalTiles: withLocalTiles)
        let hikeRecorder = makeRecorder()

        await hikeRecorder.recoverOpenSession()

        #expect(hikeRecorder.phase == .idle)
        try expectForeignDraft(id, photo: photo)
    }

    @Test("Start preserves a foreign draft received after launch", arguments: [false, true])
    func startPreservesForeignDraft(withLocalTiles: Bool) async throws {
        let hikeRecorder = makeRecorder()
        await hikeRecorder.recoverOpenSession()
        let (id, photo) = try foreignDraft(withLocalTiles: withLocalTiles)

        await hikeRecorder.start()

        #expect(hikeRecorder.phase == .waitingForFix)
        #expect(hikeRecorder.currentHike?.id != id)
        try expectForeignDraft(id, photo: photo)
    }

    @Test("recovering a local journal preserves other devices' drafts", arguments: [false, true])
    func localRecoveryPreservesForeignDraft(withLocalTiles: Bool) async throws {
        let localID = UUID()
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: localID, startedAt: clock.now)
        try await journal.close()
        let (id, photo) = try foreignDraft(withLocalTiles: withLocalTiles)
        let hikeRecorder = makeRecorder()

        await hikeRecorder.recoverOpenSession(automaticallyResume: false)

        #expect(hikeRecorder.phase == .paused)
        #expect(hikeRecorder.currentHike?.id == localID)
        try expectForeignDraft(id, photo: photo)
    }

    @Test("recovering a legacy journal claims only its draft", arguments: [false, true])
    func localJournalClaimsLegacyDraft(withLocalTiles: Bool) async throws {
        let (localID, photo) = try foreignDraft(withLocalTiles: withLocalTiles)
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: localID, startedAt: clock.now)
        try await journal.close()
        let orphan = Fixture.hike(in: container.mainContext) { hike in
            hike.isRecording = true
            hike.ownsRecordingDraft = true
        }
        let orphanID = orphan.id
        try container.mainContext.save()
        let hikeRecorder = makeRecorder()

        await hikeRecorder.recoverOpenSession(automaticallyResume: false)

        #expect(hikeRecorder.phase == .paused)
        try expectForeignDraft(localID, photo: photo)
        let fresh = ModelContext(container)
        let claims = try fresh.fetch(FetchDescriptor<HikeLocalState>())
        #expect(claims.map(\.hikeID) == [localID])
        #expect(claims.first?.ownsRecordingDraft == true)
        #expect(try fresh.fetch(FetchDescriptor<Hike>()).allSatisfy { $0.id != orphanID })

        // The claim is durable even if a later launch loses the journal.
        try hikeRecorder.deleteOrphanedRecordingHikes(except: localID)
        try expectForeignDraft(localID, photo: photo)
        try hikeRecorder.deleteOrphanedRecordingHikes()
        #expect(try ModelContext(container).fetch(FetchDescriptor<Hike>()).isEmpty)
    }

    @Test("a refused legacy claim preserves the draft and its prior sidecar", arguments: [false, true])
    func failedOwnershipClaimRollsBack(withLocalTiles: Bool) async throws {
        let (localID, photo) = try foreignDraft(withLocalTiles: withLocalTiles)
        let journal = TrackJournal(directory: directory, clock: clock.read)
        try await journal.start(sessionID: localID, startedAt: clock.now)
        try await journal.close()
        let hikeRecorder = makeRecorder(saveModelContext: { _ in throw InjectedPersistenceError() })

        await hikeRecorder.recoverOpenSession(automaticallyResume: false)

        guard case .failed = hikeRecorder.phase else {
            Issue.record("a refused ownership claim must fail recovery")
            return
        }
        try container.mainContext.save()
        try expectForeignDraft(localID, photo: photo)
        let claims = try ModelContext(container).fetch(FetchDescriptor<HikeLocalState>())
        #expect(claims.count == (withLocalTiles ? 1 : 0))
        #expect(claims.allSatisfy { !$0.ownsRecordingDraft })
        if withLocalTiles {
            #expect(claims.first?.autoSavedTileKeys == ["osm/16/34567/22345"])
        }
    }

    @Test("a refused new recording leaves no ownership claim")
    func failedStartRemovesOwnershipClaim() async throws {
        let hikeRecorder = makeRecorder(saveModelContext: { _ in throw InjectedPersistenceError() })

        await hikeRecorder.start()

        guard case .failed = hikeRecorder.phase else {
            Issue.record("the injected save failure must refuse Start")
            return
        }
        try container.mainContext.save()
        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<Hike>()).isEmpty)
        #expect(try fresh.fetch(FetchDescriptor<HikeLocalState>()).isEmpty)
    }
}
