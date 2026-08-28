//
//  MapCoordinator+Attribution.swift
//  OpenHikes
//
//  Keeping the credit line in the right one of its two slots at the top of the
//  map.
//
//  The line takes no part in the row `applySheetTop(on:)` drives, which is the
//  whole reason this is a separate, much smaller piece of arithmetic than the
//  one next door. See ``MapView/addAttribution(to:_:alignedTo:)`` for why it
//  sits where it does and why the weather badge cannot simply be anchored
//  against.
//
//  What is left is one constant that is not constant. Two things move it: the
//  forecast arriving or going away, which decides whether the line hangs below
//  the badge or stands in for it; and the reader's text size, which changes
//  how tall the badge draws. The first reaches here through `update(_:_:)`.
//  The second needs a trait registration, because a content size category
//  change moves nothing else this map observes — no bounds change, no sheet
//  report, and so no `update(_:_:)` pass to piggyback on.
//

import MapKit
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
extension MapView.Coordinator {
    /// How long the line takes to move between its two slots.
    ///
    /// Animated because the move is real and rare — a forecast arriving a
    /// second or two after launch — and an unannounced 56-point jump in a
    /// legal notice reads as a glitch rather than as a layout. Short enough
    /// not to draw attention to itself.
    private static let attributionMoveDuration: TimeInterval = 0.25

    /// Puts the credit line in the slot the current state calls for.
    ///
    /// Idempotent, and deliberately so: this is called from `update(_:_:)`,
    /// which runs on every SwiftUI pass. Writing an unchanged `constant` still
    /// invalidates the map's layout, and the map is the one view here that
    /// cannot afford a free layout pass.
    func applyAttributionClearance(on mapView: MKMapView) {
        guard let attributionTopConstraint else { return }
        let wanted = MapView.attributionTop(
            in: mapView,
            belowWeatherBadge: showsWeatherBadge
        )
        guard attributionTopConstraint.constant != wanted else { return }
        attributionTopConstraint.constant = wanted
        // Explicitly, because the write above only flags the map as needing
        // its constraints updated — not as needing layout. Without this the
        // line sits at its old offset until something unrelated happens to
        // lay the map out, and the animation below has nothing to animate.
        mapView.setNeedsLayout()

        // Only once there is something to animate *from*. Before the map is in
        // a window the first application is the line's initial position, and
        // animating that slides it in from wherever Auto Layout had left it.
        guard mapView.window != nil else { return }
        UIView.animate(withDuration: Self.attributionMoveDuration) {
            mapView.layoutIfNeeded()
        }
    }

    /// Recomputes the offset when the reader's text size changes.
    ///
    /// Registered against the map rather than the credit line: the badge is
    /// the view whose height is changing, and it is neither of these two.
    ///
    /// Through `onMainActor` for the reason every `nonisolated` callback here
    /// is — the handler is not isolated, and a trait change already arrives on
    /// the main thread, so this is the synchronous path rather than a task.
    func trackContentSizeCategory(on mapView: MKMapView) {
        attributionTraitRegistration = mapView.registerForTraitChanges(
            [UITraitPreferredContentSizeCategory.self]
        ) { [weak self] (map: MKMapView, _) in
            onMainActor { self?.applyAttributionClearance(on: map) }
        }
    }
}
#endif
