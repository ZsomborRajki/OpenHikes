//
//  AutoSaveControllerTests.swift
//  OpenHikesTests
//
//  "Auto-save controller", split out of AutoSaveTileTests.swift so that a
//  file declares one @Suite. That file's header still holds the context the
//  two share.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Auto-save controller")
struct AutoSaveControllerTests {
    private let sandbox = TileSandbox()
    private let context: ModelContext

    init() throws {
        context = try Fixture.modelContext()
    }

    private func makeController() -> AutoSaveController {
        AutoSaveController(store: sandbox.store, drainInterval: nil)
    }

    /// A hike whose manifest is already full. Activation seeds the store from
    /// that manifest, so "is the cap reached for this hike?" doubles as an
    /// observable answer to "did the controller actually activate it?".
    private func fullHike(configure: (Hike) -> Void = { _ in /* no-op */ }) -> Hike {
        Fixture.hike(in: context) { hike in
            hike.autoSavedTileKeys = (0..<AutoSaveTileStore.tileCap).map { "saved/\($0)" }
            configure(hike)
        }
    }

    /// Saves one tile against the active hike through the tile-thread path.
    private func persist(key: String, near hike: Hike, z: Int = 17) async throws {
        let anchor = hike.coordinates[2]
        let x = SlippyTileMath.tileX(anchor.longitude, z: z)
        let y = SlippyTileMath.tileY(anchor.latitude, z: z)
        try sandbox.browse(key: key)
        await offMain { sandbox.store.considerPersisting(key: key, z: z, x: x, y: y) }
    }

    @Test("selecting a hike makes it the one being saved for")
    func selectionActivates() {
        let controller = makeController()
        let hike = fullHike()
        controller.hikeSelectionChanged(to: hike)
        #expect(controller.isCapReached(for: hike), "the store should be active, seeded from this hike's manifest")
    }

    @Test("deselecting stops saving")
    func deselectionDeactivates() {
        let controller = makeController()
        let hike = fullHike()
        controller.hikeSelectionChanged(to: hike)
        controller.hikeSelectionChanged(to: nil)
        #expect(!controller.isCapReached(for: hike), "nothing should be active once the selection is cleared")
    }

    @Test("selecting another hike hands auto-save over to it")
    func selectionFollowsTheMap() {
        let controller = makeController()
        let first = fullHike()
        let second = Fixture.hike(in: context, title: "Second")
        controller.hikeSelectionChanged(to: first)
        controller.hikeSelectionChanged(to: second)
        #expect(!controller.isCapReached(for: first), "the previous hike is no longer the active one")
    }

