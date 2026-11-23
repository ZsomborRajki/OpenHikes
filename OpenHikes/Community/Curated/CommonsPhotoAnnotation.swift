//
//  CommonsPhotoAnnotation.swift
//  OpenHikes
//
//  A Wikimedia Commons photograph on the map, and the one way a surface puts
//  its photographs there: the *Community* tab's (`MapCommunityCommonsPhotos.swift`)
//  and the trail maker's (`MapTrailDraftPhotos.swift`). Each draws them as an
//  annotation class of its own, because the map tells the two apart by class:
//  a community photograph is grouped and opens its own screen, and the
//  maker's opens the maker's card. What they share is the photograph, where
//  it stands, and how a new answer replaces the pins of the last one.
//

import MapKit

/// One photograph, in the shape MapKit wants it.
///
/// Never drawn as itself: each surface draws a `final` subclass of its own,
/// with its own reuse identifier, accessibility and tap — see this file's
/// header.
class CommonsPhotoAnnotation: NSObject, MKAnnotation {
    let photo: CommonsPhoto
    @objc dynamic let coordinate: CLLocationCoordinate2D
    /// Both keys, because MapKit reads them by key-value coding once a second
    /// annotation is up — see `MapAnnotationKeyCodingTests`. Neither is drawn:
    /// the thumbnail is the pin, and the screen or card it opens says the
    /// rest.
    @objc let title: String? = nil
    @objc let subtitle: String? = nil

    /// `nil` for a photograph with no place to stand on the map.
    required init?(photo: CommonsPhoto) {
        guard let camera = photo.pin.coordinate else { return nil }
        self.photo = photo
        coordinate = camera
        super.init()
    }
}

extension MapView.Coordinator {
    /// Rebuilds one surface's photograph pins wholesale rather than diffing
    /// them.
    ///
    /// Runs when a search lands, a chip is turned, or a surface opens or
    /// closes — a few times a session, never per frame. The guard is what
    /// keeps an unrelated pass from re-dropping every one.
    ///
    /// What is drawn is read back off the map rather than kept beside it: a
    /// pass over a few hundred annotations a few times a session costs less
    /// than another stored property on a coordinator at its length limit. It
    /// comes back in no particular order, so the guard compares the two as
    /// sets: compared as arrays, a pass that changed nothing re-dropped every
    /// thumbnail whenever MapKit's order differed from the search's.
    ///
    /// Only `Pin`'s own are read back and taken down, so a pass over one
    /// surface leaves the other's photographs where they are, the same
    /// photograph included.
    func applyCommonsPhotos<Pin: CommonsPhotoAnnotation>(
        _ photos: [CommonsPhoto],
        as pin: Pin.Type,
        on mapView: MKMapView
    ) {
        let drawn = mapView.annotations.compactMap { $0 as? Pin }
        guard drawn.count != photos.count || Set(drawn.map(\.photo)) != Set(photos) else { return }
        if !drawn.isEmpty {
            mapView.removeAnnotations(drawn)
        }
        guard !photos.isEmpty else { return }
        mapView.addAnnotations(photos.compactMap { pin.init(photo: $0) })
    }
}
