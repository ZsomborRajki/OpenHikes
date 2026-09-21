//
//  MapTrailDraftOverlay.swift
//  OpenHikes
//
//  The line being drawn, on the map it is being drawn on.
//
//  Its own overlay rather than the selected hike's, because the two say
//  different things and are on screen at the same time: a hiker can be drawing
//  a new route across a valley they already have a trail through. The drawn
//  line is the app's accent and the hiker's own routes are whatever colour
//  they chose, so neither is ever mistaken for the other.
//
//  Numbered pins rather than plain dots, and that is the affordance rather
//  than decoration: the order points were put down in is the direction the
//  trail runs, and it is the only thing about a drawn line that a picture of
//  the line cannot show. It is also what the list in the sheet is a list *of*,
//  so the two are readable against each other.
//
//  Applied imperatively off ``TrailDraft``, like every other overlay here, so
//  a tap that adds a point moves MapKit and no SwiftUI view.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One waypoint, in the shape MapKit wants it, carrying the number it draws.
final class TrailDraftWaypointAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "trailDraftWaypoint"

    @objc dynamic let coordinate: CLLocationCoordinate2D
    /// One-based, because it is read by a person rather than indexed by code.
    let number: Int

    init(coordinate: CLLocationCoordinate2D, number: Int) {
        self.coordinate = coordinate
        self.number = number
    }

    /// Spoken by VoiceOver, which reaches a waypoint through its pin the way
    /// it reaches a shared hike through its marker — a polyline is not an
    /// accessibility element and cannot be made one.
    var title: String? {
        String(localized: "Point \(number)")
    }
}

extension MapView.Coordinator {
    private static let trailDraftLineWidth: CGFloat = 4
    private static let trailDraftPinDiameter: CGFloat = 24
    private static let trailDraftPinBorderWidth: CGFloat = 2.5
    private static let trailDraftPinShadowOpacity: Float = 0.35

    /// Observes the draft and redraws it, then re-registers.
    ///
    /// Both the line and whether there is a canvas at all are tracked in one
    /// registration, because they are one question: the draft is drawn while
    /// the maker is up and not otherwise, so a change to either has the same
    /// answer to compute. Idempotent, like every registration here.
    func observeTrailDraft(_ controller: TrailDraftController, on mapView: MKMapView) {
        guard !isObservingTrailDraft else { return }
        isObservingTrailDraft = true
        trackTrailDraft(controller, on: mapView)
    }

    private func trackTrailDraft(_ controller: TrailDraftController, on mapView: MKMapView) {
        applyTrailDraft(controller, on: mapView)
        reobserving(self, mapView, controller) {
            _ = controller.isEditing
            _ = controller.draft.waypoints
        } onChange: { coordinator, map, model in
            coordinator.trackTrailDraft(model, on: map)
        }
    }

    /// Rebuilds the line and the pins wholesale rather than diffing them.
    ///
    /// At most a few dozen of each, and this runs when a hiker taps — never at
    /// drag or fix frequency. The guard in front of it is what keeps a
    /// republish of the same draft from removing and re-adding everything.
    private func applyTrailDraft(_ controller: TrailDraftController, on mapView: MKMapView) {
        let coordinates = controller.isEditing ? controller.draft.coordinates : []
        guard !Self.isSameDraft(coordinates, as: trailDraftCoordinates) else { return }
        trailDraftCoordinates = coordinates

        if let existing = trailDraftOverlay {
            mapView.removeOverlay(existing)
            trailDraftOverlay = nil
        }
        if !trailDraftAnnotations.isEmpty {
            mapView.removeAnnotations(trailDraftAnnotations)
            trailDraftAnnotations = []
        }
        guard !coordinates.isEmpty else { return }

        // Above the shared hikes' lines and the hiker's own, because this is
        // the one the hiker is working on. All of it is still `.aboveLabels`:
        // the raster tile overlay is opaque, so anything below that level is
        // buried rather than faint — see ``MapCommunityRoutes``.
        if coordinates.count > 1 {
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            trailDraftOverlay = line
            mapView.addOverlay(line, level: .aboveLabels)
        }
        let pins = coordinates.enumerated().map { index, coordinate in
            TrailDraftWaypointAnnotation(coordinate: coordinate, number: index + 1)
        }
        trailDraftAnnotations = pins
        mapView.addAnnotations(pins)
    }

    /// Whether two drafts would draw identically.
    ///
    /// Compared by value rather than by count, because a later phase moves a
    /// point without adding one — and a count comparison would silently stop
    /// redrawing the moment it did.
    private static func isSameDraft(
        _ lhs: [CLLocationCoordinate2D],
        as rhs: [CLLocationCoordinate2D]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.latitude == right.latitude && left.longitude == right.longitude
        }
    }

    /// The line's renderer, or `nil` when this polyline is not the draft's.
    ///
    /// Asked by `rendererFor` before every style that describes the hiker's
    /// own route, for the reason the community one is: a draft is not a hike
    /// and must not be drawn in the colour and width somebody chose for one.
    func trailDraftRenderer(for polyline: MKPolyline) -> MKPolylineRenderer? {
        guard trailDraftOverlay === polyline else { return nil }
        let renderer = MKPolylineRenderer(polyline: polyline)
        #if os(macOS)
        renderer.strokeColor = NSColor(Color.accentColor)
        #else
        renderer.strokeColor = UIColor(Color.accentColor)
        #endif
        renderer.lineWidth = Self.trailDraftLineWidth
        renderer.lineJoin = .round
        renderer.lineCap = .round
        return renderer
    }

    /// A numbered dot for one waypoint, or `nil` when this annotation is not
    /// one.
    ///
    /// A plain ``MKAnnotationView`` rather than a marker balloon: a balloon's
    /// point is its tip, and what a hiker is reading here is where the *centre*
    /// of each point sits on the line they drew.
    func trailDraftAnnotationView(
        for annotation: TrailDraftWaypointAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView {
        let identifier = TrailDraftWaypointAnnotation.reuseIdentifier
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        view.annotation = annotation
        view.canShowCallout = false
        let diameter = Self.trailDraftPinDiameter
        view.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)

        #if canImport(UIKit)
        let label = trailDraftNumberLabel(in: view, diameter: diameter)
        label.text = "\(annotation.number)"

        let layer = view.layer
        layer.backgroundColor = UIColor(Color.accentColor).cgColor
        layer.borderColor = UIColor.white.cgColor
        layer.cornerRadius = diameter / 2
        layer.borderWidth = Self.trailDraftPinBorderWidth
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        layer.shadowOpacity = Self.trailDraftPinShadowOpacity
        layer.shadowRadius = 2
        layer.shadowOffset = .zero
        #endif
        return view
    }

    #if canImport(UIKit)
    /// The label inside a recycled pin, made once and found again afterwards.
    ///
    /// Tagged rather than subclassed: `dequeueReusableAnnotationView` hands
    /// back a view this method already furnished, and adding a second label to
    /// it on every reuse is how a recycled pin ends up drawing two numbers on
    /// top of each other.
    private func trailDraftNumberLabel(in view: MKAnnotationView, diameter: CGFloat) -> UILabel {
        let tag = 1
        if let existing = view.viewWithTag(tag) as? UILabel { return existing }
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        label.tag = tag
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        // Decoration: the number is already in the annotation's title, which
        // is what VoiceOver reads, and a label inside a pin would otherwise
        // announce the digit a second time.
        label.isAccessibilityElement = false
        view.addSubview(label)
        return label
    }
    #endif
}
