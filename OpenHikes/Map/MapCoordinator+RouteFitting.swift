//
//  MapCoordinator+RouteFitting.swift
//  OpenHikes
//
//  Putting a route on screen: the edge padding, and the one piece of
//  arithmetic that is easy to get subtly wrong in a second copy.
//
//  Split out of `MapCoordinator.swift` for the reason the walk highlight and
//  the tracking button were — the coordinator's own file is the observation
//  plumbing — and because there are two callers now rather than one. The
//  hiker's own route is fitted here by the initial draw and the detail view's
//  Zoom button; a shared hike's route is fitted by the preview that opened it,
//  through the same padding. See `MapCommunityRoutes.swift`.
//
//  What both of them need and neither should restate is the landscape panel:
//  MapKit's padding is in *physical* edges and ``MapSidePanel`` occupies a
//  *leading* one, so the conversion between them — including the safe area the
//  panel is positioned inside — belongs in exactly one place.
//

import MapKit

extension MapView.Coordinator {
    /// Fits the currently drawn route into view. Shared by the initial draw and
    /// the detail view's Zoom button.
    func fitToCurrentRoute(_ mapView: MKMapView, animated: Bool) {
        guard let polyline = routeOverlay else { return }
        fit(polyline.boundingMapRect, on: mapView, animated: animated)
    }

    /// Puts `rect` on screen inside the route padding, with the landscape
    /// panel's occupied width added on the physical edge it occupies.
    ///
    /// Its own method because a shared hike's line is fitted the same way
    /// the hiker's own route is — see `MapCommunityRoutes.swift` — and the
    /// panel arithmetic is the half of this that is easy to get subtly
    /// wrong in a second copy.
    func fit(_ rect: MKMapRect, on mapView: MKMapView, animated: Bool) {
        var insets = Self.routeInsets
        #if canImport(UIKit)
        if sidePanelInset > 0 {
            // MapKit padding uses physical edges; the panel uses leading.
            // Include the safe area the panel itself is positioned inside.
            if mapView.effectiveUserInterfaceLayoutDirection == .rightToLeft {
                insets.right += sidePanelInset + mapView.safeAreaInsets.right
            } else {
                insets.left += sidePanelInset + mapView.safeAreaInsets.left
            }
        }
        #endif
        mapView.setVisibleMapRect(rect, edgePadding: insets, animated: animated)
    }
}
