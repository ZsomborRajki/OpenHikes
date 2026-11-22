//
//  RefusedSaveScopeTests.swift
//  OpenHikesTests
//
//  A refused *Edit Route* save, or a refused deletion, takes back its own
//  change and nothing else.
//
//  Both are made in the shared main context, which autosaves: a rename, the
//  tile claims auto-save folds in, a drawing the maker could not commit — all
//  of it waits there for the next save. Each operation used to roll the whole
//  context back when its commit was refused, which took that work with it:
//  a rename gone, a hike inserted a moment earlier detached, a browsed hike's
//  newest tiles claimed by nothing. Now each commits what is already pending
//  first, so its rollback has only its own change to take.
//
//  And a refused edit writes back nothing its rollback has already taken
//  back: a column written again leaves the hike changed in the shared context,
//  for the next save to put over whatever another context saved since.
//
//  Every test runs twice. Once with every save refused — a full disk, which
//  refuses the operation and the rest alike, so the rest has to stay pending
//  for the save that lands once space is freed — and once with only the
//  operation's own commit refused, so the rollback has to stop at it. A later
//  save that succeeds, read back through a fresh context, is the evidence:
//  the hiker's work is on disk and the refused operation is not.
//
//  The context is the container's main one with autosave off, so nothing
//  commits behind the test's back.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import Testing

@MainActor
@Suite("A refused save takes back only its own change")
struct RefusedSaveScopeTests {
    private struct Refused: Error {}

    private enum Line {
        static let longitude: Double = 12.86
        static let south: Double = 47.6300
        static let middle: Double = 47.6320
        static let north: Double = 47.6340
    }

    /// A tile inside the ridge fixture's own corridor, so the auto-save store
    /// claims it the way it does in the app.
    nonisolated private static let corridorTileKey = "osm/14/2638/6357@2.0-pending"
    nonisolated private static let corridorTile = (z: 14, x: 2638, y: 6357)

    /// A save seam refusing every commit, or only the ones `carriesOperation`
    /// recognises.
    private static func save(
        refusingEverySave refusesEverySave: Bool,
        orEach carriesOperation: @escaping (ModelContext) -> Bool
    ) -> (ModelContext) throws -> Void {
        { context in
            if refusesEverySave || carriesOperation(context) { throw Refused() }
            try context.save()
        }
    }

    private static func mainContext(of container: ModelContainer) -> ModelContext {
        let context = container.mainContext
        context.autosaveEnabled = false
        return context
    }

    /// The hiker's own work, left pending beside the operation: a rename of a
    /// saved hike, and a hike inserted and not yet committed.
    private struct PendingWork {
        let renamedID: UUID
        let inserted: Hike
        let insertedID: UUID

        init(beside renamed: Hike, in context: ModelContext) {
            renamedID = renamed.id
            renamed.customName = "Renamed meanwhile"
            inserted = Fixture.hike(in: context, title: "Added meanwhile")
            insertedID = inserted.id
        }

        /// Still in the context, and then on disk once a save lands.
        func expectKept(in context: ModelContext, hikesOnDisk: Int) throws {
            #expect(inserted.modelContext === context, "the inserted hike is still in the context")
            try context.save()
            let stored = try ModelContext(context.container).fetch(FetchDescriptor<Hike>())
            #expect(stored.count == hikesOnDisk)
            #expect(stored.first { $0.id == renamedID }?.customName == "Renamed meanwhile")
            #expect(stored.first { $0.id == insertedID }?.title == "Added meanwhile")
        }
    }

    // MARK: Edit Route

