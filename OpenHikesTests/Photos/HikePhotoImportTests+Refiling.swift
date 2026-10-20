//
//  HikePhotoImportTests+Refiling.swift
//  OpenHikesTests
//
//  A picture the hike already holds, picked again from a place's screen, is
//  moved under the place rather than copied — and that move is a commit like
//  any attach. A store that refuses it has to leave the photograph where it
//  was filed and say so, the way a refused new photo does, rather than show it
//  under the place until the next launch quietly puts it back.
//
//  Both ways a repeat is found are covered: before anything is written, and
//  after the off-main file write, when the other library surface got the same
//  asset in first.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

extension HikePhotoImportTests {
    private enum Refiling {
        /// A spring at the fixture route's trailhead.
        static let spring = TrailPlace(
            latitude: Fixture.ridgeRoute[0].latitude,
            longitude: Fixture.ridgeRoute[0].longitude,
            symbol: .water
        )
        static let asset = "asset-1"
    }

    @MainActor
    private static func hikeWithAPlace(in context: ModelContext) -> Hike {
        let hike = Fixture.hike(in: context)
        hike.replacePlaces(with: [Refiling.spring], in: context)
        return hike
    }

    @MainActor
    @Test("a picture picked again whose move to a place cannot be saved stays where it was")
    func refileRollsBackWhenTheSaveFails() async throws {
        let sandbox = Sandbox()
        let context = try Fixture.modelContext()
        let hike = Self.hikeWithAPlace(in: context)
        let existing = try #require(
            await HikePhotoImport.add(
                Self.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: false,
                assetLocalIdentifier: Refiling.asset,
                store: sandbox.store
            )
        )

        let again = await HikePhotoImport.add(
            Self.sampleImageData(),
            to: hike,
            coordinate: nil,
            savesToPhotoLibrary: false,
            assetLocalIdentifier: Refiling.asset,
            placeID: Refiling.spring.id,
            store: sandbox.store,
            save: { _ in throw CocoaError(.fileWriteUnknown) }
        )

        #expect(again == nil, "a move the store refused is a failure to report")
        #expect(hike.photos.map(\.id) == [existing.id])
        #expect(hike.photos.first?.placeID == nil)
        #expect(hike.photos(ofPlace: Refiling.spring.id).isEmpty)
    }

    /// The second check, on the far side of the file write: the asset arrives
    /// by another route while the bytes are being written, so the repeat is
    /// only found once the write is done and its file is already on disk.
    ///
    /// Immediate start runs through the first duplicate check to the off-main
    /// write before returning control to this test. The main actor stays here
    /// until the repeat is attached, so the import can find it only at its
    /// second check. A yield would guarantee neither ordering and could let
    /// this pass through the early check or the refused new-photo path.
    @MainActor
    @Test("a repeat found after the file write keeps its filing when the move cannot be saved")
    func lateRefileRollsBackWhenTheSaveFails() async throws {
        let sandbox = Sandbox()
        let context = try Fixture.modelContext()
        let hike = Self.hikeWithAPlace(in: context)
        let origin = HikePhoto.Origin(assetLocalIdentifier: Refiling.asset)
        let existing = try #require(
            await Task.detached {
                sandbox.store.store(
                    Self.sampleImageData(),
                    capturedAt: Date(timeIntervalSince1970: 0),
                    coordinate: nil,
                    origin: origin
                )
            }.value
        )

        var saves = 0
        let importing = Task.immediate { @MainActor in
            await HikePhotoImport.add(
                Self.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: false,
                assetLocalIdentifier: Refiling.asset,
                placeID: Refiling.spring.id,
                store: sandbox.store,
                save: { _ in
                    saves += 1
                    #expect(hike.photos.map(\.id) == [existing.id], "the late check must find the repeat")
                    #expect(
                        hike.photos.first?.placeID == Refiling.spring.id,
                        "the save is a move of the existing photo"
                    )
                    throw CocoaError(.fileWriteUnknown)
                }
            )
        }
        hike.addPhoto(existing)
        let again = await importing.value

        #expect(again == nil, "a move the store refused is a failure to report")
        #expect(saves == 1)
        #expect(hike.photos.map(\.id) == [existing.id], "the repeat is found, not copied")
        #expect(hike.photos.first?.placeID == nil)
        await settleDelegateHop(until: "the repeat's file to be erased") {
            Self.fileCount(in: sandbox.store.directory) == 1
        }
        #expect(Self.fileCount(in: sandbox.store.directory) == 1)
        #expect(FileManager.default.fileExists(atPath: sandbox.store.url(for: existing).path))
    }

    /// Checked against the disk rather than the context that was refused, for
    /// the reason `addSurvivesAReopen` gives: in memory, a rolled-back move and
    /// a committed one can look the same.
    ///
    /// The refused context is then saved for real, the way the next autosave
    /// would, so what reaches the disk is whatever the rollback left behind —
    /// and a move only half taken back would land there. It also leaves no
    /// unsaved change behind for a later suite's background notification to
    /// try to commit into a directory this test has removed.
    @MainActor
    @Test("a refused move leaves the photograph where a fresh context finds it")
    func refusedRefileMatchesTheStore() async throws {
        let sandbox = Sandbox()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-refile-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("OpenHikes.store")
        let localURL = directory.appendingPathComponent("OpenHikesLocal.store")

        let hikeID: UUID
        let photoID: UUID
        do {
            let container = try ModelContainer.openHikes(url: storeURL, localURL: localURL)
            let context = ModelContext(container)
            let hike = Self.hikeWithAPlace(in: context)
            let photo = try #require(
                await HikePhotoImport.add(
                    Self.sampleImageData(),
                    to: hike,
                    coordinate: nil,
                    savesToPhotoLibrary: false,
                    assetLocalIdentifier: Refiling.asset,
                    store: sandbox.store
                )
            )
            let again = await HikePhotoImport.add(
                Self.sampleImageData(),
                to: hike,
                coordinate: nil,
                savesToPhotoLibrary: false,
                assetLocalIdentifier: Refiling.asset,
                placeID: Refiling.spring.id,
                store: sandbox.store,
                save: { _ in throw CocoaError(.fileWriteUnknown) }
            )
            #expect(again == nil)
            #expect(hike.photos.first?.placeID == nil, "what the screen shows")
            try context.save()
            hikeID = hike.id
            photoID = photo.id
        }

        let container = try ModelContainer.openHikes(url: storeURL, localURL: localURL)
        let reopened = try #require(
            try ModelContext(container).fetch(
                FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
            ).first
        )

        #expect(reopened.photos.map(\.id) == [photoID])
        #expect(reopened.photos.first?.placeID == nil, "what the next save and launch show")
    }
}
