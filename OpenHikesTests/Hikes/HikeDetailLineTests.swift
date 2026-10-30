//
//  HikeDetailLineTests.swift
//  OpenHikesTests
//
//  The hike detail screen, hosted in a window, takes its line from the read
//  the map's readers share and decodes none of it on the main actor (#1252).
//  ``ShownLineTests`` holds the type it reads through; this holds the screen
//  to it.
//
//  Before, the screen keyed its work on the line itself, read in its body, and
//  half its sections read `hike.route` or counted its points there. The
//  hikes list's `@Query` refreshes every hike after every save to the store,
//  and a refreshed line decodes again on its next read, so each save decoded
//  the whole line on the main actor, about 24 ms for 20,000 points.
//
//  Two ways of seeing it. The screen draws the line the store holds while the
//  main context's copy is another save's (the divergence `SelectedLineTests`
//  uses), so it read none of it there. And a long line the screen has opened
//  on, and under the hikes list's query some saves have been through, is
//  still cold in the main context: decoding it then takes the whole decode,
//  over a hundred milliseconds for 100,000 points, where a read the screen had
//  made already would have left it a few microseconds. The bound is two
//  orders of magnitude under the one and two above the other.
//
//  The second holds from iOS 27. On iOS 18.6 a fetch into the main context
//  decodes the line whole as it brings the hike in, and so does every refresh
//  after a save: the hikes list's query does both for every hike, measured
//  with the screen out of the window, and the probe's stacks put the decode
//  in the query's own fetch. A line is never cold there, so the two tests that
//  time it run from iOS 27.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import SwiftUI
import Synchronization
import Testing

@MainActor
@Suite("Hike detail line", .serialized, .timeLimit(.minutes(2)))
final class HikeDetailLineTests {
    /// The hikes list's query, and nothing else: what keeps every hike in the
    /// main context refreshed in the app.
    private struct HikesListStandIn: View {
        @Query(sort: \Hike.date, order: .reverse) private var hikes: [Hike]

        var body: some View {
            Text(verbatim: "\(hikes.count)")
        }
    }

    /// The selection's fetch, which once armed holds the next call after it
    /// has read its row, until opened: the read of a new line kept out, as a
    /// long line or a busy store keeps it.
    nonisolated final class HeldFetch: Sendable {
        private let state = Mutex((isArmed: false, isHolding: false))
        private let release = DispatchSemaphore(value: 0)

        /// Whether the held call has read its row and is waiting.
        var isHolding: Bool { state.withLock { $0.isHolding } }

        func arm() { state.withLock { $0.isArmed = true } }

        func fetch(_ context: ModelContext, _ id: PersistentIdentifier) throws -> Hike? {
            let hike = try SelectedLine.fetchHike(context, id)
            let holds = state.withLock { state in
                defer { state.isArmed = false }
                return state.isArmed
            }
            guard holds else { return hike }
            _ = hike?.route
            state.withLock { $0.isHolding = true }
            release.wait()
            return hike
        }

        func open() { release.signal() }
    }