    @Test("a refused route edit keeps the hiker's other pending work", arguments: [true, false])
    func aRefusedEditKeepsPendingWork(refusesEverySave: Bool) throws {
        let container = try Fixture.modelContainer()
        let context = Self.mainContext(of: container)
        let hike = try Self.measuredTrail(in: context)
        let other = Fixture.hike(in: context, title: "Other hike")
        try context.save()
        let route = hike.route
        let pending = PendingWork(beside: other, in: context)

        let editedID = hike.id
        let outcome = RouteEditSave.write(
            try Self.middleThird(of: route),
            to: hike,
            replacing: route,
            in: context,
            save: Self.save(refusingEverySave: refusesEverySave) { context in
                context.changedModelsArray.contains { ($0 as? Hike)?.id == editedID }
            }
        )

        #expect(outcome == .refused(.notSaved))
        #expect(hike.route == route)
        #expect(hike.routeEditData == nil)
        #expect(other.customName == "Renamed meanwhile")
        try pending.expectKept(in: context, hikesOnDisk: 3)
        let stored = try #require(
            try ModelContext(container).fetch(FetchDescriptor<Hike>()).first { $0.id == editedID }
        )
        #expect(stored.route == route, "the refused edit is not what the later save writes")
        #expect(stored.routeEditData == nil)
    }

    // MARK: Deletion

    @Test("a refused deletion keeps the hiker's other pending work", arguments: [true, false])
    func aRefusedDeletionKeepsPendingWork(refusesEverySave: Bool) throws {
        let container = try Fixture.modelContainer()
        let context = Self.mainContext(of: container)
        let photos = HikePhotoImportTests.Sandbox()
        let doomed = Fixture.hike(in: context, title: "On its way out") { $0.listOrder = 1 }
        let other = Fixture.hike(in: context, title: "Other hike")
        try context.save()
        let pending = PendingWork(beside: other, in: context)

        let doomedID = doomed.id
        #expect(throws: Refused.self) {
            try HikeDeletion.delete(
                [doomed],
                store: photos.store,
                save: Self.save(refusingEverySave: refusesEverySave) { context in
                    context.deletedModelsArray.contains { ($0 as? Hike)?.id == doomedID }
                }
            )
        }

        #expect(doomed.isAttached)
        #expect(doomed.listOrder == 1, "and its sidecar with it")
        #expect(other.customName == "Renamed meanwhile")
        try pending.expectKept(in: context, hikesOnDisk: 3)
        let stored = try ModelContext(container).fetch(FetchDescriptor<Hike>())
        #expect(stored.first { $0.id == doomedID }?.listOrder == 1)
    }

    /// The cascade is what used to take a deleted hike's rows, and on the iOS
    /// 18 floor a rollback of a cascaded deletion crashed in SwiftData — a
    /// hike with a recorded walk was enough. Its walks and places now go by
    /// hand, and a refusal puts the hike's lists of them back.
    @Test("a refused deletion keeps the hike's walks and places", arguments: [true, false])
    func aRefusedDeletionKeepsTheHikesRows(refusesEverySave: Bool) throws {
        let container = try Fixture.modelContainer()
        let context = Self.mainContext(of: container)
        let photos = HikePhotoImportTests.Sandbox()
        let doomed = Fixture.hike(in: context, title: "Walked")
        doomed.addPlaces([TrailPlace(latitude: Line.middle, longitude: Line.longitude, name: "Spring")], in: context)
        let walk = HikeWalk(
            hikeID: doomed.id,
            startedAt: .now,
            endedAt: .now,
            activeSeconds: 60,
            coveredIntervals: [0, 10],
            furthestDistanceMeters: 10,
            routeDistanceMeters: 10,
            endReason: .ended
        )
        context.insert(walk)
        walk.hike = doomed
        let other = Fixture.hike(in: context, title: "Other hike")
        try context.save()
        let pending = PendingWork(beside: other, in: context)

        let doomedID = doomed.id
        #expect(throws: Refused.self) {
            try HikeDeletion.delete(
                [doomed],
                store: photos.store,
                save: Self.save(refusingEverySave: refusesEverySave) { context in
                    context.deletedModelsArray.contains { ($0 as? Hike)?.id == doomedID }
                }
            )
        }

        #expect(doomed.isAttached)
        #expect(doomed.walks?.count == 1)
        #expect(doomed.places.map(\.name) == ["Spring"])
        // A later save writes the hike again — the floor wrote its lists
        // empty — and the rows have to still be its own on disk.
        doomed.customName = "Kept"
        try pending.expectKept(in: context, hikesOnDisk: 3)
        let stored = try #require(
            try ModelContext(container).fetch(FetchDescriptor<Hike>()).first { $0.id == doomedID }
        )
        #expect(stored.walks?.count == 1)
        #expect(stored.places.map(\.name) == ["Spring"])
    }

    /// The swipe folds the browsed hike's last drain window into its manifest
    /// before it plans — see `HikeDeletionTests+Tiles` — and those keys are
    /// then nowhere else: a rollback that took the fold back left durable
    /// tiles claimed by nothing, for the next launch trim to delete.
    @Test("a refused deletion keeps the tile the browsed hike has only just saved", arguments: [true, false])
    func aRefusedDeletionKeepsTheSurvivorsNewestTile(refusesEverySave: Bool) async throws {
        let container = try Fixture.modelContainer()
        let context = Self.mainContext(of: container)
        let sandbox = TileSandbox()
        let photos = HikePhotoImportTests.Sandbox()
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        let doomed = Fixture.hike(in: context, title: "On its way out")
        let survivor = Fixture.hike(in: context, title: "Being browsed")
        try context.save()
        controller.hikeSelectionChanged(to: survivor)
        await controller.waitForActivation()
        try sandbox.browse(key: Self.corridorTileKey)
        let store = sandbox.store
        await offMain {
            store.considerPersisting(
                key: Self.corridorTileKey,
                z: Self.corridorTile.z,
                x: Self.corridorTile.x,
                y: Self.corridorTile.y
            )
        }
        try #require(sandbox.isSaved(Self.corridorTileKey), "precondition: the tile is durable")
        try #require(survivor.autoSavedTileKeys.isEmpty, "precondition: claimed only by the pending set")

        let doomedID = doomed.id
        let outcome = HikeDeletion.delete(
            doomed,
            among: [doomed, survivor],
            autoSave: controller,
            store: photos.store,
            save: Self.save(refusingEverySave: refusesEverySave) { context in
                context.deletedModelsArray.contains { ($0 as? Hike)?.id == doomedID }
            }
        )

        guard case .refused = outcome else {
            Issue.record("a save that threw must be reported as a refusal")
            return
        }
        #expect(survivor.autoSavedTileKeys == [Self.corridorTileKey])
        try context.save()
        let survivorID = survivor.id
        let stored = try #require(
            try ModelContext(container).fetch(FetchDescriptor<Hike>()).first { $0.id == survivorID }
        )
        #expect(stored.autoSavedTileKeys == [Self.corridorTileKey])
    }

    /// The other side of committing first: the doomed hike's own fold is now
    /// on disk before the deletion is tried, so the rollback brings it back
    /// with the sidecar, and putting auto-save back must not add it twice.
    @Test("a refused deletion gives the auto-saving hike its claim back once", arguments: [true, false])
    func aRefusedDeletionRestoresTheClaimOnce(refusesEverySave: Bool) async throws {
        let container = try Fixture.modelContainer()
        let context = Self.mainContext(of: container)
        let sandbox = TileSandbox()
        let photos = HikePhotoImportTests.Sandbox()
        let controller = AutoSaveController(store: sandbox.store, drainInterval: nil)
        let hike = Fixture.hike(in: context)
        try context.save()
        controller.hikeSelectionChanged(to: hike)
        await controller.waitForActivation()
        try sandbox.browse(key: Self.corridorTileKey)
        let store = sandbox.store
        await offMain {
            store.considerPersisting(
                key: Self.corridorTileKey,
                z: Self.corridorTile.z,
                x: Self.corridorTile.x,
                y: Self.corridorTile.y
            )
        }
        try #require(hike.autoSavedTileKeys.isEmpty, "precondition: claimed only by the pending set")

        let hikeID = hike.id
        let outcome = HikeDeletion.delete(
            hike,
            among: [hike],
            autoSave: controller,
            store: photos.store,
            save: Self.save(refusingEverySave: refusesEverySave) { context in
                context.deletedModelsArray.contains { ($0 as? Hike)?.id == hikeID }
            }
        )

        guard case .refused = outcome else {
            Issue.record("a save that threw must be reported as a refusal")
            return
        }
        #expect(hike.autoSavedTileKeys == [Self.corridorTileKey])
        #expect(controller.currentHike?.id == hike.id)
        // And once on disk, after the save that lands next.
        try context.save()
        let stored = try #require(
            try ModelContext(container).fetch(FetchDescriptor<Hike>()).first { $0.id == hikeID }
        )
        #expect(stored.autoSavedTileKeys == [Self.corridorTileKey])
    }
}

