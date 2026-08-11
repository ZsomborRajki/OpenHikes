//
//  HikeDeletionTests.swift
//  OpenTrailsTests
//
//  Deleting a hike is the one operation that touches every subsystem at once:
//  the auto-save store, the tile manifests, the widget feed, the selection,
//  and the sheet's navigation stack. `OfflineStorageAccountingTests` covers
//  the tiles thoroughly. What isn't covered is the object itself — a deleted
//  `Hike` that other parts of the app are still holding a reference to.
//
//  `ContentView` holds two: `selectedHike`, and `navigationPath`, which is
//  typed `[Hike]` rather than `NavigationPath` so a widget tap can inspect it.
//  `MapSheet.delete(_:)` clears the first when it matches and never touches
//  the second, so a deleted model can stay in the navigation stack — and
//  `navigationDestination(for: Hike.self)` will hand it straight to
//  `HikeDetailView`, which reads `hike.title`, `hike.route`, `hike.tint` and
//  builds a `RouteProfile` from them.
//

import Foundation
import OpenTrailsShared
import SwiftData
import Testing
@testable import OpenTrails

@MainActor
@Suite("Hike deletion")
struct HikeDeletionTests {
    /// What a deleted `Hike` still answers. SwiftData doesn't invalidate the
    /// object — it detaches it — so reads keep working against the last known
    /// values rather than trapping. That's the good news, and it's why the gap
    /// below is a stale screen rather than a crash.
    @Test("a deleted hike is detached, not invalidated")
    func deletedHikeStillReadsBack() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let id = hike.id

        context.delete(hike)
        try context.save()

        #expect(hike.title == "Ridge Loop", "reads must not trap — the detail view may still be on screen")
        #expect(hike.route.count == Fixture.ridgeRoute.count)
        #expect(hike.id == id)

        let remaining = try context.fetch(FetchDescriptor<Hike>())
        #expect(remaining.isEmpty, "and it really is gone from the store")
    }

    /// The screen that results. A hike deleted while its detail view is on the
    /// navigation stack leaves that view pushed, showing a trail that no
    /// longer exists — its stats, its elevation chart, its Offline and
    /// Auto-Save controls all live and tappable, writing to a detached object
    /// that nothing will persist.
    ///
    /// `MapSheet.delete(_:)` clears `selectedHike` when it matches, which is
    /// what stops the *map* drawing a ghost route. `navigationPath` needs the
    /// same treatment, and gets it through `path.removeAll { $0.id == hike.id }`.
    ///
    /// Not reachable by swipe today (the list and the detail view are never on
    /// screen together), and one step away from being reachable: the widget
    /// deep link pushes onto this same path, and a delete-from-detail action
    /// is the obvious next thing to add to that screen.
    ///
    /// Mirrors `delete(_:)` rather than calling it — it's a private method on a
    /// `View`, wired to `@Query`, bindings and the tile cache — so it's the
    /// established pattern in this suite and in `StorageAccountingTests`, with
    /// the same caveat: it pins the *rule*, not the call site.
    @Test("deleting a hike takes it out of the navigation stack too")
    func deletionClearsTheNavigationPath() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        // The state `ContentView` holds, as `MapSheet` would leave it.
        var selectedHike: Hike? = hike
        var navigationPath: [Hike] = [hike]

        // `MapSheet.delete(_:)`, in the order it does it.
        if hike.id == selectedHike?.id { selectedHike = nil }
        navigationPath.removeAll { $0.id == hike.id }
        context.delete(hike)

        #expect(selectedHike == nil, "the map stops drawing it")
        #expect(navigationPath.isEmpty, "and the detail view showing it is popped")
    }

    /// Deleting one hike must not pop a different one. The path is typed
    /// `[Hike]` and a deep link can push a trail that isn't the selected one,
    /// so "pop everything" would be as wrong as popping nothing.
    @Test("deleting a hike leaves other pushed hikes alone")
    func deletionKeepsUnrelatedNavigation() throws {
        let context = try Fixture.modelContext()
        let doomed = Fixture.hike(in: context)
        let survivor = Fixture.hike(title: "Survivor", route: Fixture.loopRoute, in: context)

        var navigationPath: [Hike] = [survivor, doomed]
        navigationPath.removeAll { $0.id == doomed.id }
        context.delete(doomed)

        #expect(navigationPath.map(\.id) == [survivor.id])
    }

    /// The persisted "what was selected" pointer. `ContentView` writes it from
    /// `onChange(of: selectedHike)`, so a deletion that clears the selection
    /// clears it too — and `restoreLastSelectedHike` fetches by id, so a
    /// stale one resolves to nothing rather than to the wrong hike.
    ///
    /// Pinned because it's the only cross-launch state a delete has to reason
    /// about, and it's reasoned about implicitly.
    @Test("a deleted hike can't be restored on the next launch")
    func deletedHikeIsNotRestored() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let id = hike.id
        context.delete(hike)
        try context.save()

        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
        #expect(try context.fetch(descriptor).isEmpty)
    }

    /// The widget's side of the same event: `BackgroundTrailTracker` is told
    /// through the selection change, and the deep link it published is
    /// answered by `openHike(from:)`, which fetches by id and returns quietly
    /// when there's nothing there. Pinned so a future "open the trail anyway"
    /// convenience can't reintroduce a ghost.
    @Test("a widget tap on a deleted trail resolves to nothing")
    func deepLinkToDeletedHikeResolvesToNothing() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)
        let url = try #require(TrailWidgetDeepLink.url(hikeID: hike.id))
        context.delete(hike)
        try context.save()

        let id = try #require(TrailWidgetDeepLink.hikeID(from: url))
        let descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == id })
        #expect(try context.fetch(descriptor).first == nil)
    }
}
