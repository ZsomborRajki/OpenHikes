//
//  AutoSaveRouteEditTests.swift
//  OpenHikesTests
//
//  Edit Route saves into the hike it edits, so the controller sees the same
//  hike ID announced again with a different line. Its corridor has to follow
//  that line — keyed on the ID alone, it kept the old one and refused every
//  tile around a moved or added section until the hike was selected again.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@Suite("Auto-save after a route edit")
struct AutoSaveRouteEditTests {
    private let sandbox = TileSandbox()
    private let context: ModelContext

    init() throws {
        context = try Fixture.modelContext()
    }

    /// The fixture's ridge moved about 11 km north — well clear of the
    /// original's 1.5 km corridor, so a tile on one line is outside the other.
    private static let movedRoute = Fixture.ridgeRoute.map { point in
        var moved = point
        moved.latitude += 0.1
        return moved
    }

    private func makeController() -> AutoSaveController {
        AutoSaveController(store: sandbox.store, drainInterval: nil)
    }

    /// Offers one browsed tile on `point` to the store, through the
    /// tile-thread path.
    private func persist(key: String, on point: RouteCoordinate, z: Int = 17) async throws {
        let x = SlippyTileMath.tileX(point.longitude, z: z)
        let y = SlippyTileMath.tileY(point.latitude, z: z)
        try sandbox.browse(key: key)
        await offMain { sandbox.store.considerPersisting(key: key, z: z, x: x, y: y) }
    }

    @Test("a tile on the edited line is saved without selecting the hike again")
    func editedRouteMovesTheCorridor() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        hike.route = Self.movedRoute
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let newKey = "autosave-route-edit/17/new@2.0"
        try await persist(key: newKey, on: Self.movedRoute[2])
        let oldKey = "autosave-route-edit/17/old@2.0"
        try await persist(key: oldKey, on: Fixture.ridgeRoute[2])

        controller.flushPendingKeys()
        #expect(hike.autoSavedTileKeys == [newKey], "only the edited line's corridor should claim tiles")
    }

    /// The pending set is the only record of tiles saved since the last
    /// drain, and they are already on disk. Re-preparing the corridor must not
    /// replace the store's ownership state the way selecting another hike does.
    @Test("tiles saved before the edit stay the hike's own")
    func editKeepsPendingOwnership() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let savedKey = "autosave-route-edit/17/before@2.0"
        try await persist(key: savedKey, on: Fixture.ridgeRoute[2])

        hike.route = Self.movedRoute
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        controller.flushPendingKeys()
        #expect(hike.autoSavedTileKeys == [savedKey])
    }

    /// Hike detail re-announces its hike every time its route task restarts,
    /// coming back from a pushed screen included. With the line unchanged that
    /// must stay a no-op: rebuilding would empty the corridor until the build
    /// landed, refusing tiles drawn in the meantime.
    @Test("re-announcing an unchanged route keeps the corridor in place")
    func unchangedRouteIsNotRebuilt() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        controller.hikeSelectionChanged(to: hike)

        let key = "autosave-route-edit/17/same@2.0"
        try await persist(key: key, on: Fixture.ridgeRoute[2])
        controller.flushPendingKeys()
        #expect(hike.autoSavedTileKeys == [key], "the prepared corridor should still be claiming")
    }

    /// A second edit landing before the first one's corridor is ready: only
    /// the newest line may end up in the store.
    @Test("an edit superseded before its corridor is ready is never installed")
    func supersededEditIsDiscarded() async throws {
        let controller = makeController()
        let hike = Fixture.hike(in: context)
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        hike.route = Self.movedRoute
        controller.hikeSelectionChanged(to: hike)
        hike.route = Fixture.ridgeRoute
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()

        let movedKey = "autosave-route-edit/17/superseded@2.0"
        try await persist(key: movedKey, on: Self.movedRoute[2])
        let currentKey = "autosave-route-edit/17/current@2.0"
        try await persist(key: currentKey, on: Fixture.ridgeRoute[2])

        controller.flushPendingKeys()
        #expect(hike.autoSavedTileKeys == [currentKey])
    }
}