    let container: ModelContainer
    let model: OpenHikesModel
    let highlight = RouteHighlight()
    private let sandbox = TileSandbox()
    /// What the selection's reads fetch through, so one can be held.
    let lineFetches = HeldFetch()

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "hike-detail-line/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try ModelContainer.openHikes(
            url: directory.appending(path: "OpenHikes.store"),
            localURL: directory.appending(path: "OpenHikesLocal.store")
        )
        container.mainContext.autosaveEnabled = false
        let lines = SelectedLine(fetch: lineFetches.fetch)
        model = OpenHikesModel(
            container: container,
            backgroundTracker: BackgroundTrailTracker(
                container: container,
                monitor: StubLocationMonitor(),
                regionMonitor: FakeTrailRegionMonitor(),
                defaults: try makeScratchDefaults(),
                lines: lines
            ),
            autoSaveController: AutoSaveController(store: sandbox.store, drainInterval: nil, lines: lines),
            hikeRecorder: HikeRecorder(container: container),
            locationManager: LocationManager(manager: DormantLocationSource()),
            weatherManager: WeatherManager(widgetPublisher: .inert),
            significantLocations: SignificantLocationFeed(monitor: DormantLocationSource()),
            selectedLine: lines,
            defaults: try makeScratchDefaults()
        )
    }

    /// The ridge moved half a degree north.
    static let movedRoute = Fixture.ridgeRoute.map { point in
        var moved = point
        moved.latitude += 0.5
        return moved
    }

    static func isOnMovedRoute(_ coordinate: CLLocationCoordinate2D?) -> Bool {
        (coordinate?.latitude ?? 0) > (Fixture.ridgeRoute.last?.latitude ?? 0) + 0.4
    }

    /// A long trail, a metre or so a point, with heights and a clock.
    private static func longRoute(points: Int) -> [RouteCoordinate] {
        (0..<points).map { index in
            let step = Double(index)
            return RouteCoordinate(
                latitude: 47 + step * 0.00001,
                longitude: 12 + sin(step / 50) * 0.001,
                elevation: 600 + sin(step / 200) * 50,
                timestamp: Date(timeIntervalSince1970: 1_750_000_000 + step)
            )
        }
    }

    /// A hike saved by another context and fetched into the main one, whose
    /// line the main context has never read.
    private func hikeSavedElsewhere(route: [RouteCoordinate]) throws -> Hike {
        let id = UUID()
        let elsewhere = ModelContext(container)
        let length = RouteProfile(route: route).totalDistanceMeters
        elsewhere.insert(Hike(title: "Long", distanceMeters: length, id: id, route: route))
        try elsewhere.save()
        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
        return try #require(try container.mainContext.fetch(descriptor).first)
    }

    /// What the selection handler and the model do with a finished hike.
    func select(_ hike: Hike) async {
        DisplayedRouteCoordinateCache().prepare(for: hike, from: model.selectedLine)
        model.selectedHikeDidChange(to: hike)
        await model.autoSaveController.waitForActivation()
        await settleDelegateHop(until: "the store watch has caught up") { self.model.selectedLineStoreWatch.isSettled }
    }

    /// Hosts the hike's screen in a window, as the sheet pushes it, with the
    /// hikes list's query beside it when asked for.
    func host(
        _ hike: Hike,
        withHikesList: Bool,
        trailGraphProvider: (any TrailGraphProviding)? = nil
    ) throws -> UIWindow {
        let detail = HikeDetailView(
            hike: hike,
            highlight: highlight,
            mapController: MapController(),
            autoSave: model.autoSaveController,
            entitlement: model.entitlement,
            settings: model.storedSettings,
            locationManager: model.locationManager,
            backgroundTracker: model.backgroundTracker,
            selectedLine: model.selectedLine,
            lineStoreWatch: model.selectedLineStoreWatch,
            trailGraphProvider: trailGraphProvider,
            walkSession: model.walkSession,
            photoPins: PhotoMapPinController(),
            placePins: model.placePins
        )
        let root = VStack {
            if withHikesList { HikesListStandIn() }
            NavigationStack { detail }
        }
        let scene = try #require(
            UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
            "app-hosted tests run inside the app, which has a scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: root.modelContainer(container).environment(model))
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    static func takeDown(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Makes `save` and waits for the refresh it gives `hike` in the main
    /// context, then lays the window out, so every body that refresh
    /// invalidated has been evaluated again.
    private func save(refreshing hike: Hike, in window: UIWindow, _ saving: () async throws -> Void) async throws {
        let refreshed = SelectedLine.Write()
        withObservationTracking {
            _ = hike.title
        } onChange: {
            refreshed.raise()
        }
        try await saving()
        await settleDelegateHop(until: "the save has refreshed the hike") { refreshed.isRaised }
        await settleDelegateHop(until: "the store watch has checked the save") {
            self.model.selectedLineStoreWatch.isSettled
        }
        await model.selectedLine.refreshing?.value
        window.layoutIfNeeded()
    }

    @Test("the screen draws the line the store holds, from the read the map's readers share")
    func theScreenDrawsTheSharedRead() async throws {
        let hike = Fixture.hike(in: container.mainContext, route: Array(Fixture.ridgeRoute.prefix(1)))
        try container.mainContext.save()
        let moved = Self.movedRoute
        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: container) { stored in
            stored.replaceRoute(with: moved)
            stored.distanceMeters = RouteProfile(route: moved).totalDistanceMeters
        }
        try #require(
            hike.route.count == 1 && !hike.hasChanges,
            "the premise: with no hikes list up, the main context's copy was never told of the sibling's save"
        )
        await select(hike)

        let window = try host(hike, withHikesList: false)
        defer { Self.takeDown(window) }
        await settleDelegateHop(until: "the screen has built its profile") { self.highlight.coordinate != nil }

        #expect(Self.isOnMovedRoute(highlight.coordinate), "the store's line, which the map's readers read")
    }

    /// #724, which the screen keys its work on its line for: an edit from
    /// another device arrives while the screen is up, and the screen builds
    /// its profile, its matcher and its statistics again on the new line.
    @Test("a line another device saved while the screen is up is the line it builds on")
    func aLineSavedElsewhereRestartsTheScreen() async throws {
        let hike = Fixture.hike(in: container.mainContext)
        try await RemoteChangeLog.save(container.mainContext, settling: hike)
        await select(hike)
        let window = try host(hike, withHikesList: true)
        defer { Self.takeDown(window) }
        await settleDelegateHop(until: "the screen has built its profile") { self.highlight.coordinate != nil }
        try #require(!Self.isOnMovedRoute(highlight.coordinate))

        let moved = Self.movedRoute
        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: container) { $0.replaceRoute(with: moved) }
        await settleDelegateHop(until: "the screen has built its profile again, on the new line") {
            Self.isOnMovedRoute(self.highlight.coordinate)
        }
    }

    /// An import or a recording can take the selection while the screen
    /// stays up. Auto-save follows the hike the map draws, and the map's
    /// readers share the selection's read, so when the screen builds its own
    /// line again it must point neither back at its hike.
    @Test("a screen whose hike the selection left leaves auto-save and the map's read to the selection")
    func aScreenTheSelectionLeftLeavesTheSelectionAlone() async throws {
        let shown = Fixture.hike(in: container.mainContext, title: "Shown")
        let imported = Fixture.hike(in: container.mainContext, title: "Imported", route: Fixture.loopRoute)
        try await RemoteChangeLog.save(container.mainContext, settling: shown)
        await select(shown)
        let window = try host(shown, withHikesList: true)
        defer { Self.takeDown(window) }
        await settleDelegateHop(until: "the screen has built its profile") { self.highlight.coordinate != nil }

        await select(imported)
        let importedRead = model.selectedLine.read(of: imported)
        // A new line for the shown hike, which has its screen build again.
        shown.replaceRoute(with: Self.movedRoute)
        try await RemoteChangeLog.save(container.mainContext, settling: shown)
        await settleDelegateHop(until: "the screen has built its profile on the new line") {
            Self.isOnMovedRoute(self.highlight.coordinate)
        }
        await model.autoSaveController.waitForActivation()

        #expect(model.autoSaveController.currentHike?.id == imported.id, "auto-save stays with the map's hike")
        #expect(model.selectedLine.read(of: imported) === importedRead, "and the map keeps its read")
    }

    /// The screen open on a long line the main context has never read, with
    /// the hikes list's query beside it, as the sheet has it.
    private func openOnALongLine() async throws -> (hike: Hike, window: UIWindow) {
        let hike = try hikeSavedElsewhere(route: Self.longRoute(points: Self.longPoints))
        await select(hike)
        let window = try host(hike, withHikesList: true)
        await settleDelegateHop(until: "the screen has built its profile") { self.highlight.coordinate != nil }
        window.layoutIfNeeded()
        return (hike, window)
    }

    /// How long the main context takes to read `hike`'s line now: the whole
    /// decode if nothing read it there before, next to nothing if something
    /// did.
    private static func mainActorRead(of hike: Hike) -> (points: Int, duration: Duration) {
        let clock = ContinuousClock()
        let start = clock.now
        let points = hike.route.count
        return (points, clock.now - start)
    }

    private static let longPoints = 100_000

    /// From iOS 27, for the reason in the header.
    @available(iOS 27.0, *)
    @Test("opening the screen decodes none of its line on the main actor")
    func openingDecodesNothing() async throws {
        let (hike, window) = try await openOnALongLine()
        defer { Self.takeDown(window) }

        let read = Self.mainActorRead(of: hike)
        #expect(read.points == Self.longPoints)
        #expect(read.duration >= .milliseconds(5), "a line read on opening comes back at once: \(read.duration)")
    }

    /// From iOS 27, for the reason in the header.
    @available(iOS 27.0, *)
    @Test("with the hikes list up, saves to the store decode none of the open screen's line on the main actor")
    func savesDecodeNothing() async throws {
        let neighbor = Fixture.hike(in: container.mainContext, title: "Neighbor", route: Fixture.loopRoute)
        try await RemoteChangeLog.save(container.mainContext, settling: neighbor)
        let (hike, window) = try await openOnALongLine()
        defer { Self.takeDown(window) }

        try await save(refreshing: hike, in: window) {
            neighbor.tintHex = "#FF00FF"
            try await RemoteChangeLog.save(self.container.mainContext, settling: neighbor)
        }
        try await save(refreshing: hike, in: window) {
            try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: self.container) { $0.title = "Renamed" }
        }
        try await save(refreshing: hike, in: window) {
            hike.tintHex = "#00FF00"
            try await RemoteChangeLog.save(self.container.mainContext, settling: hike)
        }

        let read = Self.mainActorRead(of: hike)
        #expect(read.points == Self.longPoints)
        #expect(read.duration >= .milliseconds(5), "a line a body read comes back at once: \(read.duration)")
    }
}
