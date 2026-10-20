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
//  **Photographs too close together to draw apart are drawn as one**, the
//  newest of them with a count in its corner, and a tap on that opens the
//  group as a grid in the sheet — see ``CommonsPhotoGroupView``, and the
//  user's call of 2026-10-20 there. A search spreads its pictures over a grid
//  of cells, but a summit, a hut or a cable car's top station is photographed
//  from every side, and four thumbnails stacked on one spot hid three of them
//  behind the fourth. MapKit does the grouping (`clusteringIdentifier`), so a
//  group comes apart as the map zooms in, as the thumbnails stop overlapping.
//  The maker's photographs are not grouped: there a photograph is one spot to
//  put a stop on.
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
    /// What MapKit groups overlapping thumbnails by — see this file's header.
    static let clusteringIdentifier = "communityCommonsPhotos"
    /// The view a group is drawn with: the same thumbnail, with a count.
    static let groupReuseIdentifier = "communityCommonsPhotoGroup"

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

    /// The photographs a group MapKit made of these stands for, newest first
    /// — the order its grid shows them in, and the first is the one drawn.
    ///
    /// Newest first because the hiker is deciding whether a place is worth
    /// walking to now, and a hut photographed fifteen years ago may be gone.
    /// The Commons page settles a tie, so the same group always draws the
    /// same picture.
    static func photos(in group: MKClusterAnnotation) -> [CommonsPhoto] {
        group.memberAnnotations
            .compactMap { ($0 as? Self)?.photo }
            .sorted { lhs, rhs in
                guard lhs.pin.capturedAt == rhs.pin.capturedAt else { return lhs.pin.capturedAt > rhs.pin.capturedAt }
                return lhs.credit.license.sourceURL.absoluteString < rhs.credit.license.sourceURL.absoluteString
            }
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

    /// The view for one of the maker's annotations, a community photograph or
    /// a group of them, or `nil` for any other — one question, so the
    /// delegate in `MapCoordinator.swift` asks it once.
    func ownedAnnotationView(for annotation: any MKAnnotation, on mapView: MKMapView) -> MKAnnotationView? {
        if let maker = makerAnnotationView(for: annotation, on: mapView) { return maker }
        if let group = annotation as? MKClusterAnnotation {
            return communityCommonsPhotoGroupView(for: group, on: mapView)
        }
        guard let photo = annotation as? CommunityCommonsPhotoAnnotation else { return nil }
        #if os(iOS)
        let view = mapView.reusableView(
            CommonsPhotoPinView.self,
            for: photo,
            reuseIdentifier: CommunityCommonsPhotoAnnotation.reuseIdentifier
        )
        view.show(photo.photo)
        // Grouped with the thumbnails it would overlap — see the file header.
        view.clusteringIdentifier = CommunityCommonsPhotoAnnotation.clusteringIdentifier
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

    /// A group of the tab's photographs, drawn as the newest of them with how
    /// many it stands for — or `nil` for a group of anything else, which
    /// nothing on this map makes: these are the only views given a
    /// `clusteringIdentifier`.
    private func communityCommonsPhotoGroupView(
        for group: MKClusterAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView? {
        let photos = CommunityCommonsPhotoAnnotation.photos(in: group)
        guard let newest = photos.first else { return nil }
        #if os(iOS)
        let view = mapView.reusableView(
            CommonsPhotoPinView.self,
            for: group,
            reuseIdentifier: CommunityCommonsPhotoAnnotation.groupReuseIdentifier
        )
        view.show(newest, standingFor: photos.count)
        view.accessibilityIdentifier = "community-commons-photo-group"
        view.accessibilityHint = String(localized: "Opens the photos")
        return view
        #else
        return mapView.reusableView(
            MKAnnotationView.self,
            for: group,
            reuseIdentifier: CommunityCommonsPhotoAnnotation.groupReuseIdentifier
        )
        #endif
    }

    /// The pins a tap may open a screen from: the maker's own, a saved hike's
    /// places, and a community photograph or a group of them. Answers whether
    /// it was one of them.
    ///
    /// One question for all of them, so the selection handler in
    /// `MapCoordinator.swift` asks it once.
    func selectOwnedAnnotation(_ view: MKAnnotationView, on mapView: MKMapView) -> Bool {
        selectTrailDraftAnnotation(view, on: mapView)
            || selectHikePlaceAnnotation(view, on: mapView)
            || selectCommunityCommonsPhoto(view, on: mapView)
            || selectCommunityCommonsPhotoGroup(view, on: mapView)
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

    /// Opens a group's grid. Answers whether the tap was on one.
    private func selectCommunityCommonsPhotoGroup(_ view: MKAnnotationView, on mapView: MKMapView) -> Bool {
        guard let group = view.annotation as? MKClusterAnnotation else { return false }
        let photos = CommunityCommonsPhotoAnnotation.photos(in: group)
        guard !photos.isEmpty else { return false }
        // Let go of, for the reason a single photograph is.
        mapView.deselectAnnotation(group, animated: false)
        HapticMoment.targetHit.play()
        community?.open(photos)
        return true
    }
}
