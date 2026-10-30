//
//  ShownLineTests.swift
//  OpenHikesTests
//
//  What a hike's screen reads its line from, and when that line is new
//  (#1252). The screen keys its profile, statistics, follow loop and surface
//  lookup on ``ShownLine/revision``, so what is asserted is that the revision
//  moves for a new line — written here or saved elsewhere — and for nothing
//  else, and that the line comes off the main actor from the read the map's
//  readers share while the hike is selected.
//
//  Late reads are the risk in a type like this. Each of the two before it
//  (#1232, #1228) had a read that landed after a newer one and put the older
//  line back, so the orderings are driven here with a fetch that holds a read
//  after it has fetched its row: a later write, a later hike, and a second
//  line saved before the first lands.
//
//  On-disk stores, as the store watch's own suite has them: history is what
//  the watch reads, and the in-memory store records some writes differently.
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
@Suite("Shown line", .serialized)
final class ShownLineTests {
    /// Which threads the store's fetch ran on, one entry per call.
    nonisolated final class FetchLog: Sendable {
        private let threads = Mutex<[Bool]>([])

        var ranOnMainThread: [Bool] { threads.withLock { $0 } }

        func fetch(_ context: ModelContext, _ id: PersistentIdentifier) throws -> Hike? {
            threads.withLock { $0.append(Thread.isMainThread) }
            return try SelectedLine.fetchHike(context, id)
        }
    }

    /// A fetch that holds one call once it has read its row, so the read
    /// lands late carrying the line the store held when it fetched.
    nonisolated final class LateFetch: Sendable {
        private let calls = Mutex(0)
        private let heldCall: Int
        private let release = DispatchSemaphore(value: 0)
        private let fetched = Mutex(false)

        /// - Parameter heldCall: which call to hold, counting from one.
        init(holding heldCall: Int) {
            self.heldCall = heldCall
        }

        /// Whether the held call has read its row and is waiting.
        var isHolding: Bool { fetched.withLock { $0 } }

        func fetch(_ context: ModelContext, _ id: PersistentIdentifier) throws -> Hike? {
            let call = calls.withLock { count in
                count += 1
                return count
            }
            let hike = try SelectedLine.fetchHike(context, id)
            guard call == heldCall else { return hike }
            // The line is decoded now, so what the read carries is the row
            // as it stood, whatever is saved while it waits.
            _ = hike?.route
            fetched.withLock { $0 = true }
            release.wait()
            return hike
        }

        func open() { release.signal() }
    }

    /// The hikes list's query, and nothing else: what keeps every hike in the
    /// main context refreshed in the app.
    private struct HikesListStandIn: View {
        @Query(sort: \Hike.date, order: .reverse) private var hikes: [Hike]

        var body: some View {
            Text(verbatim: "\(hikes.count)")
        }
    }

    /// The selection's reader and the watch that follows the selected hike
    /// in the store, wired the way the model wires them.
    private struct Selection {
        let lines: SelectedLine
        let watch: SelectedLineStoreWatch
    }

