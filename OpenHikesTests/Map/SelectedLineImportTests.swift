//
//  SelectedLineImportTests.swift
//  OpenHikesTests
//
//  A line another device saved for the selected hike reaches all four of the
//  selection's readers (the map's projection, its colours, auto-save's
//  corridor and the widget) through the store watch. Nothing else saved
//  anywhere draws, colours, saves or publishes anything again (#1228).
//
//  Two configurations, because the app's is not the obvious one. With no
//  `@Query` up, nothing tells the main context of another context's save,
//  and before the watch the readers kept the old line until the selection
//  changed. With the hikes list's `@Query` up in a window, as the sheet
//  always has it, every save to the store refreshed every registered hike
//  and notified `route` on each. The readers watched `route`, so every rename
//  or tint saved anywhere made the selected line again: projected, measured
//  and compared. They now watch the line revision, which no refresh moves.
//
//  The import is a sibling context's save under the mirroring delegate's
//  author, as in `SelectedLineStoreWatchTests`. A member of the widget feeds
//  because selecting a hike publishes its snapshot to the App Group file
//  they share.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import OpenHikesShared
import SwiftData
import SwiftUI
import Synchronization
import Testing

extension WidgetFeedSuites {
@Suite("Selected line import", .serialized)
final class SelectedLineImportTests {
    /// How many times the selected line was fetched from the store: each one
    /// is a decode of the line.
    nonisolated final class FetchCount: Sendable {
        private let calls = Mutex(0)

        var count: Int { calls.withLock { $0 } }

        func fetch(_ context: ModelContext, _ id: PersistentIdentifier) throws -> Hike? {
            calls.withLock { $0 += 1 }
            return try SelectedLine.fetchHike(context, id)
        }
    }

    /// The four things the selection handler hands the line to, the line
    /// they share, and the watch that follows it in the store.
    private struct Selection {
        let lines: SelectedLine
        let fetches: FetchCount
        let cache: DisplayedRouteCoordinateCache
        let shading: RouteShading
        let autoSave: AutoSaveController
        let tracker: BackgroundTrailTracker
        let watch: SelectedLineStoreWatch
    }

    /// The hikes list's query, and nothing else: what keeps every hike in the
    /// main context refreshed in the app.
    private struct HikesListStandIn: View {
        @Query(sort: \Hike.date, order: .reverse) private var hikes: [Hike]

        var body: some View {
            Text(verbatim: "\(hikes.count)")
        }
    }

