//
//  MapCommunityCommonsPhotos.swift
//  OpenHikes
//
//  The Wikimedia Commons photographs the *Community* tab found, on the map —
//  see ``CommunityCommonsPhotos``.
//
//  Thumbnails, like the maker's, and for its reason: the picture answers from
//  the map whether it is worth opening. They give way to the community's hike
//  markers, which are what the list beside them is about. See
//  ``CommonsPhotoPinView``.
//
//  A tap opens the photograph's own screen in the sheet — see
//  ``CommonsPhotoView`` — rather than a callout. The screen is where the
//  credit, the place and *Plan a Trail Here* are, and a callout with all of
//  that in it would be the screen squeezed into a bubble.
//
//  Drawn from the same observation as the hike markers rather than one of its
//  own: the two change together, when an answer lands or the tab goes, and
//  the coordinator's file has no room left for another registration flag.
//

import MapKit
import OpenHikesData
import OpenHikesShared

/// One photograph, in the shape MapKit wants it.
///
/// Its own class rather than ``TrailDraftPhotoAnnotation``, because the map
/// tells the two apart by class: the maker reads its own back off the map and
/// opens its card on a tap, and a community photograph must be neither.
final class CommunityCommonsPhotoAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "communityCommonsPhoto"

    let photo: CommonsPhoto
    @objc dynamic let coordinate: CLLocationCoordinate2D
    /// Both keys, because MapKit reads them by key-value coding once a second
    /// annotation is up — see `MapAnnotationKeyCodingTests`. Neither is drawn.
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
    /// Read back off the map rather than stored, and compared as sets, for the
    /// reasons ``applyTrailDraftPhotos(_:on:)`` gives.
    func applyCommunityCommonsPhotos(_ photos: [CommonsPhoto], on mapView: MKMapView) {
        let drawn = mapView.annotations.compactMap { $0 as? CommunityCommonsPhotoAnnotation }
        guard drawn.count != photos.count || Set(drawn.map(\.photo)) != Set(photos) else { return }
        if !drawn.isEmpty {
            mapView.removeAnnotations(drawn)
        }
        guard !photos.isEmpty else { return }
        mapView.addAnnotations(photos.compactMap(CommunityCommonsPhotoAnnotation.init))
    }

    /// The view for one of the maker's annotations or a community
    /// photograph, or `nil` for any other — one question, so the delegate in
    /// `MapCoordinator.swift` asks it once.
    func ownedAnnotationView(for annotation: any MKAnnotation, on mapView: MKMapView) -> MKAnnotationView? {
        if let maker = makerAnnotationView(for: annotation, on: mapView) { return maker }
        guard let photo = annotation as? CommunityCommonsPhotoAnnotation else { return nil }
        #if os(iOS)
        let view = mapView.reusableView(
            CommonsPhotoPinView.self,
            for: photo,
            reuseIdentifier: CommunityCommonsPhotoAnnotation.reuseIdentifier
        )
        view.show(photo.photo)
        view.accessibilityIdentifier = "community-commons-photo-pin"
        view.accessibilityHint = String(localized: "Opens the photo")
        return view
        #else
        return mapView.reusableView(
            MKAnnotationView.self,
            for: photo,
            reuseIdentifier: CommunityCommonsPhotoAnnotation.reuseIdentifier
        )
        #endif
    }

    /// The pins a tap may open a screen from: the maker's own, a saved hike's
    /// places, and a community photograph. Answers whether it was one of them.
    ///
    /// One question for all three, so the selection handler in
    /// `MapCoordinator.swift` asks it once.
    func selectOwnedAnnotation(_ view: MKAnnotationView, on mapView: MKMapView) -> Bool {
        selectTrailDraftAnnotation(view, on: mapView)
            || selectHikePlaceAnnotation(view, on: mapView)
            || selectCommunityCommonsPhoto(view, on: mapView)
    }

    /// Opens a community photograph's screen. Answers whether the tap was on
    /// one.
    private func selectCommunityCommonsPhoto(_ view: MKAnnotationView, on mapView: MKMapView) -> Bool {
        guard let annotation = view.annotation as? CommunityCommonsPhotoAnnotation else { return false }
        // Let go of, so a second tap on the same picture is heard after Back.
        mapView.deselectAnnotation(annotation, animated: false)
        HapticMoment.targetHit.play()
        community?.open(annotation.photo)
        return true
    }
}
