//
//  MapCoordinatorTests+MapModes.swift
//  OpenHikesTests
//
//  The pill on the trailing edge: the map-modes button over the "my location"
//  button, in one capsule, as Maps has them. What the upper half raises is
//  SwiftUI's to present, so what is tested here is that it is raised.
//

import MapKit
@testable import OpenHikes
import Testing
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
extension MapCoordinatorTests {
    /// The button in the upper half of the pill, found as a thumb finds it.
    private func mapModesButton(_ coordinator: MapView.Coordinator) throws -> UIButton {
        let pill = try #require(coordinator.trackingButton as? UIVisualEffectView)
        let stack = try #require(pill.contentView.subviews.compactMap { $0 as? UIStackView }.first)
        return try #require(stack.arrangedSubviews.first as? UIButton)
    }

    @Test("the pill holds the map-modes button over the location button")
    func thePillHoldsBothButtons() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trackingButton)
        let modes = try mapModesButton(coordinator)
        let location = try #require(coordinator.trackingGlyph)

        #expect(pill.frame.width == MapGlassPill.controlSize)
        #expect(pill.frame.height == MapGlassPill.controlSize * 2, "one control for each button")
        let modesFrame = modes.convert(modes.bounds, to: pill)
        let locationFrame = location.convert(location.bounds, to: pill)
        #expect(modesFrame.height == MapGlassPill.controlSize, "a whole tap target of its own")
        #expect(modesFrame.maxY <= locationFrame.minY, "over the arrow, not on it")
        #expect(modes.accessibilityLabel == "Map Modes")
    }

    @Test("a tap on the map-modes button asks for Map Modes")
    func tapRaisesMapModes() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        #expect(!mapModes.isPresented, "precondition: nothing showing")

        try mapModesButton(coordinator).sendActions(for: .primaryActionTriggered)

        #expect(mapModes.isPresented)
    }

    @Test("a tap on the map-modes button opens nothing under it")
    func tapOnTheMapModesButtonIsClaimed() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let modes = try mapModesButton(coordinator)
        let frame = modes.convert(modes.bounds, to: map)

        #expect(coordinator.isTapClaimed(at: CGPoint(x: frame.midX, y: frame.midY), in: map))
    }

    @Test("the refused location button keeps to the lower half")
    func theRefusedButtonLeavesMapModesAlone() throws {
        let coordinator = MapView.Coordinator()
        let map = makeMap(mapView(), coordinator)
        defer { detach(map) }
        let pill = try #require(coordinator.trackingButton)
        let modes = try mapModesButton(coordinator)
        let refused = try #require(coordinator.refusedTrackingButton)

        let modesFrame = modes.convert(modes.bounds, to: pill)
        let refusedFrame = refused.convert(refused.bounds, to: pill)
        #expect(!modesFrame.intersects(refusedFrame), "a refusal must not cover the way to another map")
    }
}
#endif
