//
//  SelectedLineTests.swift
//  OpenHikesTests
//
//  The selected hike's line is read once, in a context of its own off the
//  main actor, and handed to the map's projection, its colours, auto-save's
//  corridor and the widget's snapshot alike (#1232). Each of the four used to
//  read `hike.route` on the main actor in the selection's change handler, and
//  the first of those reads decoded the whole externally stored route there.
//
//  That a reader was handed the store's line is asserted with a line the
//  store holds and the main context's hike does not: a sibling context's
//  save, which the main context's hike is never told of (see
//  `HikeListMetrics+Observation.swift`). The main context's copy is a single
//  point, so a reader that still read it there — or only counted its points
//  there — draws, colours, saves and publishes nothing. Where the read runs,
//  and how often, is asserted through its fetch seam, as
//  `PinnedTrailReadTests` asserts its own.
//
//  A member of the widget feeds because selecting a hike publishes its
//  snapshot to the App Group file they share.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import Synchronization
import Testing

extension WidgetFeedSuites {
@Suite("Selected line", .serialized)
final class SelectedLineTests {
    /// Which threads the store's fetch ran on, one entry per call — and,
    /// when it is given a stand-in, the row it answers with instead of the
    /// one asked for.
    nonisolated final class FetchLog: Sendable {
        private let threads = Mutex<[Bool]>([])
        private let standIn: PersistentIdentifier?

        init(answeringWith standIn: PersistentIdentifier? = nil) {
            self.standIn = standIn
        }

        var ranOnMainThread: [Bool] { threads.withLock { $0 } }

        func fetch(_ context: ModelContext, _ id: PersistentIdentifier) throws -> Hike? {
            threads.withLock { $0.append(Thread.isMainThread) }
            return try SelectedLine.fetchHike(context, standIn ?? id)
        }
    }

    /// The four things the selection handler hands the line to.
    private struct Readers {
        let cache: DisplayedRouteCoordinateCache
        let shading: RouteShading
        let autoSave: AutoSaveController
        let tracker: BackgroundTrailTracker
    }

    private let container: ModelContainer
    private let context: ModelContext
    private let defaults: UserDefaults
    private let sandbox = TileSandbox()
    private let reloads = WidgetReloadSpy()

    init() throws {
        container = try Fixture.modelContainer()
        context = ModelContext(container)
        defaults = try makeScratchDefaults()
        SharedStore.clear()
    }

    deinit {
        SharedStore.clear()
    }

    /// The ridge moved half a degree north — some 55 km, well clear of the
    /// original's 1.5 km auto-save corridor — with its heights, so it is
    /// coloured by steepness as the original is, somewhere else.
    private static let movedRoute = Fixture.ridgeRoute.map { point in
        var moved = point
        moved.latitude += 0.5
        return moved
    }

    private static func isOnMovedRoute(_ coordinate: CLLocationCoordinate2D?) -> Bool {
        (coordinate?.latitude ?? 0) > (Fixture.ridgeRoute.last?.latitude ?? 0) + 0.4
    }

    /// Where the widget's line starts.
    private static func start(of snapshot: SharedTrailSnapshot?) -> CLLocationCoordinate2D? {
        snapshot?.polyline.first.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private func readers(reading lines: SelectedLine) -> Readers {
        Readers(
            cache: DisplayedRouteCoordinateCache(),
            shading: RouteShading(provider: nil, defaults: defaults, lines: lines),
            autoSave: AutoSaveController(store: sandbox.store, drainInterval: nil, lines: lines),
            tracker: BackgroundTrailTracker(
                container: container,
                monitor: StubLocationMonitor(),
                defaults: defaults,
                widgetReload: reloads.reload,
                lines: lines
            )
        )
    }

    /// What `OpenHikesView`'s selection handler does with a finished hike,
    /// in its order, and then everything that has to land.
    private func select(_ hike: Hike, into readers: Readers, from lines: SelectedLine) async {
        readers.cache.prepare(for: hike, from: lines)
        readers.shading.follow(hike)
        readers.autoSave.hikeSelectionChanged(to: hike)
        readers.tracker.hikeSelectionChanged(to: hike)
        await readers.cache.preparation?.value
        await readers.shading.measurement?.value
        await readers.autoSave.waitForActivation()
        await readers.tracker.waitForSelectionPublish()
    }

    /// Whether a tile drawn on `point` is one auto-save claims for `hike`.
    private func claims(_ point: RouteCoordinate, for hike: Hike, key: String) async throws -> Bool {
        let z = 17
        let x = SlippyTileMath.tileX(point.longitude, z: z)
        let y = SlippyTileMath.tileY(point.latitude, z: z)
        try sandbox.browse(key: key)
        await offMain { sandbox.store.considerPersisting(key: key, z: z, x: x, y: y) }
        return sandbox.store.drainPendingKeys(for: hike.id).contains(key)
    }

    /// A saved hike of one point whose line the store has replaced behind
    /// the main context's back, which still holds the point decoded.
    private func hikeWhoseStoreMovedOn() throws -> Hike {
        let hike = Fixture.hike(in: context, route: Array(Fixture.ridgeRoute.prefix(1)))
        try context.save()
        #expect(hike.route.count == 1)
        let sibling = ModelContext(container)
        let id = hike.id
        let stored = try #require(try sibling.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first)
        stored.replaceRoute(with: Self.movedRoute)
        try sibling.save()
        return hike
    }

    /// The line each reader draws or measures is the store's, so none of them
    /// read it where the main context's copy was — the main actor.
    @Test("every reader of a selection is handed the line the store holds")
    func everyReaderIsHandedTheStoredLine() async throws {
        let hike = try hikeWhoseStoreMovedOn()
        try #require(
            hike.route.count == 1 && !hike.hasChanges,
            "the premise: the main context's hike was never told of the sibling's save"
        )
        let lines = SelectedLine()
        let readers = readers(reading: lines)

        await select(hike, into: readers, from: lines)

        #expect(Self.isOnMovedRoute(readers.cache.drawnRoute(for: hike)?.coordinates.first), "the drawn line")
        #expect(!readers.shading.stretches.isEmpty)
        #expect(
            readers.shading.stretches.allSatisfy { Self.isOnMovedRoute($0.coordinates.first) },
            "the colours"
        )
        let onMoved = try await claims(Self.movedRoute[2], for: hike, key: "selected-line/17/moved@2.0")
        let onOriginal = try await claims(Fixture.ridgeRoute[2], for: hike, key: "selected-line/17/original@2.0")
        #expect(onMoved && !onOriginal, "the corridor")
        #expect(Self.isOnMovedRoute(Self.start(of: SharedStore.load())), "the widget")
    }

