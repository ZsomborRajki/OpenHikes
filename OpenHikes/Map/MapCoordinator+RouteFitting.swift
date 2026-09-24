//
//  MapCoordinator+RouteFitting.swift
//  OpenHikes
//
//  Putting something on screen: which part of the map counts as "on screen",
//  and the arithmetic that is easy to get subtly wrong in a second copy.
//
//  Split out of `MapCoordinator.swift` for the reason the walk highlight and
//  the tracking button were — the coordinator's own file is the observation
//  plumbing — and because there are several callers now rather than one. The
//  hiker's own route is fitted here by the initial draw and the detail view's
//  Zoom button; a shared hike's route is fitted by the preview that opened it;
//  and a searched place or a photograph's pin is shown through the same
//  measurement. See `MapCommunityRoutes.swift` and `MapState.swift`.
//
//  ## The focus area
//
//  The map fills the window and something is always drawn over part of it:
//  ``MapSheet`` in portrait, ``MapSidePanel`` in landscape. A camera move that
//  ignores them frames what it is aiming at into the *window*, which puts the
//  bottom half of a route behind the sheet and the leading edge of one behind
//  the panel — the half of the walk the hiker asked to see is the half they
//  cannot.
//
//  So every camera move measures the same thing first: how much of the map is
//  covered, and on which physical edge. ``obstructionInsets(in:)`` is that
//  measurement and nothing else, which is what lets a route fit and a search
//  result share it while disagreeing about everything else — a route wants
//  breathing room around the line, and a search's `boundingRegion` already has
//  its own framing that nobody here should be adding to.
//
//  The portrait number is the sheet at its **middle** detent, not wherever the
//  sheet happens to be. Every path that moves the camera also puts the sheet
//  there — see ``SheetPresentation/makeRoomForTheMap()`` — so the middle detent
//  is where the sheet is about to be, and measuring the sheet's *current* top
//  would frame against the height it is animating away from.
//
//  MapKit's padding is in *physical* edges and the panel occupies a *leading*
//  one, so the conversion between them — including the safe area the panel is
//  positioned inside — belongs in exactly one place.
//
//  And MapKit does not measure that padding from the edge of the map: it
//  measures it from the map's layout margins, which ``MapView`` has already
//  pushed off the leading edge for the panel's sake. The panel is therefore
//  easy to pay for twice, and a camera asked for more padding than it has map
//  does not come back cramped — it comes back wrong. See ``setVisible``.
//

import MapKit
import OpenHikesData

extension MapView.Coordinator {
    /// Fits the currently drawn route into the focus area. Shared by the
    /// initial draw and the detail view's Zoom button.
    func fitToCurrentRoute(_ mapView: MKMapView, animated: Bool) {
        guard let polyline = routeOverlay else { return }
        fit(polyline.boundingMapRect, on: mapView, animated: animated)
    }

    /// Puts `rect` on screen inside the route padding *and* the focus area.
    ///
    /// Its own method because a shared hike's line is fitted the same way the
    /// hiker's own route is — see `MapCommunityRoutes.swift`.
    func fit(_ rect: MKMapRect, on mapView: MKMapView, animated: Bool) {
        var insets = obstructionInsets(in: mapView)
        insets.top += Self.routeInsets.top
        insets.bottom += Self.routeInsets.bottom
        insets.left += Self.routeInsets.left
        insets.right += Self.routeInsets.right
        setVisible(rect, on: mapView, edgePadding: insets, animated: animated)
    }

    /// Shows `region` inside the focus area, with no padding of its own.
    ///
    /// The difference from ``fit(_:on:animated:)`` is deliberate and is the
    /// whole reason the two are separate. A route is a line and wants air
    /// around it; a region was chosen by whoever asked — a search result's
    /// `boundingRegion`, the span a photograph's pin is shown at — and adding
    /// sixty points of route padding to it would zoom out of a framing
    /// somebody already decided. What it does need is the same obstruction
    /// measurement, because a photograph centred in the *window* is a
    /// photograph under the sheet.
    func show(_ region: MKCoordinateRegion, on mapView: MKMapView, animated: Bool) {
        setVisible(
            region.mapRect,
            on: mapView,
            edgePadding: obstructionInsets(in: mapView),
            animated: animated
        )
    }

