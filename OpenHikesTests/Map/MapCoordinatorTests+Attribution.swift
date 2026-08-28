//
//  MapCoordinatorTests+Attribution.swift
//  OpenHikesTests
//
//  Where the credit line ends up, now that it hangs beneath the weather badge
//  rather than riding the sheet at the bottom of the map.
//
//  It has two slots and no others: below the badge when there is a forecast to
//  show, and in the badge's own place when there is not. Nothing else moves
//  it, and in particular the sheet does not.
//
//  The badge itself cannot be measured from here, or from anywhere in this
//  hierarchy: it is a SwiftUI overlay drawn over the map rather than a subview
//  of it. So what these assert is the *slot* — that the line lands under where
//  the badge draws and lines up with its leading edge — computed from
//  ``WeatherBadge``'s own published geometry rather than from
//  ``MapView/addAttribution(to:_:alignedTo:)``'s arithmetic restated, which
//  would only ever agree with itself.
//
//  Test maps are 390x844 with no window, so `safeAreaInsets` is zero all round
//  and every number below is measured from the map's own edges.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

extension MapCoordinatorTests {
    /// The badge's height at the default text size, which is
    /// `.minimumTapTarget()`'s floor rather than the capsule's own size — the
    /// symbol and its padding come to a little under 44 points.
    private static let badgeHeight = MapPhotoControlsView.controlSize

    /// The whole point of the move: the line clears the bottom of the weather
    /// badge instead of sharing a row with it or sitting above it.
    ///
    /// A gap rather than a mere ordering, because the two are chrome of the
    /// same kind over live map imagery and a credit touching the badge reads
    /// as part of it.
    @Test("the credit line hangs below the weather badge")
    func attributionSitsBelowTheWeatherBadge() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let credit = try #require(coordinator.attributionView)
        map.layoutIfNeeded()

        let badgeBottom = WeatherBadge.topPadding + Self.badgeHeight
        #expect(!credit.isHidden, "there is a line to place")
        #expect(credit.frame.minY >= badgeBottom, "the credit line runs under the badge")
        #expect(credit.frame.minY - badgeBottom < 24, "the credit line has drifted off the badge")
        #endif
    }

    /// Left-aligned *with the badge*, not merely near the edge. The two are
    /// laid out by different frameworks against different anchors, so the only
    /// thing making them a column is that both read
    /// ``WeatherBadge/leadingPadding``.
    @Test("the credit line lines up with the weather badge's leading edge")
    func attributionAlignsWithTheWeatherBadge() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let credit = try #require(coordinator.attributionView)
        map.layoutIfNeeded()

        #expect(credit.frame.minX == map.safeAreaInsets.left + WeatherBadge.leadingPadding)
        #endif
    }

    /// Chrome near the top of the map, not a control riding the sheet.
    ///
    /// The tracking button is the comparison because it is the thing that does
    /// ride it, and because the credit line used to sit below it.
    @Test("the credit line sits at the top of the map")
    func attributionSitsAtTheTop() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let credit = try #require(coordinator.attributionView)
        let button = try #require(coordinator.trackingButton)
        map.layoutIfNeeded()

        #expect(credit.frame.maxY < map.bounds.midY)
        #expect(credit.frame.maxY < button.frame.minY)
        #endif
    }

    /// Without a forecast there is no badge, and the line stands in for it
    /// rather than hanging under an empty space.
    ///
    /// The badge's exact slot, not merely "higher": these are the only two
    /// positions this view has, and the one it falls back to is the one the
    /// badge would have had.
    @Test("with no weather badge the credit line takes its place")
    func attributionTakesTheBadgesPlaceWhenItIsAbsent() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(showsWeatherBadge: false), coordinator)
        defer { detach(map) }
        let credit = try #require(coordinator.attributionView)
        map.layoutIfNeeded()

        #expect(credit.frame.minY == WeatherBadge.topPadding)
        #expect(credit.frame.minX == map.safeAreaInsets.left + WeatherBadge.leadingPadding)
        #endif
    }

    /// The forecast arrives after launch, so both slots are reached through
    /// `update(_:_:)` rather than only at build time — and the line has to
    /// move out of the badge's way when it does.
    @Test("the credit line moves aside when a forecast arrives")
    func attributionMovesWhenTheBadgeAppears() throws {
        #if os(iOS)
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(showsWeatherBadge: false), coordinator)
        defer { detach(map) }
        let credit = try #require(coordinator.attributionView)
        map.layoutIfNeeded()
        let withoutBadge = credit.frame.minY

        mapView(showsWeatherBadge: true).update(map, coordinator)
        map.layoutIfNeeded()

        #expect(credit.frame.minY > withoutBadge, "the credit line stayed under the badge")
        #expect(credit.frame.minY >= WeatherBadge.topPadding + Self.badgeHeight)
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
        map.layoutIfNeeded()

        #expect(credit.frame.maxX <= map.bounds.width - map.safeAreaInsets.right)
        #endif
    }
}