    /// One fetch for four readers, and none of it on the main thread: the
    /// caller is the main actor itself, so a read on its caller's executor
    /// fails. The fetch answers with another row's line, which only a reader
    /// handed the shared read can draw, so a reader that read a copy of its
    /// own — on the main actor or off it — draws the hike's line and fails.
    @Test("one read, off the main thread, serves all four readers")
    func oneReadServesEveryReader() async throws {
        #expect(pthread_main_np() != 0, "the bug needs a main-actor caller to reproduce")
        let hike = Fixture.hike(in: context)
        let marker = Fixture.hike(in: context, title: "Marker", route: Self.movedRoute)
        try context.save()
        let log = FetchLog(answeringWith: marker.persistentModelID)
        let lines = SelectedLine(fetch: log.fetch)
        let readers = readers(reading: lines)

        await select(hike, into: readers, from: lines)

        #expect(log.ranOnMainThread == [false])
        #expect(Self.isOnMovedRoute(readers.cache.drawnRoute(for: hike)?.coordinates.first), "the drawn line")
        #expect(readers.shading.hikeID == hike.id && !readers.shading.stretches.isEmpty)
        #expect(readers.shading.stretches.allSatisfy { Self.isOnMovedRoute($0.coordinates.first) }, "the colours")
        #expect(try await claims(Self.movedRoute[2], for: hike, key: "selected-line/17/shared@2.0"), "the corridor")
        #expect(Self.isOnMovedRoute(Self.start(of: SharedStore.load())), "the widget")

        // Asked again with nothing written — *Color By* moved, another map
        // picked — the line is the one already read.
        readers.shading.setColoring(.difficulty)
        readers.shading.setColoring(.elevation)
        await readers.shading.measurement?.value
        readers.autoSave.hikeSelectionChanged(to: hike)
        await readers.autoSave.waitForActivation()
        #expect(log.ranOnMainThread == [false], "the same line is not read twice")
    }

    /// Another context sees only what was saved, so a hike the store has not
    /// had every edit of is read from the hike in hand: never saved, or saved
    /// and written since.
    @Test("a hike with edits its store has not had is read where it is")
    func anUnsavedLineIsReadInPlace() async throws {
        let log = FetchLog()
        let lines = SelectedLine(fetch: log.fetch)
        let neverSaved = Fixture.hike(in: context, title: "Never Saved", route: Self.movedRoute)
        #expect(await lines.read(of: neverSaved).route == Self.movedRoute)

        let edited = Fixture.hike(in: context, title: "Edited")
        try context.save()
        edited.replaceRoute(with: Self.movedRoute)
        #expect(edited.hasChanges)
        #expect(await lines.read(of: edited).route == Self.movedRoute, "the edit, not the store's line before it")
        #expect(log.ranOnMainThread.isEmpty)
    }

