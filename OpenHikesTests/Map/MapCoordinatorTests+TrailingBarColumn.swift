//
//  MapCoordinatorTests+TrailingBarColumn.swift
//  OpenHikesTests
//
//  Where the pill on the trailing edge stands once the system keeps a column
//  for it beyond the safe area, as a closed iPhone Duo does: in the column,
//  with the 2D button over it, level with the row across the map, and under
//  the status items at the column's top.
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
    /// A sheet dragged nearly to the top of the map.
    private static let nearTheTop: CGFloat = 8

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
        #expect(flatten.frame.maxY < pill.frame.minY)
    }

    /// One row across the map, by the owner's decision: at the cover display's
    /// middle detent the pill stands 16 points over the sheet as the credit
    /// line opposite does, and the 2D button on it is left close under the
    /// status items — see `MapTrailingBarColumn.swift`.
    @Test("in the column the pill keeps the row's height at the middle detent")
    func trackingPillKeepsTheRowInTheColumn() throws {
        let coordinator = MapView.Coordinator()
        let (map, _) = try coverMap(coordinator)
        defer { detach(map) }
        let tracking = try #require(coordinator.trackingBottomConstraint)
        let credit = try #require(coordinator.attributionBottomConstraint)

        sheetMetrics.topY = Self.coverMiddleDetent
        coordinator.applySheetTop(on: map)
        #expect(tracking.constant == Self.coverMiddleDetent - Self.rowSpacing)
        #expect(credit.constant == tracking.constant)
    }

    /// The cover display gives the map no top inset, and its status items
    /// stand at the top of the column. So a sheet carried to the top leaves
    /// the row under the column's top, where on any other display it leaves
    /// it under the map's own inset.
    @Test("in the column the row stops under the status items, as one row")
    func rowStopsUnderTheColumnTop() throws {
        let coordinator = MapView.Coordinator()
        let (map, column) = try coverMap(coordinator)
        defer { detach(map) }
        let tracking = try #require(coordinator.trackingBottomConstraint)
        let credit = try #require(coordinator.attributionBottomConstraint)
        let pill = try #require(coordinator.trackingButton)

        sheetMetrics.topY = Self.nearTheTop
        coordinator.applySheetTop(on: map)
        layOut(map)
        #expect(pill.frame.minY == column.topInset + Self.rowSpacing)
        #expect(credit.constant == tracking.constant)

        // Unfolded, there is no column and the map's own inset is the limit.
        coordinator.trackingPillPlacement?.stand(in: nil)
        coordinator.applySheetTop(on: map)
        layOut(map)
        #expect(pill.frame.minY == map.safeAreaInsets.top + Self.rowSpacing)
    }
}
#endif
