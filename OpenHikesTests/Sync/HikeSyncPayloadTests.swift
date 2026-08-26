//
//  HikeSyncPayloadTests.swift
//  OpenHikesTests
//
//  What travels, and — the part that actually needed a test — what doesn't.
//
//  The tile fields are the reason this app uses ``CKSyncEngine`` instead of
//  SwiftData's CloudKit mirroring, so "a hike arriving from another device
//  cannot claim tiles this device doesn't have" is the assertion that keeps
//  that decision honest.
//

import Foundation
@testable import OpenHikes
import SwiftData
import Testing

@MainActor
@Suite("Hike sync payload")
struct HikeSyncPayloadTests {
    private enum Constants {
        static let tileKeys = ["osm/14/8000/5000@2", "osm/15/16000/10000@2"]
        static let otherTileKeys = ["osm/12/2000/1250@2"]
        static let customName = "The Long Way Round"
        static let author = "A Walker"
        static let keywords = "ridge, forest"
        static let trackDescription = "Up the ridge and back along the river."
        static let surface = ["asphalt": 120.0, "gravel": 880.0]
        static let difficulty = ["T2": 500.0, "T3": 500.0]
    }

    @Test("A payload carries the fields that describe the walk")
    func payloadCarriesDescriptiveFields() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { hike in
            hike.customName = Constants.customName
            hike.author = Constants.author
            hike.keywords = Constants.keywords
            hike.trackDescription = Constants.trackDescription
            hike.surfaceMetersByCategory = Constants.surface
            hike.difficultyMetersByGrade = Constants.difficulty
            hike.autoFollowEnabled = false
        }

        let payload = try #require(HikeSyncPayload(hike: hike))

        #expect(payload.id == hike.id)
        #expect(payload.title == hike.title)
        #expect(payload.customName == Constants.customName)
        #expect(payload.author == Constants.author)
        #expect(payload.keywords == Constants.keywords)
        #expect(payload.trackDescription == Constants.trackDescription)
        #expect(payload.surfaceMetersByCategory == Constants.surface)
        #expect(payload.difficultyMetersByGrade == Constants.difficulty)
        #expect(payload.autoFollowEnabled == false)
        #expect(payload.route.count == hike.route.count)
    }

    /// The whole argument for hand-rolling sync in one test: a hike that
    /// arrives from another device must not be able to tell this one that it
    /// holds offline maps it never downloaded.
    @Test("Applying a payload leaves this device's tile bookkeeping alone")
    func applyingLeavesTilesAlone() throws {
        let context = try Fixture.modelContext()
        let source = Fixture.hike(in: context, title: "Source") { hike in
            hike.autoSavedTileKeys = Constants.otherTileKeys
            hike.autoSaveTilesEnabled = false
        }
        let destination = Fixture.hike(in: context, title: "Destination") { hike in
            hike.autoSavedTileKeys = Constants.tileKeys
            hike.autoSaveTilesEnabled = true
        }

        let payload = try #require(HikeSyncPayload(hike: source))
        payload.apply(to: destination)

        #expect(destination.title == "Source")
        #expect(destination.autoSavedTileKeys == Constants.tileKeys)
        #expect(destination.autoSaveTilesEnabled)
        #expect(destination.offlineDownloads.isEmpty)
    }

    /// `id` is the identity the record was looked up by. Writing it could only
    /// ever graft one hike's identity onto another.
    @Test("Applying a payload does not rewrite the hike's identity")
    func applyingKeepsIdentity() throws {
        let context = try Fixture.modelContext()
        let source = Fixture.hike(in: context, title: "Source")
        let destination = Fixture.hike(in: context, title: "Destination")
        let originalID = destination.id

        try #require(HikeSyncPayload(hike: source)).apply(to: destination)

        #expect(destination.id == originalID)
    }

    /// A draft is rewritten on every GPS fix and has no finished route. It is
    /// the recorder's, and sending it would describe a walk that isn't over.
    @Test("A recording draft refuses to become a payload")
    func draftIsRefused() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context) { $0.isRecording = true }

        #expect(HikeSyncPayload(hike: hike) == nil)
        #expect(HikePhotoSyncPayload.payloads(of: hike).isEmpty)
    }

    /// A deleted hike is on its way out; reading it would only send it back.
    @Test("A deleted hike refuses to become a payload")
    func deletedHikeIsRefused() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        context.delete(hike)

        #expect(HikeSyncPayload(hike: hike) == nil)
    }

    /// The insert path and the update path have to agree, or a field added to
    /// one would be silently missing from hikes that arrived through the other.
    @Test("A hike built from a payload matches one written over")
    func makeHikeMatchesApply() throws {
        let context = try Fixture.modelContext()
        let source = Fixture.hike(in: context, title: "Source") { hike in
            hike.customName = Constants.customName
            hike.surfaceMetersByCategory = Constants.surface
        }
        let payload = try #require(HikeSyncPayload(hike: source))

        let inserted = payload.makeHike()
        context.insert(inserted)
        let updated = Fixture.hike(in: context, title: "Stale")
        payload.apply(to: updated)

        #expect(inserted.id == source.id)
        #expect(inserted.title == updated.title)
        #expect(inserted.customName == updated.customName)
        #expect(inserted.distanceMeters == updated.distanceMeters)
        #expect(inserted.surfaceMetersByCategory == updated.surfaceMetersByCategory)
        #expect(inserted.route.count == updated.route.count)
    }
}
