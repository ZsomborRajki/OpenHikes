//
//  HikeDeletionTests.swift
//  OpenHikesTests
//
//  Deleting a hike is the one operation that touches every subsystem at once:
//  the auto-save store, the tile manifests, the widget feed, the selection,
//  and the sheet's navigation stack. `StorageAccountingTests` covers the
//  tiles thoroughly. What isn't covered is the object itself — a deleted
//  `Hike` that other parts of the app are still holding a reference to.
//
//  `OpenHikesView` holds two: `selectedHike`, and `navigationPath`, typed
//  `[SheetRoute]` rather than `NavigationPath` so a widget tap can inspect
//  it. `MapSheet.delete(_:among:)` clears both, and these tests pin that
//  rule: a hike left in the path would be handed straight to
//  `HikeDetailView` by `navigationDestination(for: SheetRoute.self)`, which
//  reads `hike.title`, `hike.route`, `hike.tint` and builds a
//  `RouteProfile` from them.
//

import Foundation
@testable import OpenHikes
import OpenHikesShared
import SwiftData
import Testing

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

    /// The screen this prevents. A hike left in the navigation stack after
    /// deletion would keep its detail view pushed, showing a trail that no
    /// longer exists — its stats, its elevation chart, its Offline and
    /// Auto-Save controls all live and tappable, writing to a detached object
    /// that nothing will persist.
    ///
    /// `MapSheet.delete(_:among:)` clears `selectedHike` when it matches,
    /// which is what stops the *map* drawing a ghost route, and removes the
    /// hike from `path` unconditionally — a widget deep link pushes onto that
    /// path directly, so "pushed" and "selected" need not be the same hike.
    ///
    /// Calls `SheetRoute.removeHike` — the rule `MapSheet.delete(_:among:)`
    /// itself calls. It used to be re-implemented here, because it lived
    /// inside that private view method; a mirrored rule pins the reasoning but
    /// cannot fail when the call site drifts away from it.
    @Test("deleting a hike takes it out of the navigation stack too")
    func deletionClearsTheNavigationPath() throws {
        let context = try Fixture.modelContext()
        let hike = Fixture.hike(in: context)

        // The state `OpenHikesView` holds and `MapSheet` is handed.
        var selectedHike: Hike? = hike
        var path: [SheetRoute] = [.hike(hike)]

        let wasSelected = SheetRoute.removeHike(hike.id, selectedHike: &selectedHike, from: &path)
        context.delete(hike)

        #expect(wasSelected, "so the caller knows to clear the map highlight")
        #expect(selectedHike == nil, "the map stops drawing it")
        #expect(path.isEmpty, "and the detail view showing it is popped")
    }

    /// Deleting one hike must not pop a different one. A deep link can push a
    /// trail that isn't the selected one, so "pop everything" would be as
    /// wrong as popping nothing.
    @Test("deleting a hike leaves other pushed hikes alone")
    func deletionKeepsUnrelatedNavigation() throws {
        let context = try Fixture.modelContext()
        let doomed = Fixture.hike(in: context)
        let survivor = Fixture.hike(in: context, title: "Survivor", route: Fixture.loopRoute)

        var selectedHike: Hike? = survivor
        var path: [SheetRoute] = [.hike(survivor), .hike(doomed)]

        let wasSelected = SheetRoute.removeHike(doomed.id, selectedHike: &selectedHike, from: &path)
        context.delete(doomed)

        #expect(!wasSelected, "a different hike was selected, so the highlight stays")
        #expect(selectedHike?.id == survivor.id)
        #expect(path == [.hike(survivor)])
    }

    /// The unconditional half of the rule: a widget deep link pushes a trail
    /// without selecting it, so a deletion has to pop by identity rather than
    /// by "was it selected".
    @Test("deleting an unselected hike still pops the screen showing it")
    func deletionPopsAnUnselectedButPushedHike() throws {
        let context = try Fixture.modelContext()
        let deepLinked = Fixture.hike(in: context, title: "Deep linked")
        let selected = Fixture.hike(in: context, title: "Selected", route: Fixture.loopRoute)

        var selectedHike: Hike? = selected
        // A pushed photo viewer goes with it — the gallery it pages through
        // belongs to the hike being deleted.
        var path: [SheetRoute] = [.hike(deepLinked), .photo(deepLinked, UUID())]

        let wasSelected = SheetRoute.removeHike(deepLinked.id, selectedHike: &selectedHike, from: &path)
        context.delete(deepLinked)

        #expect(!wasSelected)
        #expect(selectedHike?.id == selected.id, "an unrelated selection is untouched")
        #expect(path.isEmpty, "both the detail view and its gallery are popped")
    }

    /// The persisted "what was selected" pointer. `OpenHikesModel` writes it from
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
    /// answered by `openHike(id:)`, which fetches by id and returns quietly
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
