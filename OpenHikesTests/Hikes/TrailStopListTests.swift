//
//  TrailStopListTests.swift
//  OpenHikesTests
//
//  The UIKit list the maker's stops are drawn in — see ``TrailStopList`` for
//  why it is UIKit at all. What a suite can reach without a finger: which stop
//  a drop moved and where it went, which rows a swipe may delete, and the one
//  row height the list is sized by.
//
//  The drag itself is `TrailMakerUITests.testReorderingThePoints`, and the
//  swipe `testRemovingAStop`; only a simulator can press a grabber.
//

import CoreLocation
import Foundation
@testable import OpenHikes
import Testing
import UIKit

@MainActor
@Suite("Trail stop list")
struct TrailStopListTests {
    private typealias Coordinator = TrailStopList.Coordinator

    /// What the list's closures were handed.
    private final class Calls {
        var searched = 0
        var moved = 0
        var stepped = 0
        var deleted: [UUID] = []
    }

    private static func draft(points: Int) -> TrailDraft {
        let draft = TrailDraft()
        for index in 0..<points {
            draft.addStop(CLLocationCoordinate2D(latitude: 37.33 + Double(index) * 0.002, longitude: -122.03))
        }
        return draft
    }

    private static func list(_ draft: TrailDraft, calls: Calls) -> TrailStopList {
        TrailStopList(
            draft: draft,
            onSearch: { _ in calls.searched += 1 },
            onMove: { _, _ in calls.moved += 1 },
            onStep: { _, _ in calls.stepped += 1 },
            onDelete: { calls.deleted.append($0) }
        )
    }

    /// A coordinator installed in a real collection view and showing `draft`.
    private static func coordinator(showing draft: TrailDraft, calls: Calls) -> Coordinator {
        let coordinator = Coordinator()
        let view = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 400),
            collectionViewLayout: UICollectionViewCompositionalLayout.list(
                using: UICollectionLayoutListConfiguration(appearance: .plain)
            )
        )
        coordinator.install(in: view)
        coordinator.list = list(draft, calls: calls)
        coordinator.show(draft.slots, of: draft)
        return coordinator
    }

    // MARK: A drop

    @Test("a stop dropped between two others goes in front of the one after it")
    func aDropNamesTheStopItNowPrecedes() {
        let draft = Self.draft(points: 3)
        let ids = draft.slots.map(\.id)
        let waypoints = draft.waypoints.map(\.id)

        let drop = Coordinator.drop(of: ids[2], in: [ids[0], ids[2], ids[1]], slots: draft.slots)

        #expect(drop == Coordinator.Drop(stop: waypoints[2], before: waypoints[1]))
    }

    @Test("a stop dropped last goes to the end")
    func aDropAtTheBottomIsTheEnd() {
        let draft = Self.draft(points: 3)
        let ids = draft.slots.map(\.id)

        let drop = Coordinator.drop(of: ids[0], in: [ids[1], ids[2], ids[0]], slots: draft.slots)

        #expect(drop == Coordinator.Drop(stop: draft.waypoints[0].id, before: nil))
    }

    /// An open field has no waypoint behind it, so there is nothing for the
    /// draft to move — and the list never lets one be picked up anyway.
    @Test("an open field is never a stop that moved")
    func anOpenFieldIsNotADrop() {
        let draft = Self.draft(points: 0)
        let ids = draft.slots.map(\.id)

        #expect(Coordinator.drop(of: ids[1], in: [ids[1], ids[0]], slots: draft.slots) == nil)
    }

    // MARK: A swipe

    @Test("a filled stop swipes to Delete, and Delete removes that stop")
    func aStopSwipesToDelete() throws {
        let draft = Self.draft(points: 2)
        let calls = Calls()
        let coordinator = Self.coordinator(showing: draft, calls: calls)

        let configuration = try #require(coordinator.swipeActions(at: IndexPath(item: 1, section: 0)))
        let delete = try #require(configuration.actions.first)
        #expect(configuration.actions.count == 1)
        #expect(delete.style == .destructive)
        #expect(delete.title == String(localized: "Delete"))

        delete.handler(delete, UIView()) { _ in
            // UIKit's own completion, which only closes the swipe.
        }
        #expect(calls.deleted == [draft.waypoints[1].id])
        #expect(calls.searched + calls.moved + calls.stepped == 0, "a swipe does nothing else")
    }

    @Test("an open field has nothing to swipe")
    func anOpenFieldHasNoSwipe() {
        let coordinator = Self.coordinator(showing: Self.draft(points: 0), calls: Calls())

        #expect(coordinator.swipeActions(at: IndexPath(item: 0, section: 0)) == nil)
        #expect(coordinator.rowCount == 2)
    }

    // MARK: The row height

    /// Whole points, because a fractional one reaches the cell a hair over its
    /// pixels and every row comes out a third of a point taller than the list
    /// was sized for — see ``TrailStopList/Coordinator/rowHeight(for:)``.
    @Test("a row is a whole number of points, and grows with the type size")
    func theRowHeightIsWholeAndScales() {
        let coordinator = Coordinator()
        let large = coordinator.rowHeight(for: UITraitCollection(preferredContentSizeCategory: .large))
        let larger = coordinator.rowHeight(for: UITraitCollection(preferredContentSizeCategory: .accessibilityLarge))

        #expect(large == large.rounded())
        #expect(large >= 2 * TrailStopRowView.rowPadding + 17)
        #expect(larger > large)
    }
}
