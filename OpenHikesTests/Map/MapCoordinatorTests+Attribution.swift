//
//  MapCoordinatorTests+Attribution.swift
//  OpenHikesTests
//
//  Where the credit line ends up, now that it is the bottom of the map's
//  leading-edge stack rather than a notice pinned under the weather badge.
//
//  Three claims, and they are the whole of the placement. It sits on the
//  leading edge at the same inset the camera pill takes. Its bottom is the row
//  the sheet drives, level with the "my location" button opposite it — which
//  ``MapCoordinatorTests+SheetInsets`` holds across a whole drag. And the
//  camera pill sits directly above it, a small fixed gap up, whatever the line
//  itself is doing: one credit or three, one row or two.
//
//  The pill's gap is asserted against ``MapView/creditLineSpacing`` rather
//  than a number repeated here, because the two would agree with each other
//  and with nothing else. What is not the constant is the *relationship* —
//  above, not below; measured from the line's own frame, so a credit that
//  wraps moves the pill with it.
//
//  Test maps are 390x844 with no window, so `safeAreaInsets` is zero all round
//  and every number below is measured from the map's own edges.
//

import Foundation
import MapKit
@testable import OpenHikes
import RealModule
import Testing

extension MapCoordinatorTests {
    /// The move itself: the line is down on the sheet's edge with the
    /// controls, not up at the top of the map with the compass.
    @Test("the credit line rides the sheet beside the tracking button")
    func attributionSitsOnTheControlRow() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let credit = try #require(coordinator.attributionView)
        let button = try #require(coordinator.trackingButton)
        let sheetTop = map.bounds.height * 0.45
        sheetMetrics.topY = sheetTop
        coordinator.applySheetTop(on: map)
        layOut(map)

        #expect(!credit.isHidden, "there is a line to place")
        #expect(credit.frame.maxY < sheetTop, "the line is above the sheet's edge")
        #expect(sheetTop - credit.frame.maxY < 24, "and it is on that edge, not adrift of it")
        #expect(
            credit.frame.maxY.isApproximatelyEqual(to: button.frame.maxY, absoluteTolerance: 1),
            "the line and the tracking button are one row"
        )
        #endif
    }

    /// Left-aligned with the camera pill above it, and at the control inset
    /// rather than the map's own edge: in landscape the map's edge is under
    /// the notch and behind the side panel, and a credit the reader cannot see
    /// is not a credit.
    @Test("the credit line lines up with the camera pill")
    func attributionAlignsWithTheCameraPill() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let credit = try #require(coordinator.attributionView)
        let pill = try #require(coordinator.photoControls)
        layOut(map)

        #expect(credit.frame.minX == pill.frame.minX)
        #expect(credit.frame.minX > map.safeAreaInsets.left)
        #endif
    }

    /// The pill is above the line, close enough to read as one stack. Both
    /// halves matter: *above*, which is the order, and the gap, which is what
    /// keeps it from reading as two unrelated pieces of chrome.
    @Test("the camera pill sits just above the credit line")
    func cameraPillSitsAboveTheCreditLine() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let credit = try #require(coordinator.attributionView)
        let pill = try #require(coordinator.photoControls)
        layOut(map)

        #expect(
            (credit.frame.minY - pill.frame.maxY).isApproximatelyEqual(
                to: MapView.creditLineSpacing,
                absoluteTolerance: 1
            ),
            "the pill is not sitting on the credit line"
        )
        #endif
    }

    /// A credit that wraps has to push the pill up rather than draw underneath
    /// it. Nothing recomputes anything to make that happen — the pill hangs
    /// off the line's top edge — and this is what would catch a later change
    /// back to an arithmetic offset.
    ///
    /// Wrapped by narrowing the map rather than by a longer credit, because
    /// the longest one any provider here asks for still fits on one row at
    /// phone width. What is being tested is the height changing at all.
    @Test("a credit that wraps takes the camera pill up with it")
    func cameraPillFollowsAWrappedCreditLine() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let credit = try #require(coordinator.attributionView)
        let pill = try #require(coordinator.photoControls)
        credit.update(with: TileProvider.stadiaOutdoors.attribution)
        layOut(map)
        let oneRow = credit.frame.height
        let pillAboveOneRow = pill.frame.maxY

        map.frame = CGRect(x: 0, y: 0, width: 200, height: map.bounds.height)
        layOut(map)

        #expect(credit.frame.height > oneRow, "the credit did not wrap")
        #expect(pill.frame.maxY < pillAboveOneRow, "the pill stayed where the shorter line was")
        #expect(
            (credit.frame.minY - pill.frame.maxY).isApproximatelyEqual(
                to: MapView.creditLineSpacing,
                absoluteTolerance: 1
            )
        )
        #endif
    }

    /// The system base map draws no line of ours, and the pill must not be
    /// left hanging over the space one would have taken: a hidden view is
    /// still laid out, so this is the case the second constraint exists for.
    @Test("with nothing to credit the camera pill takes the line's place")
    func cameraPillClosesTheGapWithoutACreditLine() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(tileSource: nil), coordinator)
        defer { detach(map) }
        let credit = try #require(coordinator.attributionView)
        let pill = try #require(coordinator.photoControls)
        let button = try #require(coordinator.trackingButton)
        sheetMetrics.topY = map.bounds.height * 0.45
        coordinator.applySheetTop(on: map)
        layOut(map)

        #expect(credit.isHidden)
        #expect(
            pill.frame.maxY.isApproximatelyEqual(to: button.frame.maxY, absoluteTolerance: 1),
            "without a line to clear, the pill is level with the tracking button"
        )
        #endif
    }

    /// And back again when a provider of ours is selected, because the source
    /// changes while the map is up — from Settings, on any launch.
    @Test("selecting a credited source makes room for the line again")
    func cameraPillMakesRoomWhenACreditArrives() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let view = mapView(tileSource: nil)
        let map = makeMap(view, coordinator)
        defer { detach(map) }
        let credit = try #require(coordinator.attributionView)
        let pill = try #require(coordinator.photoControls)
        // Applied before and after, so the only thing that moves the pill
        // between the two readings is the line appearing.
        coordinator.applySheetTop(on: map)
        layOut(map)
        let withoutCredit = pill.frame.maxY

        mapView().update(map, coordinator)
        layOut(map)

        #expect(!credit.isHidden)
        #expect(pill.frame.maxY < withoutCredit, "the pill did not make room for the line")
        #expect(
            (credit.frame.minY - pill.frame.maxY).isApproximatelyEqual(
                to: MapView.creditLineSpacing,
                absoluteTolerance: 1
            )
        )
        #endif
    }

    /// A credit is as wide as the parties it names, and one provider names
    /// three. The ceiling is what makes a long one wrap inside the map rather
    /// than run off its trailing edge.
    @Test("a long credit wraps inside the map rather than overflowing it")
    func aLongCreditStaysInsideTheMap() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let credit = try #require(coordinator.attributionView)
        credit.update(with: TileProvider.stadiaOutdoors.attribution)
        layOut(map)

        #expect(credit.frame.maxX <= map.bounds.width - map.safeAreaInsets.right)
        #endif
    }

    /// Lays the map out from scratch.
    ///
    /// `layoutIfNeeded` alone is not enough here: writing a constraint's
    /// constant marks the map as needing its constraints updated rather than
    /// as needing layout, and a map with no window has nothing else coming
    /// along to lay it out. The app's own passes are what stand in for this.
    private func layOut(_ map: MKMapView) {
        map.setNeedsLayout()
        map.layoutIfNeeded()
    }
}
