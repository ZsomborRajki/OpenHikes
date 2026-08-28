//
//  HikeRecorderTests+TileClaims.swift
//  OpenHikesTests
//
//  That a recording draft takes its device-local sidecar with it when the
//  recorder throws it away.
//
//  A draft is not an empty hike as far as `HikeLocalState` is concerned:
//  `AutoSaveController` folds browsing tiles into whichever hike is active,
//  and for the length of a walk that is the draft. The two stores are not
//  related — they cannot be — so nothing cascades, and nothing in the app ever
//  fetches a `HikeLocalState` except by the `hikeID` of a hike that still
//  exists. A row that outlives its draft is therefore unreachable by every
//  claim set, every sweep and every screen: it is never read again and never
//  deleted, one more per discarded recording, for the life of the install.
//
//  `HikeLocalStateTests` pins the sidecar's own behaviour and the user-facing
//  delete in `MapSheet`. What is pinned here is that the recorder's two delete
//  paths — the walker's discard and the orphan sweep at the start of the next
//  session — agree with it.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

extension HikeRecorderTests {
    /// The key shape `TileCache` actually stores under, so this reads as a
    /// claim rather than as a string.
    private static let autoSavedTileKey = "osm/16/34567/22345@2.0"

    /// The walker records with the map on screen, then discards. The draft
    /// goes; so must the row that was accumulating tiles against it.
    ///
    /// Everything here reads through `container.mainContext` — the recorder's
    /// own context, and the one the sidecar is written and deleted in — so
    /// what is being asserted is the delete rather than SwiftData's
    /// cross-context coordination.
    @Test("discarding a recording takes its device-local tile claims with it")
    func discardRemovesTheDraftsTileClaims() async throws {
        let mainContext = container.mainContext
        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()

        let draft = try #require(hikeRecorder.currentHike)
        draft.autoSavedTileKeys = [Self.autoSavedTileKey]
        try mainContext.save()
        #expect(
            try mainContext.fetch(FetchDescriptor<HikeLocalState>()).count == 1,
            "the write has to have reached the sidecar for the delete to mean anything"
        )

        await hikeRecorder.discard()

        #expect(try mainContext.fetch(FetchDescriptor<Hike>()).isEmpty)
        #expect(
            try mainContext.fetch(FetchDescriptor<HikeLocalState>()).isEmpty,
            "a row left here is unreachable: nothing fetches one except through a hike that exists"
        )
    }

    /// The other path: a draft left behind by a launch that ended without
    /// stopping, swept away when the next session activates. Same leak, and it
    /// is the larger one — the orphan had a whole walk to accumulate keys.
    @Test("replacing an orphaned draft takes its device-local tile claims with it")
    func startRemovesTheOrphanedDraftsTileClaims() async throws {
        let mainContext = container.mainContext
        let orphan = Fixture.hike(
            in: mainContext,
            title: "Interrupted Hike",
            route: []
        ) { hike in
            hike.isRecording = true
            hike.autoSavedTileKeys = [Self.autoSavedTileKey]
        }
        let orphanID = orphan.id
        try mainContext.save()
        #expect(try mainContext.fetch(FetchDescriptor<HikeLocalState>()).count == 1)

        let hikeRecorder = makeRecorder()
        await hikeRecorder.start()

        let current = try #require(hikeRecorder.currentHike)
        #expect(current.id != orphanID, "the new session is a new draft, not the orphan resumed")
        #expect(try mainContext.fetch(FetchDescriptor<Hike>()).count == 1)
        // The new draft has claimed nothing, so any surviving row is the
        // orphan's.
        #expect(
            try mainContext.fetch(FetchDescriptor<HikeLocalState>()).isEmpty,
            "the swept orphan's sidecar goes with it"
        )
    }
}