// MARK: - What a refused edit leaves pending

extension RefusedSaveScopeTests {
    /// What the trail is measured with before the edit: the length both
    /// breakdowns give their one category, and the cached climb and descent.
    nonisolated private static let measuredMeters: Double = 400
    nonisolated private static let measuredClimb: Double = 120
    nonisolated private static let measuredDescent: Double = 80

    /// The rollback takes back what it can, and the refused edit writes back
    /// only what it left. iOS 27.0 takes every column back, which leaves the
    /// edit nothing to write. Written back anyway, a column left the hike
    /// changed in the shared context — `@Model` filters no same-value write —
    /// and that context's next save put the pre-edit figures over ones
    /// another context had saved since, as the hiker's other device would.
    /// The iOS 18 floor takes no column back, and there every one is written
    /// back by hand.
    @Test("a refused route edit writes back only what its rollback left", arguments: [true, false])
    func aRefusedEditWritesBackOnlyWhatTheRollbackLeft(refusesEverySave: Bool) throws {
        let container = try Fixture.modelContainer()
        let context = Self.mainContext(of: container)
        let hike = try Self.measuredTrail(in: context)
        let before = EditedColumns(hike)

        let editedID = hike.id
        let outcome = RouteEditSave.write(
            try Self.middleThird(of: hike.route),
            to: hike,
            replacing: hike.route,
            in: context,
            save: Self.save(refusingEverySave: refusesEverySave) { context in
                context.changedModelsArray.contains { ($0 as? Hike)?.id == editedID }
            }
        )

        #expect(outcome == .refused(.notSaved))
        #expect(EditedColumns(hike) == before, "every column is back")
        // On the floor nothing was taken back, so everything had to be written.
        guard try Self.rollbackTakesBackWrites() else { return }
        #expect(!hike.hasChanges, "nothing the rollback took back is written again")
        #expect(hike.localState?.hasChanges == false, "nor in the hike's sidecar")

        let elsewhere = ModelContext(container)
        let copy = try #require(try elsewhere.fetch(FetchDescriptor<Hike>()).first { $0.id == editedID })
        copy.surfaceMetersByCategory = ["gravel": Self.measuredMeters]
        try elsewhere.save()
        _ = Fixture.hike(in: context, title: "Added meanwhile")
        try context.save()
        let stored = try #require(
            try ModelContext(container).fetch(FetchDescriptor<Hike>()).first { $0.id == editedID }
        )
        #expect(
            stored.surfaceMetersByCategory == ["gravel": Self.measuredMeters],
            "the breakdown measured elsewhere is not written over"
        )
    }

    /// A trail drawn in the maker — edited in *Edit Route* like any other
    /// line — with every column an edit writes filled in: both breakdowns and
    /// a cached climb, beside a place with a photograph filed under it that
    /// the edit must not touch. Saved, so a refused edit has all of it to put
    /// back.
    private static func measuredTrail(in context: ModelContext) throws -> Hike {
        let draft = TrailDraft()
        draft.append(CLLocationCoordinate2D(latitude: Line.south, longitude: Line.longitude))
        draft.append(CLLocationCoordinate2D(latitude: Line.north, longitude: Line.longitude))
        let spring = TrailPlace(latitude: Line.middle, longitude: Line.longitude, name: "Spring")
        draft.addPlaces([spring])
        let hike = try #require(TrailDraftSave.hike(from: draft, named: "Ridge", into: context).hike)
        var photo = HikePhoto()
        photo.placeID = spring.id
        hike.addPhoto(photo)
        hike.surfaceMetersByCategory = ["paved": Self.measuredMeters]
        hike.difficultyMetersByGrade = ["hiking": Self.measuredMeters]
        hike.climbMeters = Self.measuredClimb
        hike.descentMeters = Self.measuredDescent
        hike.elevationRouteRevision = "measured-route"
        try context.save()
        return hike
    }

    /// `route` cut to its middle third: an edit that writes the line, its
    /// length, the original and the edit record, and empties what was
    /// measured along the old line.
    private static func middleThird(of route: [RouteCoordinate]) throws -> EditedLine {
        let distances = RouteTrim.distances(along: route)
        let length = try #require(distances.last)
        return try #require(EditedLine(
            whole: route,
            distances: distances,
            cuts: EditedLine.Cuts(range: length / 3...length * 2 / 3),
            replacing: route
        ))
    }

    /// Whether a rollback on this OS takes back what was written over saved
    /// rows: a column, and a list of rows. Measured on iOS 27.0 it takes back
    /// both, and on 18.6, the iOS 18 floor, neither.
    private static func rollbackTakesBackWrites() throws -> Bool {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        hike.addPlaces([TrailPlace(latitude: Line.middle, longitude: Line.longitude, name: "Spring")], in: context)
        try context.save()
        hike.customName = "Written"
        hike.trailPoints = []
        context.rollback()
        return hike.customName == nil && hike.places.count == 1
    }
}

/// Every column a route edit writes, and the hike's places and photographs,
/// which it must leave alone, as one value to hold before and after a
/// refusal.
private struct EditedColumns: Equatable {
    let route: [RouteCoordinate]
    let original: [RouteCoordinate]
    let edit: Data?
    let duration: Double?
    let distance: Double
    let date: Date
    let surface: [String: Double]
    let difficulty: [String: Double]
    let photos: [HikePhoto]
    let places: [String]
    let climb: Double?
    let descent: Double?
    let elevationRevision: String?

    init(_ hike: Hike) {
        route = hike.route
        original = hike.originalRoute
        edit = hike.routeEditData
        duration = hike.durationSeconds
        distance = hike.distanceMeters
        date = hike.date
        surface = hike.surfaceMetersByCategory
        difficulty = hike.difficultyMetersByGrade
        photos = hike.photos
        places = hike.places.map(\.name)
        climb = hike.climbMeters
        descent = hike.descentMeters
        elevationRevision = hike.elevationRouteRevision
    }
}
