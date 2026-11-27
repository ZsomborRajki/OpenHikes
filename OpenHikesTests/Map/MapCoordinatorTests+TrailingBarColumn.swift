//
//  MapCoordinatorTests+TrailingBarColumn.swift
//  OpenHikesTests
//
//  Where the pill on the trailing edge stands once the system keeps a column
//  for it beyond the safe area, as a closed iPhone Duo does: in the column,
//  with the 2D button over it, and under the status items at the column's top.
//
//  No simulator the gates run on has such a column, and a map here has no
//  window to ask. So the column is handed to the pill's placement as the
//  coordinator hands it over, with the figures the cover display answered —
//  see `TrailingBarColumnTests` for which windows have one.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
extension MapCoordinatorTests {
    /// The cover display of a closed iPhone Duo.
    private static let coverWidth: CGFloat = 466
    private static let coverHeight: CGFloat = 678
    /// Where the sheet's middle detent rests on it, measured.
    private static let coverMiddleDetent: CGFloat = 321
    private static let rowSpacing: CGFloat = 16

    /// A map the size of the cover display, with the pill in its column.
    ///
    /// Sized first: a map that changes height asks the system for its column
    /// again, and a map with no window has none.
    private func coverMap(_ coordinator: MapView.Coordinator) throws -> (map: MKMapView, column: TrailingBarColumn) {
        let map = makeMap(mapView(), coordinator)
        map.frame = CGRect(x: 0, y: 0, width: Self.coverWidth, height: Self.coverHeight)
        map.layoutIfNeeded()
        let column = try #require(TrailingBarColumnTests.closedDuo.column)
        coordinator.trackingPillPlacement?.stand(in: column)
        layOut(map)
        return (map, column)
    }

    /// Lays `map` out again. Asked for by name, because a constraint that
    /// changes on a view no window holds marks nothing as needing layout.
    private func layOut(_ map: MKMapView) {
        map.setNeedsLayout()
        map.layoutIfNeeded()
    }

    @Test("the pill stands in the column the system keeps beyond the safe area, and leaves it again")
    func trackingPillStandsInTheTrailingColumn() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trackingButton)
        let inSafeArea = map.safeAreaLayoutGuide.layoutFrame.maxX - MapView.controlInset
        #expect(pill.frame.maxX == inSafeArea)

        let column = try #require(TrailingBarColumnTests.closedDuo.column)
        coordinator.trackingPillPlacement?.stand(in: column)
        layOut(map)
        #expect(pill.frame.maxX == map.bounds.maxX - column.trailingInset)
        #expect(pill.frame.width == MapGlassPill.controlSize, "moved, not stretched between two edges")

        // A Duo unfolding: the inner display keeps no column.
        coordinator.trackingPillPlacement?.stand(in: nil)
        layOut(map)
        #expect(pill.frame.maxX == inSafeArea)
    }

    @Test("the 2D button stands over the pill in the column")
    func flattenButtonFollowsThePillIntoTheColumn() throws {
        let coordinator = MapView.Coordinator()
        let (map, column) = try coverMap(coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trackingButton)
        let flatten = try #require(coordinator.flattenButton)
        #expect(flatten.frame.maxX == map.bounds.maxX - column.trailingInset)
        #expect(flatten.frame.maxY == pill.frame.minY - (MapView.flattenButtonReach - MapGlassPill.controlSize))
    }

    /// The sheet's middle detent rests high enough on the cover display for
    /// the 2D button, standing on a pill 16 points over the sheet, to reach
    /// into the status items the column starts under. So the pill stops
    /// short, and the row across the map, with nothing over it, does not.
    @Test("in the column the pill stops where the 2D button clears the status items")
    func trackingPillStopsUnderTheColumnTop() throws {
        let coordinator = MapView.Coordinator()
        let (map, column) = try coverMap(coordinator)
        defer { detach(map) }
        let tracking = try #require(coordinator.trackingBottomConstraint)
        let credit = try #require(coordinator.attributionBottomConstraint)
        let pill = try #require(coordinator.trackingButton)
        let flatten = try #require(coordinator.flattenButton)

        // Low on the map, the pill rides the row.
        sheetMetrics.topY = Self.coverHeight - 100
        coordinator.applySheetTop(on: map)
        #expect(tracking.constant == sheetMetrics.topY - Self.rowSpacing)
        #expect(credit.constant == tracking.constant)

        sheetMetrics.topY = Self.coverMiddleDetent
        coordinator.applySheetTop(on: map)
        layOut(map)
        #expect(credit.constant == Self.coverMiddleDetent - Self.rowSpacing, "the row keeps its own limit")
        #expect(flatten.frame.minY == column.topInset, "the 2D button is clear of the column's top")
        #expect(pill.frame.maxY < Self.coverMiddleDetent, "and the pill is still above the sheet")
    }

    @Test("with no column the pill keeps the row's height at the same detent")
    func trackingPillKeepsTheRowWithoutAColumn() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        map.frame = CGRect(x: 0, y: 0, width: Self.coverWidth, height: Self.coverHeight)
        map.layoutIfNeeded()
        let tracking = try #require(coordinator.trackingBottomConstraint)
        let credit = try #require(coordinator.attributionBottomConstraint)

        sheetMetrics.topY = Self.coverMiddleDetent
        coordinator.applySheetTop(on: map)
        #expect(tracking.constant == Self.coverMiddleDetent - Self.rowSpacing)
        #expect(credit.constant == tracking.constant)
    }
}
#endif
