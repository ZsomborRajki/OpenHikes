//
//  AutoSaveHoldTests.swift
//  OpenHikesTests
//
//  What keeps a hike's map deleted once the hiker has deleted it.
//
//  The hike is still selected after its saved map goes, and the switch in
//  Settings may still be on, so the stand-down is all that keeps the next
//  pan from saving it again. Several things announce the selection again
//  without changing it — a change of map on *Map Modes*, Settings' delete-all,
//  the hike's screen reading its line on the way back from a pushed screen —
//  and each of them used to arm the hike the deletion had just stood down.
//  `AutoSaveController.holdDown(_:)` keeps it down through all of them, until
//  the map selects a hike anew or the hiker moves the switch, which is asking
//  for auto-save.
//
//  `StoredTileDeletionTests` owns the deletion's ordering, and the hold's
//  plainest case: a deletion that lands, then a pan.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Auto-save after a hike's saved map is deleted")
struct AutoSaveHoldTests {
    /// A tile inside the ridge fixture's own corridor, so the auto-save
    /// store claims it the way it does in the app.
    nonisolated private static let corridorKey = "osm/14/2638/6357@2.0"
    nonisolated private static let corridorTile = (z: 14, x: 2638, y: 6357)

    private let sandbox = TileSandbox()
    private let context: ModelContext
    /// A registry of this suite's own: the deletion stands down every run in
    /// the one it is handed.
    private let downloads = OfflineDownloadRegistry()

    init() throws {
        context = try Fixture.modelContext()
    }

    private func deleteStoredTiles(
        of hike: Hike,
        among hikes: [Hike],
        with controller: AutoSaveController,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> StoredTileDeletion.Outcome {
        StoredTileDeletion.delete(
            storedTilesOf: hike,
            autoSave: controller,
            downloads: downloads,
            fetchingHikes: { hikes },
            save: save
        )
    }

    /// The pan the hold is there for: a tile around the trail, drawn.
    private func pan() async throws {
        try sandbox.browse(key: Self.corridorKey)
        let (store, tile) = (sandbox.store, Self.corridorTile)
        await offMain { store.considerPersisting(key: Self.corridorKey, z: tile.z, x: tile.x, y: tile.y) }
    }

    @Test("a deleted map stays unsaved through every announcement that is not a selection, until the switch moves")
    func holdOutlastsEveryReannouncement() async throws {
        nonisolated(unsafe) var isOn = true
        nonisolated(unsafe) var drawsTiles = true
        let controller = AutoSaveController(
            store: sandbox.store,
            drainInterval: nil,
            isSwitchedOn: { isOn },
            mapRendersTiles: { drawsTiles }
        )
        let hike = Fixture.hike(in: context)
        try context.save()
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()
        try #require(controller.isSaving(for: hike), "precondition: the hike is being saved for")

        guard case .committed = deleteStoredTiles(of: hike, among: [hike], with: controller) else {
            Issue.record("the deletion was refused")
            return
        }

        // Apple Maps on Map Modes, then a map drawn from tiles again.
        drawsTiles = false
        controller.reannounceSelection(hike)
        drawsTiles = true
        controller.reannounceSelection(hike)
        #expect(!controller.isSaving(for: hike), "a change of map is no selection")

        // `SettingsView.deleteAllTiles`, minus the SwiftUI.
        controller.beginStorageAction()
        controller.endStorageAction()
        #expect(!controller.isSaving(for: hike), "nor is a storage action")

        // The hike's screen, back from a pushed screen.
        controller.reannounceSelection(hike)
        #expect(!controller.isSaving(for: hike), "nor the hike's screen reading its line again")

        try await pan()
        #expect(!sandbox.isSaved(Self.corridorKey), "so the next pan saves nothing of the map just deleted")

        isOn = false
        controller.switchDidChange()
        isOn = true
        controller.switchDidChange()
        await controller.waitForActivation()
        #expect(controller.isSaving(for: hike), "turning the switch back on is the hiker asking for it again")
    }

    /// Held whether or not it was being saved for: on Apple's map at the
    /// deletion, a map drawn from tiles chosen a moment later must not save
    /// it either. And a deletion the store refused takes the hold back with
    /// it, or the hike would be kept from saving a map it still has.
    @Test("a hike not being saved for is held too, and a refusal lets it go")
    func refusalReleasesAHoldOnAnIdleHike() async throws {
        nonisolated(unsafe) var drawsTiles = false
        let controller = AutoSaveController(
            store: sandbox.store,
            drainInterval: nil,
            mapRendersTiles: { drawsTiles }
        )
        let hike = Fixture.hike(in: context)
        try context.save()
        controller.hikeSelectionChanged(to: hike)
        try #require(!controller.isSaving(for: hike), "precondition: the map draws no tiles")

        guard case .refused(.notSaved) = deleteStoredTiles(
            of: hike, among: [hike], with: controller, save: { _ in throw CocoaError(.fileWriteUnknown) }
        ) else {
            Issue.record("a save that threw must be reported as a refusal")
            return
        }
        drawsTiles = true
        controller.reannounceSelection(hike)
        await controller.waitForActivation()
        #expect(controller.isSaving(for: hike), "the hike keeps its map, so nothing holds it down")

        drawsTiles = false
        controller.reannounceSelection(hike)
        guard case .committed = deleteStoredTiles(of: hike, among: [hike], with: controller) else {
            Issue.record("the deletion was refused")
            return
        }
        drawsTiles = true
        controller.reannounceSelection(hike)
        #expect(!controller.isSaving(for: hike), "a deletion that lands holds it, whichever map is up")
    }

    /// Only the selected hike can be armed by an announcement, so only it is
    /// held, and deleting another hike's map leaves the selected one's hold
    /// where it was.
    @Test("deleting another hike's map leaves the selected hike's hold alone")
    func anotherHikesDeletionKeepsTheHold() async throws {
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        let selected = Fixture.hike(in: context, title: "Selected")
        let other = Fixture.hike(in: context, title: "Elsewhere", route: Fixture.loopRoute)
        try context.save()
        controller.hikeSelectionChanged(to: selected)
        await controller.waitForActivation()

        guard case .committed = deleteStoredTiles(of: selected, among: [selected, other], with: controller),
              case .committed = deleteStoredTiles(of: other, among: [selected, other], with: controller)
        else {
            Issue.record("a deletion was refused")
            return
        }
        controller.reannounceSelection(selected)
        #expect(!controller.isSaving(for: selected))
    }
}
