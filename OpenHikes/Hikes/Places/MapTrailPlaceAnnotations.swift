//
//  MapTrailPlaceAnnotations.swift
//  OpenHikes
//
//  A trail's places on the map.
//
//  Two sources, one pin. While the maker is up they come from
//  ``TrailDraft/places``, and a tap opens the maker's place sheet — see
//  `MapTrailDraftSelection.swift`. On a hike that has been saved they come
//  from its ``TrailPoint`` rows through ``TrailPlacePinController`` and a tap
//  opens the place's own screen — see ``HikePlaceView``. One annotation class
//  carrying ``TrailPlaceAnnotation/belongsToDraft`` rather than two nearly
//  identical ones: the pin, the glyph and the colour are the same thing said
//  about the same place.
//
//  ## A place is a marker, a waypoint is a dot
//
//  Drawn apart on purpose, because they are different kinds of thing and are
//  on screen together. A waypoint is a numbered dot on the line — see
//  `MapTrailDraftOverlay.swift`, where the argument for the plain circle is
//  that what a hiker reads is where the *centre* of each point sits. A place
//  is not on the line at all, so it is a balloon whose tip points at the
//  ground it is about, in its kind's own colour — blue water, a brown summit —
//  so a map of forty of them reads at a glance.
//
//  Built out of `MKMarkerAnnotationView` for the reason
//  ``MapPhotoAnnotations`` gives: the balloon, the drop, the shadow and the
//  decluttering are already drawn, and what is app-specific is the glyph.
//

import MapKit
import OpenHikesShared
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One ``TrailPlace``, in the shape MapKit wants it.
final class TrailPlaceAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "trailPlace"

    @objc dynamic let coordinate: CLLocationCoordinate2D
    let place: TrailPlace
    /// How far along the trail it sits, or `nil` where that cannot be said —
    /// no line yet, or too far off it to describe. See ``TrailPlaceAnchor``.
    let anchor: TrailPlaceAnchor?
    /// Whether this is the drawing's place, which opens the place sheet, rather
    /// than a saved hike's, which opens the place's screen.
    let belongsToDraft: Bool
    /// Whether this is where a place about to be added would stand, rather
    /// than a place the hike has. Opens nothing. See ``HikePlaceAdder``.
    let isPlaceholder: Bool

    @objc var title: String? { place.displayName }

    /// What it is and where, on one line — and the whole of what identifies an
    /// unnamed place, which is the normal case.
    ///
    /// The kind is left out when it is already the title, so an unnamed spring
    /// does not read "Water · Water".
    @objc var subtitle: String? {
        let kind = place.name.isEmpty ? nil : place.symbol?.label
        let distance = anchor.map { measured in
            Measurement(value: measured.distanceAlongRouteMeters, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
        }
        let parts = [kind, distance].compactMap(\.self)
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    init(row: TrailPlaceRow, belongsToDraft: Bool, isPlaceholder: Bool = false) {
        place = row.place
        coordinate = row.place.clCoordinate
        anchor = row.anchor
        self.belongsToDraft = belongsToDraft
        self.isPlaceholder = isPlaceholder
    }

    func matches(_ row: TrailPlaceRow, belongsToDraft: Bool) -> Bool {
        place == row.place && anchor == row.anchor && self.belongsToDraft == belongsToDraft
    }
}

extension TrailPlaceSymbol {
    /// The pin's colour — the kind at a glance, as Apple Maps colours its own.
    var tint: Color {
        switch self {
        case .camp: .green
        case .caution: .red
        case .junction: .gray
        case .parking: .blue
        case .shelter: .orange
        case .summit: .brown
        case .viewpoint: .teal
        case .water: .cyan
        }
    }
}

extension TrailPlace {
    /// A place that claims no kind is the app's own indigo.
    var tint: Color { symbol?.tint ?? .indigo }
}

extension MapView.Coordinator {
    func trailPlaceAnnotationView(
        for annotation: TrailPlaceAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView {
        let identifier = TrailPlaceAnnotation.reuseIdentifier
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        view.annotation = annotation
        #if os(iOS)
        view.glyphImage = UIImage(systemName: annotation.place.systemImageName)
        view.displayPriority = .required
        view.markerTintColor = UIColor(annotation.place.tint)
        view.accessibilityIdentifier = switch (annotation.belongsToDraft, annotation.isPlaceholder) {
        case (true, _): "trail-draft-place"
        case (false, true): "hike-place-placeholder"
        case (false, false): "hike-place"
        }
        #endif
        // The pin a hiker is placing stands in front of the ones already there.
        view.zPriority = annotation.isPlaceholder ? .max : .defaultUnselected
        // Neither kind shows a callout: the drawing's opens the place sheet
        // and a saved hike's opens the place's screen — see
        // ``selectHikePlaceAnnotation(_:on:)``.
        view.canShowCallout = false
        return view
    }

    /// A tap on one of a saved hike's place pins, which opens that place's
    /// screen. Answers whether it was one.
    func selectHikePlaceAnnotation(_ view: MKAnnotationView, on mapView: MKMapView) -> Bool {
        guard let place = view.annotation as? TrailPlaceAnnotation, !place.belongsToDraft else { return false }
        // Deselected at once, as the maker's pins are: an annotation left
        // selected swallows the next tap on it.
        mapView.deselectAnnotation(place, animated: false)
        if hikePlaceController?.open(place.place.id) == true {
            HapticMoment.targetHit.play()
        }
        return true
    }
}
