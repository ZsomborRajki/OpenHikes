//
//  QueryEarlierCopyTests.swift
//  OpenHikesTests
//
//  What the hikes list's order capsule leans on. A pass of the list that
//  leaves the capsule as it was keeps the capsule from an earlier pass, binding
//  and all (`SortMenu+Equatable.swift`), and choosing an order writes through
//  that binding, whose setter asks the list's `@Query` whether a hand-made
//  order is in force and clears it. So a copy of the list from an earlier pass
//  has to read the hikes as they are now: one added since is among them, and
//  one deleted since is not.
//
//  The answer is SwiftData's rather than the app's, so it is measured on a
//  hosted hierarchy, as `SheetQueryIsolationTests` measures what a query wakes.
//

import Foundation
@testable import OpenHikes
import OpenHikesData
import SwiftData
import SwiftUI
import Testing

/// The reads of each copy of the probe kept: its first pass's and its latest.
@MainActor
private final class CopyReads {
    var first: (() -> [UUID])?
    var latest: (() -> [UUID])?
}

/// A view holding the hikes list's query, which hands out a read of its
/// hikes made through the copy of itself each pass ran on, as a binding the
/// list builds in a pass reads them.
private struct QueryCopyProbe: View {
    let reads: CopyReads
    @Query(sort: \Hike.date, order: .reverse) private var hikes: [Hike]

    var body: some View {
        let copy = self
        let read = { copy.hikes.map(\.id) }
        if reads.first == nil { reads.first = read }
        reads.latest = read
        return Text(verbatim: "\(hikes.count)")
    }
}

@MainActor
@Suite("A query read through an earlier copy of its view")
struct QueryEarlierCopyTests {
    /// Hosted in the app's own scene, as `SheetQueryIsolationTests` hosts its
    /// probes: a scene-less window never lays out.
    private func host(_ view: some View, in container: ModelContainer) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first,
            "app-hosted tests run inside the app, which has a scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view.modelContainer(container))
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    @Test("reads the hikes as they are now, not as they were on its pass")
    func readsTheHikesAsTheyAreNow() async throws {
        let container = try Fixture.modelContainer()
        let context = container.mainContext
        let first = Fixture.hike(in: context, title: "First")
        try context.save()
        let reads = CopyReads()
        let window = try host(QueryCopyProbe(reads: reads), in: container)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        await settleDelegateHop(until: "the probe's first pass") { reads.first?() == [first.id] }

        let second = Fixture.hike(in: context, title: "Second")
        second.date = first.date.addingTimeInterval(60)
        try context.save()
        await settleDelegateHop(until: "a pass that reads the added hike") {
            reads.latest?() == [second.id, first.id]
        }
        #expect(reads.first?() == [second.id, first.id], "a hike added since is among them")

        context.delete(first)
        try context.save()
        await settleDelegateHop(until: "a pass that has lost the deleted hike") { reads.latest?() == [second.id] }
        #expect(reads.first?() == [second.id], "a hike deleted since is not")
    }
}
