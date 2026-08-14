//
//  SheetQueryIsolationTests.swift
//  OpenHikesTests
//
//  `MapSheet` holds the app's only broad `@Query` — every `Hike`, sorted by
//  date — and the sheet is also the `NavigationStack` the hike detail view is
//  pushed into. That puts a SwiftData query and a colour/width slider in the
//  same live hierarchy, which is worth measuring rather than assuming: unlike
//  `@Observable`, `@Query` has no per-property granularity, so a write to any
//  `Hike` field invalidates every view holding one.
//
//  Measured on a real hosted hierarchy rather than reasoned about, because the
//  answer is SwiftData's rather than this app's, and the fix (which subtree
//  holds the query) only pays for itself if the premise is true.
//

import Foundation
@testable import OpenHikes
import SwiftData
import SwiftUI
import Testing

/// Counts `body` evaluations. A class so the count survives the value-type
/// copies SwiftUI makes of the view itself.
@MainActor
final class BodyCounter {
    private(set) var count = 0

    func record() { count += 1 }
}

/// The shape `MapSheet` had: the query and the chrome in one body, so anything
/// that invalidates the query re-runs all of it.
private struct BroadQueryProbe: View {
    let counter: BodyCounter
    @Query(sort: \Hike.date, order: .reverse)
    private var hikes: [Hike]

    var body: some View {
        counter.record()
        return Text(verbatim: "\(hikes.count)")
    }
}

/// The shape it has now: the query lives in a leaf, and the parent — standing
/// in for the search field, the settings button and the navigation stack —
/// holds none of it.
private struct NarrowQueryProbe: View {
    let outerCounter: BodyCounter
    let innerCounter: BodyCounter

    var body: some View {
        outerCounter.record()
        return VStack {
            Text(verbatim: "chrome")
            BroadQueryProbe(counter: innerCounter)
        }
    }
}

@MainActor
@Suite("Sheet query isolation")
struct SheetQueryIsolationTests {
    /// Hosts a view in a real window and lets SwiftUI settle. Nothing about a
    /// `@Query` update is synchronous, so the count is only meaningful after
    /// the run loop has had the chance to deliver it.
    ///
    /// The window is built from the host app's own scene — both unit bundles
    /// are app-hosted, so there is always one — because `UIWindow(frame:)` is
    /// deprecated and a scene-less window never lays out.
    private func host(_ view: some View, in container: ModelContainer) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
            "app-hosted tests run inside the app, which has a scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(
            rootView: view.modelContainer(container)
        )
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func settle(_ window: UIWindow) async {
        for _ in 0..<10 {
            await Task.yield()
            window.rootViewController?.view.setNeedsLayout()
            window.layoutIfNeeded()
        }
    }

    /// Teardown, for the same reason `MapCoordinatorTests` detaches its map:
    /// a hosted window left behind keeps a live SwiftData observation and a
    /// hosting controller alive across the rest of the run.
    private func dismiss(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// The premise. A slider drag in the hike detail view writes `routeWidth`
    /// at touch frequency, and nothing renders it here — but the query has no
    /// way to know that.
    @Test("a write to an unrendered field still invalidates a broad query")
    func unrelatedWritesInvalidateTheQuery() async throws {
        let container = try Fixture.modelContainer()
        let hike = Fixture.hike(in: container.mainContext)
        let counter = BodyCounter()
        let window = try host(BroadQueryProbe(counter: counter), in: container)
        defer { dismiss(window) }
        await settle(window)

        let before = counter.count
        #expect(before > 0, "precondition: the probe rendered at all")

        for width in stride(from: 3.0, through: 8.0, by: 1.0) {
            hike.routeWidth = width
            await settle(window)
        }

        #expect(
            counter.count > before,
            "SwiftData has no per-property granularity: this is the cost the sheet used to pay"
        )
    }

    /// And the fix: the same writes, against a hierarchy where only the leaf
    /// holds the query. The chrome around it is evaluated once and stays that
    /// way — which is what `MapSheet` now looks like.
    @Test("a query held in a leaf leaves the surrounding chrome alone")
    func narrowingTheQueryProtectsTheParent() async throws {
        let container = try Fixture.modelContainer()
        let hike = Fixture.hike(in: container.mainContext)
        let outer = BodyCounter()
        let inner = BodyCounter()
        let window = try host(NarrowQueryProbe(outerCounter: outer, innerCounter: inner), in: container)
        defer { dismiss(window) }
        await settle(window)

        let outerBefore = outer.count
        let innerBefore = inner.count

        for width in stride(from: 3.0, through: 8.0, by: 1.0) {
            hike.routeWidth = width
            await settle(window)
        }

        #expect(inner.count > innerBefore, "precondition: the writes really did invalidate the query")
        #expect(
            outer.count == outerBefore,
            "the parent reads no hike, so a hike write must not re-evaluate it"
        )
    }

    /// The structural half, on the real views rather than on probes.
    ///
    /// A `@Query` is a stored property, so where it is declared is a fact
    /// about the type — and it is the only fact that decides which subtree
    /// SwiftData invalidates. Checking it here means re-adding one to the
    /// sheet's chrome fails a test rather than quietly costing a body pass per
    /// touch, which is exactly the sort of regression that is invisible until
    /// someone profiles a slider drag.
    @Test("the query lives in the leaf, not in the sheet's chrome")
    func onlyTheLeafDeclaresTheQuery() throws {
        let container = try Fixture.modelContainer()
        let sheet = MapSheet(
            searchText: .constant(""),
            detent: .constant(.large),
            selectedHike: .constant(nil),
            path: .constant([]),
            highlight: RouteHighlight(),
            mapController: MapController()
        )
        #expect(
            !declaresQuery(sheet),
            "the sheet is the navigation stack the detail view's sliders write from"
        )

        let leaf = MapSheetHikes(
            searchText: "",
            isSearchFocused: false,
            isCompact: false,
            completer: SearchCompleter(),
            recorder: HikeRecorder(container: container, automaticallyRecovers: false),
            selectedHikeID: nil,
            onOpen: { _ in /* unused */ },
            onSelectResult: { _ in /* unused */ },
            onSelectCompletion: { _ in /* unused */ },
            onDelete: { _, _ in /* unused */ },
            onRecord: { /* unused */ },
            onImport: { /* unused */ }
        )
        #expect(declaresQuery(leaf), "and it is the leaf that pays for it")
    }

    /// Names the property wrappers a view stores. `@Query` is one of them, so
    /// its presence is visible without rendering anything.
    private func declaresQuery(_ view: some View) -> Bool {
        Mirror(reflecting: view).children.contains { child in
            String(describing: type(of: child.value)).hasPrefix("Query<")
        }
    }
}