    /// How much of the map is covered, per physical edge.
    ///
    /// Landscape and portrait are the two shapes and they never overlap: the
    /// panel replaces the sheet rather than joining it, so exactly one of the
    /// branches below contributes.
    func obstructionInsets(in mapView: MKMapView) -> MapEdgeInsets {
        var insets = MapEdgeInsets()
        #if canImport(UIKit)
        if sidePanelInset > 0 {
            // MapKit padding uses physical edges; the panel uses leading.
            // Include the safe area the panel itself is positioned inside.
            if mapView.effectiveUserInterfaceLayoutDirection == .rightToLeft {
                insets.right += sidePanelInset + mapView.safeAreaInsets.right
            } else {
                insets.left += sidePanelInset + mapView.safeAreaInsets.left
            }
        } else {
            insets.bottom += sheetOccupiedHeight(in: mapView)
        }
        #endif
        return insets
    }

    /// How much of the map's height the sheet takes at its middle detent.
    ///
    /// Measured where possible: ``SheetMetrics/middleRestY`` is learned by
    /// watching the sheet come to rest, because there is no fraction that
    /// works across devices — the system's medium detent rests 43% of the way
    /// down one phone and 48% down another.
    ///
    /// The fallback is a guess and it is deliberately the *pessimistic* one.
    /// Until the sheet has been seen resting there — the first draw of a launch
    /// that restored a selected hike is exactly that moment — the alternative
    /// to guessing is to frame against the whole window, which is the bug this
    /// exists to fix. Being a little too conservative costs a route some of the
    /// screen it could have had; being too generous puts it under the sheet.
    private func sheetOccupiedHeight(in mapView: MKMapView) -> CGFloat {
        let height = mapView.bounds.height
        guard let restY = sheetMetrics?.middleRestY, restY > 0, restY < height else {
            return height * Self.assumedMiddleDetentShare
        }
        return height - restY
    }

    /// Applies `edgePadding`, having first taken off what MapKit is going to
    /// add back and made sure there is a viewport left to apply it to.
    ///
    /// ## What MapKit counts twice
    ///
    /// `setVisibleMapRect(_:edgePadding:animated:)` frames into the map's
    /// **layout margins**, not into its bounds: whatever is passed here is
    /// added to `directionalLayoutMargins` rather than measured from the edge
    /// of the view. Those margins are not incidental — ``MapView`` sets the
    /// leading one to the width of ``MapSidePanel`` so MapKit's own compass and
    /// scale clear it — so in landscape the panel was being paid for twice, at
    /// 344 points a go. On an iPhone 18 Pro that is 884 points of left padding
    /// on an 874-point-wide map: no viewport at all, and
    /// `setVisibleMapRect` answers a request like that with a camera that puts
    /// the route off the trailing edge of the screen. Measured on a route that
    /// should have spanned 466–814 points: it was drawn from 756 to 917.
    ///
    /// So the margins are subtracted before the call and added back by MapKit
    /// during it, which leaves the *effective* padding equal to what the
    /// caller asked for on every edge where the margin is the smaller of the
    /// two. Where it is larger — the trailing edge in landscape, where a
    /// device's own safe area already exceeds the route's 60 points of air —
    /// the margin wins, which is right: something is drawn there.
    ///
    /// ## And why it is still clamped
    ///
    /// `setVisibleMapRect(_:edgePadding:animated:)` is undefined when the
    /// padding exceeds the view, and the padding here is the sum of two
    /// independent things — a sheet's height and a route's breathing room —
    /// neither of which knows how small the other has left the map. On an
    /// iPhone SE in landscape that sum is most of the width. So the padding is
    /// scaled to fit rather than trusted: a cramped viewport is a worse picture
    /// than a generous one, and either is a picture. The size it is scaled to
    /// fit is the map less its margins, for the same reason the subtraction
    /// above happens at all — that is the box MapKit is actually framing into.
    private func setVisible(
        _ rect: MKMapRect,
        on mapView: MKMapView,
        edgePadding: MapEdgeInsets,
        animated: Bool
    ) {
        let margins = Self.layoutMargins(of: mapView)
        let residual = MapEdgeInsets(
            top: max(0, edgePadding.top - margins.top),
            left: max(0, edgePadding.left - margins.left),
            bottom: max(0, edgePadding.bottom - margins.bottom),
            right: max(0, edgePadding.right - margins.right)
        )
        let framed = CGSize(
            width: max(0, mapView.bounds.width - margins.left - margins.right),
            height: max(0, mapView.bounds.height - margins.top - margins.bottom)
        )
        let clamped = Self.clamped(residual, toFit: framed)
        mapView.setVisibleMapRect(rect, edgePadding: clamped.platformInsets, animated: animated)
    }

