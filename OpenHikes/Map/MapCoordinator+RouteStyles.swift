//
//  MapCoordinator+RouteStyles.swift
//  OpenHikes
//
//  How the qualified stretches of a route are drawn: the inferred ones and
//  the paused ones, both derived from the route's own tint and width so they
//  cannot drift from the line they sit on.
//
//  Split out of `MapCoordinator.swift` for the reason the highlight dot and
//  the walk's stretches were: that file is the observation plumbing, and it
//  had reached its length. Internal rather than private, which is what a
//  file split costs in Swift — `rendererFor` next door is what calls these.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension MapView.Coordinator {
    /// Faded, but well clear of the basemap: a stretch the app is less
    /// sure about still has to be followable on a printed-looking map.
    private static let inferredRouteAlpha: CGFloat = 0.55
    /// The dashed line is drawn a little wider than the solid one so that
    /// fading it doesn't also make it thinner to the eye.
    private static let inferredRouteWidthFactor: CGFloat = 1.35
    private static let inferredRouteDashPattern: [Int] = [2, 7]
    /// A pause is drawn fainter still than an inferred stretch: the app
    /// has no claim at all about this ground, not merely a weak one.
    private static let pausedRouteAlpha: CGFloat = 0.4
    /// Dotted where the inferred line is dashed, which is what separates
    /// the two at a glance on a route that carries both.
    private static let pausedRouteDashPattern: [Int] = [1, 6]

    /// The route's own tint, drawn dashed and faded.
    ///
    /// Deliberately the same colour rather than a warning one: this stretch is
    /// still the hiker's route, and the app's claim about it is weaker, not
    /// alarming. The dash is what carries the meaning — a broken line for the
    /// part of the walk the recording didn't see — and keeping the tint means
    /// a hike recoloured by its owner stays recoloured throughout.
    ///
    /// Left as a plain `MKPolylineRenderer`: the directional chevrons state a
    /// travel direction along the line, which is exactly what isn't known here.
    func inferredRouteRenderer(
        for polyline: MKPolyline
    ) -> MKPolylineRenderer {
        let renderer = MKPolylineRenderer(polyline: polyline)
        applyInferredStyle(to: renderer)
        return renderer
    }

    /// Applies the paused-stretch appearance.
    ///
    /// Built on the inferred one rather than beside it: both are the route's
    /// own tint drawn weakly over ground the line crosses without evidence,
    /// and the walker should not have to learn two visual languages for that.
    /// The dots and the extra fade are what say which of the two this is —
    /// nobody was watching, versus nobody was asked to.
    ///
    /// Left a plain `MKPolylineRenderer` for the reason the inferred one is:
    /// a direction along this stretch is precisely what isn't known.
    func applyPausedStyle(to renderer: MKPolylineRenderer) {
        applyInferredStyle(to: renderer)
        #if os(macOS)
        renderer.strokeColor = NSColor(routeTint)
            .withAlphaComponent(Self.pausedRouteAlpha)
        #else
        renderer.strokeColor = UIColor(routeTint)
            .withAlphaComponent(Self.pausedRouteAlpha)
        #endif
        // swiftlint:disable:next legacy_objc_type
        renderer.lineDashPattern = Self.pausedRouteDashPattern.map { NSNumber(value: $0) }
        renderer.lineCap = .round
    }

    /// Applies the inferred-stretch appearance, derived from the route's
    /// current tint and width so the two never drift apart.
    func applyInferredStyle(to renderer: MKPolylineRenderer) {
        #if os(macOS)
        renderer.strokeColor = NSColor(routeTint)
            .withAlphaComponent(Self.inferredRouteAlpha)
        #else
        renderer.strokeColor = UIColor(routeTint)
            .withAlphaComponent(Self.inferredRouteAlpha)
        #endif
        renderer.lineWidth = CGFloat(routeWidth) * Self.inferredRouteWidthFactor
        // swiftlint:disable:next legacy_objc_type
        renderer.lineDashPattern = Self.inferredRouteDashPattern.map { NSNumber(value: $0) }
        renderer.lineJoin = .round
        renderer.lineCap = .butt
    }
}
