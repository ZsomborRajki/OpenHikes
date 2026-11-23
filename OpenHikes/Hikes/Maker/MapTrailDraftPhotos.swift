//
//  MapTrailDraftPhotos.swift
//  OpenHikes
//
//  The Wikimedia Commons photographs *Search this area* found, on the maker's
//  map — see ``TrailDraftPhotos``.
//
//  Each is a thumbnail that gives way to the drawing's own stops and places —
//  see ``CommonsPhotoPinView``. A hidden photograph is still one tap of zoom
//  away, where a hidden stop would be a stop nobody can drag.
//
//  A tap opens the maker's place card on it — see
//  ``TrailDraftSelection/photo(_:)`` — never a callout, for the reason the
//  maker has none (`MapTrailDraftSelection.swift`).
//

import MapKit
#if canImport(UIKit)
import UIKit
#endif

/// One of the maker's photographs on the map: its own class, so the maker
/// reads back only its own — see ``CommonsPhotoAnnotation``.
final class TrailDraftPhotoAnnotation: CommonsPhotoAnnotation {
    static let reuseIdentifier = "trailDraftPhoto"
}

extension MapView.Coordinator {
    /// Puts the maker's photographs on the map, leaving the *Community*
    /// tab's alone — see ``applyCommonsPhotos(_:as:on:)``. An unrelated pass
    /// over the draft re-drops none of them.
    func applyTrailDraftPhotos(_ photos: [CommonsPhoto], on mapView: MKMapView) {
        applyCommonsPhotos(photos, as: TrailDraftPhotoAnnotation.self, on: mapView)
    }

    func trailDraftPhotoView(for annotation: TrailDraftPhotoAnnotation, on mapView: MKMapView) -> MKAnnotationView {
        #if os(iOS)
        let view = mapView.reusableView(
            CommonsPhotoPinView.self,
            for: annotation,
            reuseIdentifier: TrailDraftPhotoAnnotation.reuseIdentifier
        )
        view.show(annotation.photo)
        view.accessibilityIdentifier = "trail-draft-photo-pin"
        return view
        #else
        return mapView.reusableView(
            MKAnnotationView.self,
            for: annotation,
            reuseIdentifier: TrailDraftPhotoAnnotation.reuseIdentifier
        )
        #endif
    }
}
