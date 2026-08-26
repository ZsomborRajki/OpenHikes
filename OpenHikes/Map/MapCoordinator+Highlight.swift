//
//  MapCoordinator+Highlight.swift
//  OpenHikes
//
//  The selection dot: one annotation that follows an elevation-chart scrub or
//  an auto-follow match, added, moved and removed straight on `MKMapView`.
//
//  Split out of `MapCoordinator.swift` for the same reason the tracking button
//  was: the coordinator's own file is the observation plumbing, and each thing
//  that plumbing drives reads better beside its own justification than folded
//  into the middle of it.
//
//  Internal rather than private, which is what a file split costs in Swift —
//  `private` is file-scoped, and `observeHighlight(_:on:)` and two delegate
//  callbacks still live next door.
//

import MapKit
#if canImport(UIKit)
import UIKit
#endif

extension MapView.Coordinator {
    /// Adds/moves/removes the single highlight annotation. O(1).
    func applyHighlight(_ coordinate: CLLocationCoordinate2D?, on mapView: MKMapView) {
        guard let coordinate else {
            if let annotation = highlightAnnotation {
                mapView.removeAnnotation(annotation)
                highlightAnnotation = nil
            }
            return
        }
        if let annotation = highlightAnnotation {
            if annotation.coordinate.latitude != coordinate.latitude
                || annotation.coordinate.longitude != coordinate.longitude {
                annotation.coordinate = coordinate
            }
        } else {
            let annotation = MKPointAnnotation()
            annotation.coordinate = coordinate
            highlightAnnotation = annotation
            mapView.addAnnotation(annotation)
        }
        updateHighlightOpacity(on: mapView)
    }

    /// Fades the selection dot when it visually coincides with the "my location"
    /// puck, so the two don't blend into an ambiguous blob and the user's real
    /// position stays the one that reads clearly. zPriority doesn't help here —
    /// MKUserLocationView isn't ordered against custom annotations the normal way.
    func updateHighlightOpacity(on mapView: MKMapView) {
        guard let annotation = highlightAnnotation,
              let view = mapView.view(for: annotation) else { return }
        guard let userCoordinate = mapView.userLocation.location?.coordinate else {
            setAlpha(1, on: view)
            return
        }
        let selectionPoint = mapView.convert(annotation.coordinate, toPointTo: mapView)
        let userPoint = mapView.convert(userCoordinate, toPointTo: mapView)
        let distance = hypot(selectionPoint.x - userPoint.x, selectionPoint.y - userPoint.y)
        setAlpha(distance < Self.overlapThresholdPoints ? Self.overlapFadedAlpha : 1, on: view)
    }

    func setAlpha(_ alpha: CGFloat, on view: MKAnnotationView) {
        #if os(macOS)
        view.alphaValue = alpha
        #else
        view.alpha = alpha
        #endif
    }
}