    /// With *Auto-Save Tiles* off, which is how it starts, a hike is browsed
    /// like any map; nothing is saved for it.
    @Test("no hike is activated while the switch is off")
    func switchedOffNeverActivates() {
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil, isSwitchedOn: { false })
        let hike = fullHike()
        controller.hikeSelectionChanged(to: hike)
        #expect(controller.currentHike == nil)
        #expect(!controller.isSaving(for: hike))
        #expect(!controller.isCapReached(for: hike))
    }

    /// The switch is off until the hiker turns it on. A hike's screen once
    /// carried it, on for every hike, when browsing was the only way the
    /// default map could be kept.
    @Test("the switch starts off, and is read from the defaults Settings writes it to")
    func switchStartsOff() throws {
        let suite = "AutoSaveControllerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!AutoSaveController.isSwitchedOn(in: defaults), "nothing is saved for until the hiker asks")
        defaults.set(true, forKey: SettingsKey.autoSaveTilesEnabled)
        #expect(AutoSaveController.isSwitchedOn(in: defaults))
    }

    /// A one-point hike has no corridor worth speaking of. Its points are
    /// counted once its line has been read, off the main actor, rather than
    /// as it is selected: counting them there decoded the whole route on the
    /// main thread (#1232).
    @Test("a hike with fewer than two points is let go once its line is read")
    func degenerateHikeIsNotActivated() async {
        let controller = makeController()
        let hike = Fixture.hike(
            in: context,
            route: [RouteCoordinate(latitude: 47.63, longitude: 12.86)]
        ) { $0.autoSavedTileKeys = (0..<AutoSaveTileStore.tileCap).map { "saved/\($0)" } }
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()
        #expect(controller.currentHike == nil)
        #expect(!controller.isCapReached(for: hike))
    }

    /// The switch is in Settings, with the selected hike's map under the
    /// sheet, so it has to take effect there and then: nothing else announces
    /// the selection again until the hiker picks another hike.
    @Test("the switch starts and stops saving for the hike already selected")
    func switchArmsTheSelectedHike() {
        nonisolated(unsafe) var isOn = false
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil, isSwitchedOn: { isOn })
        let hike = fullHike()
        controller.hikeSelectionChanged(to: hike)
        #expect(controller.currentHike == nil)

        isOn = true
        controller.switchDidChange()
        #expect(controller.isSaving(for: hike))
        #expect(controller.isCapReached(for: hike), "turning it on should arm the store from this hike's manifest")

        isOn = false
        controller.switchDidChange()
        #expect(!controller.isSaving(for: hike))
        #expect(!controller.isCapReached(for: hike), "turning it off should stop the store tracking this hike")
    }

    /// With nothing selected the switch has nothing to arm, and a hike
    /// deleted since it was announced is not read again.
    @Test("the switch arms nothing when no hike is selected, or the selected one is gone")
    func switchArmsNothingWithoutAHike() throws {
        nonisolated(unsafe) var isOn = false
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil, isSwitchedOn: { isOn })
        isOn = true
        controller.switchDidChange()
        #expect(controller.currentHike == nil)

        isOn = false
        let hike = fullHike()
        try context.save()
        controller.hikeSelectionChanged(to: hike)
        context.delete(hike)
        try context.save()
        isOn = true
        controller.switchDidChange()
        #expect(controller.currentHike == nil)
    }

    /// The system base map draws no tiles, so there is nothing to auto-save
    /// for. Activating anyway would build a route-sized corridor and hold a
    /// live store entry for a hike that can never claim a tile — which is
    /// precisely the work that option exists to avoid. The refusal lives in
    /// the controller rather than only where the toggle is drawn, for the same
    /// reason ``OfflineTileDownloader`` refuses a download it isn't offered.
    @Test("no hike is activated while the map draws no tiles")
    func systemBaseMapNeverActivates() {
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil) { false }
        let hike = fullHike()

        controller.hikeSelectionChanged(to: hike)
        #expect(controller.currentHike == nil)
        #expect(!controller.isCapReached(for: hike))
    }

    /// The switch is the hiker's to set whatever map is up; it just doesn't
    /// start anything while nothing is being drawn.
    @Test("the switch going on arms nothing while the map draws no tiles")
    func systemBaseMapIgnoresTheSwitch() {
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil) { false }
        let hike = fullHike()
        controller.hikeSelectionChanged(to: hike)

        controller.switchDidChange()
        #expect(controller.currentHike == nil, "nothing is armed for a map that fetches nothing")
        #expect(controller.selectedHike?.id == hike.id, "and the selection is still known for when one does")
    }

    /// Picking a tile source again has to arm auto-save for whatever is
    /// already selected — `OpenHikesView` re-announces the selection through
    /// ``OpenHikesModel/tileProviderDidChange(selectedHike:)`` for this.
    @Test("re-announcing the selection arms auto-save once the map draws tiles again")
    func selectionIsRearmedWhenTilesReturn() {
        nonisolated(unsafe) var rendersTiles = false
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil) { rendersTiles }
        let hike = fullHike()

        controller.hikeSelectionChanged(to: hike)
        #expect(controller.currentHike == nil)

        rendersTiles = true
        controller.hikeSelectionChanged(to: hike)
        #expect(controller.currentHike?.id == hike.id)
        #expect(controller.isCapReached(for: hike))
    }

    @Test("a long route's corridor is prepared before it accepts tiles")
    func longRouteActivationCompletesOffMain() async throws {
        let route = (0..<18_000).map { index in
            RouteCoordinate(
                latitude: 47.63 + Double(index) * 0.000001,
                longitude: 12.86
            )
        }
        let controller = makeController()
        let hike = Fixture.hike(in: context, route: route)

        controller.hikeSelectionChanged(to: hike)
        #expect(controller.currentHike?.id == hike.id)
        await controller.waitForActivation()

        let key = "autosave-long-route/17/1/1@2.0"
        try await persist(key: key, near: hike)
        controller.flushPendingKeys()
        #expect(hike.autoSavedTileKeys == [key])
    }

    /// The drain is what turns "saved on disk" into "recorded on the hike".
    /// Until it runs the tiles exist with nothing pointing at them, which is
    /// why the delete path flushes before it reads any manifest.
    @Test("draining folds newly saved keys into the hike's manifest")
    func flushMergesKeys() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let anchor = hike.coordinates[2]
        let z = 17
        let x = SlippyTileMath.tileX(anchor.longitude, z: z)
        let keys = ["autosave-test/\(z)/\(x)/a@2.0", "autosave-test/\(z)/\(x)/b@2.0"]
        for key in keys { try await persist(key: key, near: hike) }

        controller.flushPendingKeys()
        #expect(Set(hike.autoSavedTileKeys) == Set(keys))

        // A second drain has nothing left to add — no duplicates in the manifest.
        controller.flushPendingKeys()
        #expect(hike.autoSavedTileKeys.count == keys.count)
    }

    @Test("a failed suspension save keeps ownership pending for retry")
    func failedSuspensionSaveKeepsPendingKeys() async throws {
        struct SaveFailure: Error {}

        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let key = "autosave-suspension-test/17/1/1@2.0"
        try await persist(key: key, near: hike)

        controller.sceneWillResignActive { throw SaveFailure() }
        #expect(hike.autoSavedTileKeys.isEmpty, "a failed save must roll back the in-memory manifest update")
        #expect(
            sandbox.store.suspendAndSnapshotPendingKeys(for: hike.id) == [key],
            "ownership must remain pending until persistence succeeds"
        )

        controller.sceneDidBecomeActive()
        controller.flushPendingKeys()
        #expect(hike.autoSavedTileKeys == [key])
    }

    @Test("suspension saves ownership already folded into the model")
    func suspensionSavesPreviouslyDrainedOwnership() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        try await persist(key: "autosave-drained-test/17/1/1@2.0", near: hike)
        controller.flushPendingKeys()

        var saveWasCalled = false
        controller.sceneWillResignActive { saveWasCalled = true }
        #expect(saveWasCalled, "suspension must save even when the timer already drained every pending key")
    }

    @Test("selection changes during suspension preserve failed-save ownership")
    func suspendedSelectionChangePreservesPendingKeys() async throws {
        struct SaveFailure: Error {}

        let controller = makeController()
        let first = Fixture.hike(in: context)
        let second = Fixture.hike(in: context, title: "Second")
        controller.hikeSelectionChanged(to: first)
        await controller.waitForActivation()

        let key = "autosave-deferred-selection-test/17/1/1@2.0"
        try await persist(key: key, near: first)

        controller.sceneWillResignActive { throw SaveFailure() }
        controller.hikeSelectionChanged(to: second)
        #expect(
            sandbox.store.suspendAndSnapshotPendingKeys(for: first.id) == [key],
            "changing selection while suspended must not replace the store's retained ownership"
        )

        controller.sceneDidBecomeActive()
        #expect(first.autoSavedTileKeys == [key])
    }
}
