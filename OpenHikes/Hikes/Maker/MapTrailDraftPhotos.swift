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
import OpenHikesData
#if canImport(UIKit)
import UIKit
#endif

/// One photograph, in the shape MapKit wants it.
final class TrailDraftPhotoAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "trailDraftPhoto"

    let photo: CommonsPhoto
    @objc dynamic let coordinate: CLLocationCoordinate2D
    /// Both keys, because MapKit reads them by key-value coding once a second
    /// annotation is up — see `MapAnnotationKeyCodingTests`. Neither is drawn:
    /// the thumbnail is the pin and the card says the rest.
    @objc let title: String? = nil
    @objc let subtitle: String? = nil

    init?(photo: CommonsPhoto) {
        guard let camera = photo.pin.coordinate else { return nil }
        self.photo = photo
        coordinate = camera
        super.init()
    }
}

extension MapView.Coordinator {
    /// Rebuilds the photographs' pins wholesale rather than diffing them.
    ///
    /// Runs when a search lands, the chip is turned, or the maker opens or
    /// closes — a few times a session, never per frame. The guard is what
    /// keeps an unrelated pass over the draft from re-dropping every one.
    ///
    /// What is drawn is read back off the map rather than kept beside it: a
    /// pass over a few hundred annotations a few times a session costs less
    /// than another stored property on a coordinator at its length limit. It
    /// comes back in no particular order, so the guard compares the two as
    /// sets: compared as arrays, a pass that changed nothing re-dropped every
    /// thumbnail whenever MapKit's order differed from the search's.
    func applyTrailDraftPhotos(_ photos: [CommonsPhoto], on mapView: MKMapView) {
        let drawn = mapView.annotations.compactMap { $0 as? TrailDraftPhotoAnnotation }
        guard drawn.count != photos.count || Set(drawn.map(\.photo)) != Set(photos) else { return }
        if !drawn.isEmpty {
            mapView.removeAnnotations(drawn)
        }
        guard !photos.isEmpty else { return }
        mapView.addAnnotations(photos.compactMap(TrailDraftPhotoAnnotation.init))
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
