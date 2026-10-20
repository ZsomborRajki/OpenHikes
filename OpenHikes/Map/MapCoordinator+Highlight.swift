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
//  The dot's *view* is here for a second caller as well: an open community
//  preview's chart stands the same dot on that hike's line, in its own colour
//  — see `MapCommunityPreviewHighlight.swift`. Two dots, drawn one way, so a
//  scrub reads the same on the map whoever's trail the chart is of.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension MapView.Coordinator {
    /// A small filled dot in `tint` with a white ring: the selected hike's,
    /// in its route tint, and an open preview's, in its listing's colour.
    ///
    /// Each kind under a reuse identifier of its own, so whatever a caller
    /// sets on the view beyond this — the preview's stands in front of the
    /// pins and is named for UI automation — never turns up on a recycled
    /// view of the other.
    func highlightDotView(
        for annotation: any MKAnnotation,
        tint: Color,
        reuseIdentifier: String,
        on mapView: MKMapView
    ) -> MKAnnotationView {
        let view = mapView.reusableView(MKAnnotationView.self, for: annotation, reuseIdentifier: reuseIdentifier)
        view.canShowCallout = false

        let diameter: CGFloat = 18
        view.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        #if os(macOS)
        view.wantsLayer = true
        let layer = view.layer ?? CALayer()
        view.layer = layer
        layer.backgroundColor = NSColor(tint).withAlphaComponent(1).cgColor
        layer.borderColor = NSColor.white.cgColor
        #else
        let layer = view.layer
        layer.backgroundColor = UIColor(tint).withAlphaComponent(1).cgColor
        layer.borderColor = UIColor.white.cgColor
        #endif
        layer.cornerRadius = diameter / 2
        layer.borderWidth = 3
        let annotationShadowOpacity: Float = 0.3
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        layer.shadowOpacity = annotationShadowOpacity
        layer.shadowRadius = 2
        layer.shadowOffset = .zero
        return view
    }

    /// Rebuilds the highlight annotation so `viewFor` recreates its dot in the
    /// new route tint. Cheap — there is at most one such annotation.
    func refreshHighlightColor(on mapView: MKMapView) {
        guard let annotation = highlightAnnotation else { return }
        mapView.removeAnnotation(annotation)
        mapView.addAnnotation(annotation)
    }

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
    ///
    /// Both dots, for the same reason: a preview's stands at the trailhead
    /// until its chart is touched, and a stranger's trailhead can be exactly
    /// where the hiker is standing.
    func updateHighlightOpacity(on mapView: MKMapView) {
        updateOpacity(of: highlightAnnotation, on: mapView)
        updateOpacity(of: communityPreviewHighlight, on: mapView)
    }

    private func updateOpacity(of annotation: (any MKAnnotation)?, on mapView: MKMapView) {
        guard let annotation,
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
