//
//  MapTrailDraftPhotos.swift
//  OpenHikes
//
//  The Wikimedia Commons photographs *Search this area* found, on the maker's
//  map — see ``TrailDraftPhotos``.
//
//  **The picture is the pin.** A camera glyph in a marker says *there is a
//  photograph here* and makes the hiker open each one to find out whether it
//  is the lake or the car park; a thumbnail answers that from the map, which
//  is the whole of what a planning map is for. So each is a small rounded
//  photograph with a white edge, the way Photos draws its places map.
//
//  **And it gives way.** A search can find sixteen in a valley, and a drawing
//  has stops and places that are the hiker's own: the photographs are below
//  both and collide with each other, so MapKit hides what overlaps and a zoom
//  brings it back. A hidden photograph is still one tap of zoom away, where a
//  hidden stop would be a stop nobody can drag.
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
            TrailDraftPhotoAnnotationView.self,
            for: annotation,
            reuseIdentifier: TrailDraftPhotoAnnotation.reuseIdentifier
        )
        view.show(annotation.photo)
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

#if os(iOS)
/// A thumbnail standing on the spot it was taken.
final class TrailDraftPhotoAnnotationView: MKAnnotationView {
    /// The thumbnail's side, in points: a fingertip, and a picture big
    /// enough to tell a lake from a road.
    static let side: CGFloat = 44
    private static let cornerRadius: CGFloat = 8
    private static let edge: CGFloat = 2
    /// Below the hiker's own stops and places, which are `.defaultHigh` and
    /// above, and above MapKit's own labels.
    private static let priority = MKFeatureDisplayPriority(rawValue: 500)
    private static let shadowOpacity: Float = 0.3
    private static let shadowRadius: CGFloat = 3
    private static let shadowDrop: CGFloat = 1
    /// Decoded at the screen's scale and no more.
    private static let pixelsPerPoint: CGFloat = 3

    private let imageView = UIImageView()
    /// Which photograph is on screen, so a decode that lands after the view
    /// has been recycled onto another pin is dropped rather than drawn.
    private var shown: CommonsPhoto?
    private var loadTask: Task<Void, Never>?

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        // Standing on the spot rather than centred on it, like a pin.
        centerOffset = CGPoint(x: 0, y: -Self.side / 2)
        canShowCallout = false
        // Below the hiker's own stops and places, and hidden by its
        // neighbours — see the file header.
        displayPriority = Self.priority
        collisionMode = .rectangle
        backgroundColor = .white
        layer.cornerRadius = Self.cornerRadius
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = Self.shadowOpacity
        layer.shadowRadius = Self.shadowRadius
        layer.shadowOffset = CGSize(width: 0, height: Self.shadowDrop)
        imageView.frame = bounds.insetBy(dx: Self.edge, dy: Self.edge)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = Self.cornerRadius - Self.edge
        imageView.backgroundColor = .secondarySystemFill
        addSubview(imageView)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "trail-draft-photo-pin"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        shown = nil
        imageView.image = nil
    }

    /// Points the view at a photograph. Cheap to call again with the same one.
    func show(_ photo: CommonsPhoto) {
        accessibilityLabel = PhotoLicenceCredit.line(author: photo.credit.author, licence: photo.credit.licence)
        guard shown != photo else { return }
        shown = photo
        imageView.image = nil
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            // The decode the community strip owns, at this box's size.
            let decoded = await CommunityPhotoTile.decodeUIImage(
                photo.fileURL,
                maxPixelSize: Int(Self.side * Self.pixelsPerPoint)
            )
            guard let self, shown == photo else { return }
            imageView.image = decoded
        }
    }
}
#endif