    /// *Edit Route* and heights filled onto a line write it and save at once,
    /// with no change of selection to announce it. Each of the four follows
    /// the line on its own, through the watch ``SelectedLine`` arms for it,
    /// and all four take the new line from one new read, off the main thread.
    @Test("a line written to the selected hike reaches all four readers from one new read")
    func aWrittenLineReachesEveryReader() async throws {
        let hike = Fixture.hike(in: context)
        try context.save()
        let log = FetchLog()
        let lines = SelectedLine(fetch: log.fetch)
        let readers = readers(reading: lines)
        await select(hike, into: readers, from: lines)
        let drawn = try #require(readers.cache.drawnRoute(for: hike))

        hike.replaceRoute(with: Self.movedRoute)
        try context.save()
        await settleDelegateHop(until: "the new line is drawn, coloured and on the widget") {
            Self.isOnMovedRoute(readers.cache.drawnRoute(for: hike)?.coordinates.first)
                && readers.shading.stretches.contains { Self.isOnMovedRoute($0.coordinates.first) }
                && Self.isOnMovedRoute(Self.start(of: SharedStore.load()))
        }
        await readers.tracker.waitForSelectionPublish()
        await readers.autoSave.waitForActivation()

        #expect(readers.cache.drawnRoute(for: hike)?.revision != drawn.revision)
        #expect(log.ranOnMainThread == [false, false], "the new line is read once, off the main thread")
        let onMoved = try await claims(Self.movedRoute[2], for: hike, key: "selected-line/17/edited@2.0")
        let onOriginal = try await claims(Fixture.ridgeRoute[2], for: hike, key: "selected-line/17/before@2.0")
        #expect(onMoved && !onOriginal, "the corridor follows the new line")
    }

    /// While the hikes list is up, every save of any hike tells every hike's
    /// line watch its line was written (#1228). A line written again as it
    /// was is the same thing, here: the widget and auto-save compare before
    /// they rebuild, so neither spends anything on it. Waited out through the
    /// widget's comparison and any publication it started.
    @Test("a line written again unchanged spends no widget reload and keeps the corridor")
    func anUnchangedLineCostsNothing() async throws {
        let hike = Fixture.hike(in: context)
        try context.save()
        let lines = SelectedLine()
        let readers = readers(reading: lines)
        await select(hike, into: readers, from: lines)
        let published = reloads.count
        let watched = try #require(readers.tracker.followedLine?.write)

        hike.replaceRoute(with: hike.route)
        try context.save()
        let kept = try await claims(Fixture.ridgeRoute[2], for: hike, key: "selected-line/17/unchanged@2.0")
        await settleDelegateHop(until: "the widget's watch hears the write") {
            readers.tracker.followedLine?.write !== watched
        }
        await readers.tracker.followedLine?.check?.value
        await readers.tracker.waitForSelectionPublish()

        #expect(kept, "the corridor stayed up for the same line")
        #expect(reloads.count == published, "the same line is not published again")
    }

    /// A line another context saved need not be told to this one, so the
    /// readers keep the line they have until something asks — which is what
    /// ``SelectedLine/refresh()`` is for (#1228). Asked when the store holds
    /// nothing new, it changes nothing: waited out by a write, whose landing
    /// must be the only new projection.
    @Test("a refresh hands a line another context saved to all four readers")
    func aRefreshDeliversAStoredLine() async throws {
        let hike = Fixture.hike(in: context)
        try context.save()
        let lines = SelectedLine()
        let readers = readers(reading: lines)
        await select(hike, into: readers, from: lines)
        let first = try #require(readers.cache.drawnRoute(for: hike))

        lines.refresh()
        await lines.refreshing?.value
        hike.replaceRoute(with: Fixture.loopRoute)
        try context.save()
        await settleDelegateHop(until: "the written line lands") {
            readers.cache.drawnRoute(for: hike)?.coordinates.count == Fixture.loopRoute.count
        }
        let written = try #require(readers.cache.drawnRoute(for: hike))
        #expect(written.revision == first.revision + 1, "a refresh that found nothing new projected nothing")

        let sibling = ModelContext(container)
        let id = hike.id
        let stored = try #require(try sibling.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first)
        stored.replaceRoute(with: Self.movedRoute)
        try sibling.save()
        lines.refresh()
        await lines.refreshing?.value
        await settleDelegateHop(until: "the store's line is drawn, coloured and on the widget") {
            Self.isOnMovedRoute(readers.cache.drawnRoute(for: hike)?.coordinates.first)
                && readers.shading.stretches.contains { Self.isOnMovedRoute($0.coordinates.first) }
                && Self.isOnMovedRoute(Self.start(of: SharedStore.load()))
        }
        await readers.tracker.waitForSelectionPublish()
        await readers.autoSave.waitForActivation()
        #expect(readers.shading.describesCurrentLine)
        #expect(try await claims(Self.movedRoute[2], for: hike, key: "selected-line/17/refreshed@2.0"))
    }

    /// A hike deleted through another context is still held by this one until
    /// it merges, and the store has nothing to read for it: nothing to draw,
    /// colour, save or publish.
    @Test("a hike the store no longer holds reads as an empty line")
    func aDeletedRowReadsAsNothing() async throws {
        let hike = Fixture.hike(in: context)
        try context.save()
        let sibling = ModelContext(container)
        let id = hike.id
        let stored = try #require(try sibling.fetch(FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })).first)
        sibling.delete(stored)
        try sibling.save()

        #expect(await SelectedLine().read(of: hike).route.isEmpty)
    }
}
}