    private let container: ModelContainer

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "shown-line/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try ModelContainer.openHikes(
            url: directory.appending(path: "OpenHikes.store"),
            localURL: directory.appending(path: "OpenHikesLocal.store")
        )
        container.mainContext.autosaveEnabled = false
    }

    /// The ridge moved half a degree north, with its heights.
    private static let movedRoute = Fixture.ridgeRoute.map { point in
        var moved = point
        moved.latitude += 0.5
        return moved
    }

    /// And moved a little further, for a second new line.
    private static let furtherRoute = movedRoute.map { point in
        var moved = point
        moved.latitude += 0.1
        return moved
    }

    private static func selection(
        fetch: @escaping @Sendable (ModelContext, PersistentIdentifier) throws -> Hike? = SelectedLine.fetchHike
    ) -> Selection {
        let lines = SelectedLine(fetch: fetch)
        return Selection(lines: lines, watch: SelectedLineStoreWatch { lines.refresh() })
    }

    /// What the model does with a selected finished hike: its readers ask
    /// for the line, and then the watch follows it from when that read began.
    private func select(_ hike: Hike, in selection: Selection) async throws {
        _ = selection.lines.read(of: hike)
        selection.watch.follow(hike, since: try #require(selection.lines.readBegan(for: hike)))
        await settleDelegateHop(until: "the watch has caught up with the hike") { selection.watch.isSettled }
    }

    private func saved(_ title: String, route: [RouteCoordinate] = Fixture.ridgeRoute) async throws -> Hike {
        let hike = Fixture.hike(in: container.mainContext, title: title, route: route)
        try await RemoteChangeLog.save(container.mainContext, settling: hike)
        return hike
    }

    /// Writes `route` as every writer of a line does: through the hike's own
    /// context, saved at once.
    private func write(_ route: [RouteCoordinate], to hike: Hike) throws {
        hike.replaceRoute(with: route)
        hike.distanceMeters = RouteProfile(route: route).totalDistanceMeters
        try container.mainContext.save()
    }

    /// Hosts the hikes list's query in a window, as the sheet does.
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

    private func landed(on route: [RouteCoordinate], _ shown: ShownLine, _ what: Comment) async {
        await settleDelegateHop(until: what) { shown.current?.route == route }
        await shown.landing?.value
    }

    @Test("a selected hike's screen reads the line the map's readers share, off the main thread")
    func theScreenSharesTheSelectionsRead() async throws {
        let hike = try await saved("Shared")
        let log = FetchLog()
        let selection = Self.selection(fetch: log.fetch)
        try await select(hike, in: selection)
        let shared = selection.lines.read(of: hike)
        let shown = ShownLine()

        let read = shown.show(hike, selection: selection.lines, followedBy: selection.watch)
        await shown.landing?.value

        #expect(read === shared, "the readers' read, not one of the screen's own")
        #expect(log.ranOnMainThread == [false], "one fetch, off the main thread, for all of them")
        #expect(shown.current?.route == Fixture.ridgeRoute)
        #expect(shown.revision == 0)
        #expect(selection.lines.read(of: hike) === shared, "and the readers keep theirs")
    }

    /// The cost #1252 removed: under the hikes list's query, every save to
    /// the store refreshed the hike and notified `route`, and the screen's
    /// body decoded the line again for it. None of those saves is a new line.
    @Test("with the hikes list up, a rename, a tint or another hike's save reads nothing and moves nothing")
    func otherSavesMoveNothing() async throws {
        let hike = try await saved("Selected")
        let neighbor = try await saved("Neighbor", route: Fixture.loopRoute)
        let window = try await hostHikesList()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let selection = Self.selection()
        try await select(hike, in: selection)
        let shown = ShownLine()
        let read = shown.show(hike, selection: selection.lines, followedBy: selection.watch)
        await shown.landing?.value

        neighbor.tintHex = "#FF00FF"
        try await checked(selection) {
            try await RemoteChangeLog.save(self.container.mainContext, settling: neighbor)
        }
        try await checked(selection) {
            try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: self.container) { $0.title = "Renamed" }
        }
        hike.tintHex = "#00FF00"
        hike.customName = "Renamed here"
        hike.autoFollowEnabled.toggle()
        try await checked(selection) {
            try await RemoteChangeLog.save(self.container.mainContext, settling: hike)
        }
        await settleDelegateHop()
        await shown.landing?.value

        #expect(shown.read === read, "no new read")
        #expect(shown.revision == 0, "and nothing to restart")
    }

    /// Makes `save`, and waits until the watch has checked the store for it
    /// and any look at the line that check started has landed.
    private func checked(_ selection: Selection, _ save: () async throws -> Void) async throws {
        let before = selection.watch.completedChecks
        try await save()
        await settleDelegateHop(until: "the watch has checked the save") {
            selection.watch.completedChecks > before && selection.watch.isSettled
        }
        await selection.lines.refreshing?.value
    }

    @Test("a line written to the hike is a new line, once")
    func aWrittenLineMovesTheRevisionOnce() async throws {
        let hike = try await saved("Written")
        let selection = Self.selection()
        try await select(hike, in: selection)
        let shown = ShownLine()
        shown.show(hike, selection: selection.lines, followedBy: selection.watch)
        await shown.landing?.value

        try write(Self.movedRoute, to: hike)
        await landed(on: Self.movedRoute, shown, "the written line is shown")
        await selection.lines.refreshing?.value
        await settleDelegateHop()

        #expect(shown.revision == 1)
        #expect(shown.current?.distanceMeters == hike.distanceMeters, "with the length written beside it")
        #expect(shown.read === selection.lines.read(of: hike), "and from the readers' new read")
    }

    /// The edit #724 was about: *Edit Route* keeps the hike's id and
    /// replaces its line, and the line the screen then builds from matches a
    /// fix on the new line that the old one is hundreds of metres from.
    @Test("an edited line under the same id prepares into a matcher for that line")
    func anEditPreparesTheNewLine() async throws {
        let draft = TrailDraft()
        for latitude in [47.6300, 47.6340] {
            draft.append(CLLocationCoordinate2D(latitude: latitude, longitude: 12.86))
        }
        let hike = try #require(TrailDraftSave.hike(from: draft, named: "Ridge", into: container.mainContext).hike)
        let selection = Self.selection()
        try await select(hike, in: selection)
        let shown = ShownLine()
        let before = shown.show(hike, selection: selection.lines, followedBy: selection.watch)
        await shown.landing?.value

        draft.append(CLLocationCoordinate2D(latitude: 47.6400, longitude: 12.86))
        try #require(TrailDraftSave.update(hike, from: draft, openedWith: [], into: container.mainContext).hike != nil)
        await settleDelegateHop(until: "the edited line is shown") { shown.revision == 1 }
        await shown.landing?.value

        let old = try await HikeDetailPreparation.prepare(reading: before)
        let new = try await HikeDetailPreparation.prepare(reading: try #require(shown.read))
        let fix = CLLocationCoordinate2D(latitude: 47.6400, longitude: 12.86)
        let oldMatch = try #require(old.profile.nearestPoint(to: fix))
        let newMatch = try #require(new.profile.nearestPoint(to: fix))
        #expect(oldMatch.offRouteMeters > RouteProfile.followMatchThresholdMeters)
        #expect(newMatch.offRouteMeters <= RouteProfile.followMatchThresholdMeters)
        #expect(new.walkRevision == TrailWalkRecord.routeRevision(of: hike.route))
    }

    @Test("a line another device saved for the hike reaches its screen")
    func aLineSavedElsewhereReachesTheScreen() async throws {
        let hike = try await saved("Synced")
        let selection = Self.selection()
        try await select(hike, in: selection)
        let shown = ShownLine()
        shown.show(hike, selection: selection.lines, followedBy: selection.watch)
        await shown.landing?.value

        let moved = Self.movedRoute
        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: container) { $0.replaceRoute(with: moved) }
        await landed(on: Self.movedRoute, shown, "the line saved elsewhere is shown")

        #expect(shown.revision == 1)
    }

    /// An import or a recording can take the selection while a hike's screen
    /// stays up. The screen must not ask the selection's reader about its
    /// hike, which would take that reader's read from the map, and a line
    /// saved elsewhere must still reach it.
    @Test("a screen whose hike the selection left reads its own, takes nothing from the map, and still hears saves")
    func aScreenTheSelectionLeftReadsItsOwn() async throws {
        let hike = try await saved("Shown")
        let next = try await saved("Imported", route: Fixture.loopRoute)
        let window = try await hostHikesList()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let selection = Self.selection()
        try await select(hike, in: selection)
        let shown = ShownLine()
        let shared = shown.show(hike, selection: selection.lines, followedBy: selection.watch)
        await shown.landing?.value

        try await select(next, in: selection)
        let nextRead = selection.lines.read(of: next)
        // A save, which refreshes the shown hike and so has its screen look
        // at whose reader it reads through.
        next.tintHex = "#FF00FF"
        try await RemoteChangeLog.save(container.mainContext, settling: next)
        await settleDelegateHop(until: "the screen reads through its own") { shown.read !== shared }
        await shown.landing?.value

        #expect(selection.lines.read(of: next) === nextRead, "the map's readers keep the selection's read")
        #expect(shown.revision == 0, "the same line, read again, restarts nothing")
        #expect(shown.current?.route == Fixture.ridgeRoute)

        let moved = Self.movedRoute
        try await SelectedLineStoreWatchTests.saveElsewhere(hike.id, in: container) { $0.replaceRoute(with: moved) }
        await landed(on: Self.movedRoute, shown, "a line saved elsewhere still reaches the screen")
        #expect(shown.revision == 1)
        #expect(selection.lines.read(of: next) === nextRead)
    }

    /// The first of the orderings: a write lands while the read before it is
    /// still out, and the screen ends on the newer line whichever lands last.
    @Test("a read that lands after a newer line changes nothing")
    func aLateReadChangesNothing() async throws {
        let hike = try await saved("Late")
        let late = LateFetch(holding: 2)
        defer { late.open() }
        let selection = Self.selection(fetch: late.fetch)
        try await select(hike, in: selection)
        let shown = ShownLine()
        shown.show(hike, selection: selection.lines, followedBy: selection.watch)
        await shown.landing?.value

        try write(Self.movedRoute, to: hike)
        await settleDelegateHop(until: "the moved line's read is out") { late.isHolding }
        let held = try #require(shown.read)
        try write(Self.furtherRoute, to: hike)
        await landed(on: Self.furtherRoute, shown, "the newer line lands first")
        let revision = shown.revision
        late.open()
        _ = await held.route
        await settleDelegateHop()
        await shown.landing?.value

        #expect(shown.current?.route == Self.furtherRoute, "the late line is not put back")
        #expect(shown.revision == revision)
        #expect(shown.read !== held)
    }

    /// Two lines saved close together: the screen ends on the second, and
    /// the read it holds is the one the readers hold.
    @Test("two lines written close together end on the second")
    func twoLinesEndOnTheSecond() async throws {
        let hike = try await saved("Twice")
        let selection = Self.selection()
        try await select(hike, in: selection)
        let shown = ShownLine()
        shown.show(hike, selection: selection.lines, followedBy: selection.watch)
        await shown.landing?.value

        try write(Self.movedRoute, to: hike)
        try write(Self.furtherRoute, to: hike)
        await landed(on: Self.furtherRoute, shown, "the second line is shown")
        await selection.lines.refreshing?.value
        await settleDelegateHop()
        await shown.landing?.value

        #expect(shown.current?.route == Self.furtherRoute)
        #expect(shown.read === selection.lines.read(of: hike))
    }

    /// A screen shows one hike, but a read of the first is not cancelled
    /// when it is asked about another, and must not land over it.
    @Test("a late read of the hike shown before lands on nothing")
    func anEarlierHikesLateReadLandsOnNothing() async throws {
        let first = try await saved("First")
        let second = try await saved("Second", route: Self.movedRoute)
        let late = LateFetch(holding: 1)
        defer { late.open() }
        let selection = Self.selection()
        let shown = ShownLine(fetch: late.fetch)

        let held = shown.show(first, selection: selection.lines, followedBy: selection.watch)
        await settleDelegateHop(until: "the first hike's read is out") { late.isHolding }
        shown.show(second, selection: selection.lines, followedBy: selection.watch)
        await landed(on: Self.movedRoute, shown, "the second hike's line is shown")
        late.open()
        _ = await held.route
        await settleDelegateHop()

        #expect(shown.current?.route == Self.movedRoute)
        #expect(shown.revision == 0)
    }
}