    private let container: ModelContainer
    private let defaults: UserDefaults
    private let sandbox = TileSandbox()
    private let reloads = WidgetReloadSpy()

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "selected-line-import/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try ModelContainer.openHikes(
            url: directory.appending(path: "OpenHikes.store"),
            localURL: directory.appending(path: "OpenHikesLocal.store")
        )
        container.mainContext.autosaveEnabled = false
        defaults = try makeScratchDefaults()
        defaults.set(RouteColoring.elevation.rawValue, forKey: SettingsKey.routeColoring)
        SharedStore.clear()
    }

    deinit {
        SharedStore.clear()
    }

    /// The ridge moved half a degree north, well clear of the original's
    /// auto-save corridor, with its heights, so it is coloured by steepness
    /// somewhere else.
    private static let movedRoute = Fixture.ridgeRoute.map { point in
        var moved = point
        moved.latitude += 0.5
        return moved
    }

    private static let movedLength = RouteProfile(route: movedRoute).totalDistanceMeters

    private static func isOnMovedRoute(_ coordinate: CLLocationCoordinate2D?) -> Bool {
        (coordinate?.latitude ?? 0) > (Fixture.ridgeRoute.last?.latitude ?? 0) + 0.4
    }

    private static func start(of snapshot: SharedTrailSnapshot?) -> CLLocationCoordinate2D? {
        snapshot?.polyline.first.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private func selection() -> Selection {
        let fetches = FetchCount()
        let lines = SelectedLine(fetch: fetches.fetch)
        return Selection(
            lines: lines,
            fetches: fetches,
            cache: DisplayedRouteCoordinateCache(),
            shading: RouteShading(provider: nil, defaults: defaults, lines: lines),
            autoSave: AutoSaveController(store: sandbox.store, drainInterval: nil, lines: lines),
            tracker: BackgroundTrailTracker(
                container: container,
                monitor: StubLocationMonitor(),
                defaults: defaults,
                widgetReload: reloads.reload,
                lines: lines
            ),
            watch: SelectedLineStoreWatch { [lines] in lines.refresh() }
        )
    }

    /// What `OpenHikesView`'s handler and `OpenHikesModel.selectedHikeDidChange`
    /// do with a finished hike, in their order, then everything that lands.
    private func select(_ hike: Hike, into selection: Selection) async throws {
        selection.cache.prepare(for: hike, from: selection.lines)
        selection.shading.follow(hike)
        selection.autoSave.hikeSelectionChanged(to: hike)
        selection.tracker.hikeSelectionChanged(to: hike)
        selection.watch.follow(hike, since: try #require(selection.lines.readBegan(for: hike)))
        await selection.cache.preparation?.value
        await selection.shading.measurement?.value
        await selection.autoSave.waitForActivation()
        await selection.tracker.waitForSelectionPublish()
    }

    /// Another device's line, and its length, saved as the mirroring import
    /// saves it.
    private func saveMovedLineElsewhere(onto hike: Hike) async throws {
        let length = Self.movedLength
        let moved = Self.movedRoute
        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: container) { stored in
            stored.replaceRoute(with: moved)
            stored.distanceMeters = length
        }
    }

    private func claims(_ point: RouteCoordinate, for hike: Hike, key: String) async throws -> Bool {
        let z = 17
        let x = SlippyTileMath.tileX(point.longitude, z: z)
        let y = SlippyTileMath.tileY(point.latitude, z: z)
        try sandbox.browse(key: key)
        await offMain { sandbox.store.considerPersisting(key: key, z: z, x: x, y: y) }
        return sandbox.store.drainPendingKeys(for: hike.id).contains(key)
    }

    /// Hosts the hikes list's query in a window, as the sheet does, and lets
    /// it draw once.
    private func hostHikesList() async throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
            "app-hosted tests run inside the app, which has a scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: HikesListStandIn().modelContainer(container))
        window.isHidden = false
        window.layoutIfNeeded()
        await settleDelegateHop()
        return window
    }

    @Test("a line another device saved is drawn, coloured, saved and published, with no list up")
    func aLineSavedElsewhereReachesEveryReader() async throws {
        let hike = Fixture.hike(in: container.mainContext)
        try await RemoteChangeLog.save(container.mainContext, settling: hike)
        let selection = selection()
        try await select(hike, into: selection)

        try await saveMovedLineElsewhere(onto: hike)
        await settleDelegateHop(until: "the stored line is drawn, coloured and on the widget") {
            Self.isOnMovedRoute(selection.cache.drawnRoute(for: hike)?.coordinates.first)
                && selection.shading.stretches.contains { Self.isOnMovedRoute($0.coordinates.first) }
                && Self.isOnMovedRoute(Self.start(of: SharedStore.load()))
        }
        await selection.tracker.waitForSelectionPublish()
        await selection.autoSave.waitForActivation()

        #expect(selection.shading.describesCurrentLine)
        #expect(try await claims(Self.movedRoute[2], for: hike, key: "selected-line-import/17/moved@2.0"))
        #expect(SharedStore.load()?.totalDistanceMeters == Self.movedLength)
        #expect(hike.route == Self.movedRoute, "the main context's copy holds it too")
    }

    @Test("with the hikes list up, a rename or another hike's save draws, colours, saves and publishes nothing")
    func theHikesListUpRedrawsOnlyANewLine() async throws {
        let hike = Fixture.hike(in: container.mainContext, title: "Selected")
        let neighbor = Fixture.hike(in: container.mainContext, title: "Neighbor", route: Fixture.loopRoute)
        try await RemoteChangeLog.save(container.mainContext, settling: hike)
        let window = try await hostHikesList()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let selection = selection()
        try await select(hike, into: selection)
        let drawn = try #require(selection.cache.drawnRoute(for: hike))
        let shadingRevision = selection.shading.revision
        let published = reloads.count
        let fetched = selection.fetches.count

        neighbor.tintHex = "#FF00FF"
        try await RemoteChangeLog.save(container.mainContext, settling: neighbor)
        await settleDelegateHop(until: "the watch has checked the neighbor's save") {
            selection.watch.completedChecks > 0 && selection.watch.isSettled
        }
        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: container) { $0.title = "Renamed elsewhere" }
        await settleDelegateHop(until: "the watch has checked the rename") {
            selection.watch.completedChecks > 1 && selection.watch.isSettled
        }
        await selection.lines.refreshing?.value
        await settleDelegateHop()

        #expect(selection.cache.drawnRoute(for: hike)?.revision == drawn.revision, "projected nothing again")
        #expect(selection.shading.revision == shadingRevision, "measured nothing again")
        #expect(reloads.count == published, "published nothing again")
        #expect(selection.fetches.count == fetched + 1, "one look at the renamed hike's line, none for the neighbor")

        try await saveMovedLineElsewhere(onto: hike)
        await settleDelegateHop(until: "the new line is drawn") {
            Self.isOnMovedRoute(selection.cache.drawnRoute(for: hike)?.coordinates.first)
        }
        #expect(selection.cache.drawnRoute(for: hike)?.revision == drawn.revision + 1, "and drawn once")
    }

    /// A stored difficulty breakdown says whether a line has grades worth
    /// colouring, and *Color By* reads it from the hike's own copy beside the
    /// line it reads from the store. A line another device saved comes with
    /// that device's breakdown, and the two are read from the same save: the
    /// watch refreshes the hike's copy before the line is looked at.
    @Test("a line saved elsewhere is coloured by the difficulty breakdown saved with it")
    func aReceivedLineIsColoredByItsOwnBreakdown() async throws {
        let url = try #require(Bundle.main.url(forResource: UITestTrailTagFixture.gpxName, withExtension: "gpx"))
        let route = try GPXImport.load(from: url).route
        let provider = try #require(BundledTrailGraphProvider(fixtureName: UITestTrailTagFixture.trailGraphName))
        let hike = Fixture.hike(in: container.mainContext, route: route)
        try await RemoteChangeLog.save(container.mainContext, settling: hike)
        let byDifficulty = try makeScratchDefaults()
        byDifficulty.set(RouteColoring.difficulty.rawValue, forKey: SettingsKey.routeColoring)
        let lines = SelectedLine()
        let shading = RouteShading(provider: provider, defaults: byDifficulty, lines: lines)
        let watch = SelectedLineStoreWatch { lines.refresh() }
        shading.follow(hike)
        watch.follow(hike, since: try #require(lines.readBegan(for: hike)))
        await shading.measurement?.value
        #expect(!shading.stretches.isEmpty, "precondition: the fixture's trail is graded")
        let revision = shading.revision

        // Another device moved a height and measured the line again, and its
        // graph had no grade for it.
        var nudging = route
        nudging[0].elevation = (nudging[0].elevation ?? 0) + 1
        let nudged = nudging
        let meters = RouteProfile(route: nudged).totalDistanceMeters
        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: container) { stored in
            stored.replaceRoute(with: nudged)
            stored.difficultyMetersByGrade = [TrailDifficulty.unknown.rawValue: meters]
        }
        await settleDelegateHop(until: "the new line is measured") {
            shading.revision > revision && shading.describesCurrentLine && watch.isSettled
        }
        await shading.measurement?.value

        #expect(shading.stretches.isEmpty, "the stored breakdown has no grade, so nothing is coloured")
    }

    /// A selection made during a walk waits for the walk to end. A line saved
    /// elsewhere for that selection meanwhile is not a selection either: the
    /// widget keeps the walk, then takes the new selection with its new line.
    @Test("a line saved elsewhere during a walk leaves the widget to the walk until it ends")
    func aWalkKeepsTheWidgetUntilItEnds() async throws {
        let walked = Fixture.hike(in: container.mainContext, title: "Walked", route: Fixture.loopRoute)
        let next = Fixture.hike(in: container.mainContext, title: "Next")
        try await RemoteChangeLog.save(container.mainContext, settling: next)
        let selection = selection()
        try await select(walked, into: selection)
        selection.tracker.walkDidStart(hikeID: walked.id)
        try await select(next, into: selection)

        try await saveMovedLineElsewhere(onto: next)
        await settleDelegateHop(until: "the new line is drawn on the map") {
            Self.isOnMovedRoute(selection.cache.drawnRoute(for: next)?.coordinates.first)
        }
        await selection.tracker.followedLine?.check?.value
        #expect(SharedStore.load()?.hikeID == walked.id, "the widget is the walk's until it ends")

        selection.tracker.walkDidEnd(final: nil)
        await settleDelegateHop(until: "the selection made during the walk is applied") {
            selection.tracker.trackedHikeID == next.id
        }
        await selection.tracker.waitForSelectionPublish()
        #expect(SharedStore.load()?.hikeID == next.id)
        #expect(Self.isOnMovedRoute(Self.start(of: SharedStore.load())))
    }

    /// A selection made while the scene is away waits in auto-save for the
    /// scene to come back. A line saved elsewhere for it meanwhile must not
    /// put the hike being left back in its place.
    @Test("a line saved elsewhere while the scene is away leaves auto-save's waiting selection to it")
    func theSceneAwayKeepsAutoSavesWaitingSelection() async throws {
        let left = Fixture.hike(in: container.mainContext, title: "Left", route: Fixture.loopRoute)
        let next = Fixture.hike(in: container.mainContext, title: "Next")
        try await RemoteChangeLog.save(container.mainContext, settling: next)
        let selection = selection()
        try await select(left, into: selection)
        selection.autoSave.sceneWillResignActive { /* nothing pending to save */ }
        selection.cache.prepare(for: next, from: selection.lines)
        selection.shading.follow(next)
        selection.autoSave.hikeSelectionChanged(to: next)
        selection.watch.follow(next, since: try #require(selection.lines.readBegan(for: next)))

        try await saveMovedLineElsewhere(onto: next)
        await settleDelegateHop(until: "the new line is drawn on the map") {
            Self.isOnMovedRoute(selection.cache.drawnRoute(for: next)?.coordinates.first)
        }
        await selection.lines.refreshing?.value
        await settleDelegateHop()
        selection.autoSave.sceneDidBecomeActive()
        await selection.autoSave.waitForActivation()

        #expect(selection.autoSave.currentHike?.id == next.id)
        #expect(try await claims(Self.movedRoute[2], for: next, key: "selected-line-import/17/waiting@2.0"))
    }
}
}