    /// The map's own layout margins, per *physical* edge.
    ///
    /// The map's are directional — ``MapView/applyBuiltInControlMargins(to:)``
    /// writes the panel into the leading one — and everything a camera move
    /// spends is physical, so this is the same leading-to-left conversion
    /// ``obstructionInsets(in:)`` makes, against the same layout direction.
    ///
    /// Read rather than recomputed from ``sidePanelInset``: the getter returns
    /// the margins MapKit will actually frame into, which is the set value
    /// *plus* the safe area it is inset from — 356 points becomes 418 on a
    /// phone held sideways — and a second copy of that arithmetic here would
    /// be a second thing to keep true.
    private static func layoutMargins(of mapView: MKMapView) -> MapEdgeInsets {
        #if canImport(UIKit)
        let margins = mapView.directionalLayoutMargins
        let rightToLeft = mapView.effectiveUserInterfaceLayoutDirection == .rightToLeft
        return MapEdgeInsets(
            top: margins.top,
            left: rightToLeft ? margins.trailing : margins.leading,
            bottom: margins.bottom,
            right: rightToLeft ? margins.leading : margins.trailing
        )
        #else
        // `NSView` has no layout margins, so there is nothing to take off.
        return MapEdgeInsets()
        #endif
    }

    /// Scales `insets` down, per axis, until each leaves at least
    /// ``minimumViewport`` points of map between them.
    ///
    /// A pure function so it can be asserted directly: the sizes that break
    /// this are small landscape windows, and building one of those in a test is
    /// exactly the thing the arithmetic should not need.
    static func clamped(_ insets: MapEdgeInsets, toFit size: CGSize) -> MapEdgeInsets {
        var result = insets
        let horizontal = insets.left + insets.right
        if horizontal > 0, horizontal > size.width - minimumViewport {
            let scale = max(0, size.width - minimumViewport) / horizontal
            result.left *= scale
            result.right *= scale
        }
        let vertical = insets.top + insets.bottom
        if vertical > 0, vertical > size.height - minimumViewport {
            let scale = max(0, size.height - minimumViewport) / vertical
            result.top *= scale
            result.bottom *= scale
        }
        return result
    }

    /// The least map a camera move will leave itself, on either axis.
    ///
    /// Small on purpose: this is a floor that stops the padding eating the
    /// viewport, not a layout decision.
    static let minimumViewport: CGFloat = 80

    /// What fraction of the map's height the sheet is assumed to take at its
    /// middle detent, before one has been measured.
    ///
    /// The larger of the two occupancies ``SheetMetrics/middleRestY``'s own
    /// documentation names — a detent resting 43% down takes 57% — so the
    /// unmeasured case errs towards a route that is fully visible rather than
    /// one whose last stretch is behind the sheet.
    static let assumedMiddleDetentShare: CGFloat = 0.57
}

/// Edge padding for a camera move, in points, per *physical* edge.
///
/// A type of this app's own rather than `UIEdgeInsets` so the arithmetic above
/// compiles on macOS, where the equivalent is `NSEdgeInsets` and the two agree
/// about nothing but their field names.
struct MapEdgeInsets: Equatable {
    var top: CGFloat = 0
    var left: CGFloat = 0
    var bottom: CGFloat = 0
    var right: CGFloat = 0

    #if os(macOS)
    var platformInsets: NSEdgeInsets {
        NSEdgeInsets(top: top, left: left, bottom: bottom, right: right)
    }
    #else
    var platformInsets: UIEdgeInsets {
        UIEdgeInsets(top: top, left: left, bottom: bottom, right: right)
    }
    #endif
}

extension MKCoordinateRegion {
    /// This region as a map rect.
    ///
    /// Built from the two corners rather than from the centre and a span in
    /// map points, because a degree of longitude is a different number of map
    /// points at every latitude and the span is in degrees.
    ///
    /// A region that crosses the antimeridian is not handled and does not need
    /// to be: the regions reaching this are a local search's `boundingRegion`
    /// and a span around one photograph, and a rect built from a wrapped pair
    /// of corners would be refused by `setVisibleMapRect` rather than drawn
    /// wrong.
    var mapRect: MKMapRect {
        let topLeft = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: center.latitude + span.latitudeDelta / 2,
                longitude: center.longitude - span.longitudeDelta / 2
            )
        )
        let bottomRight = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: center.latitude - span.latitudeDelta / 2,
                longitude: center.longitude + span.longitudeDelta / 2
            )
        )
        return MKMapRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }
}
