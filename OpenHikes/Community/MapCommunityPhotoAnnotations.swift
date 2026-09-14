//
//  MapCommunityPhotoAnnotations.swift
//  OpenHikes
//
//  Where the photographs of the hike being previewed were taken.
//
//  This is the half of a shared hike's photographs that was missing, and the
//  gap was exactly the one ``MapCommunityAnnotations`` closed for the list: a
//  strip of pictures said *this walk has eight photographs* and nothing at all
//  about which bend in the trail any of them is of. The pins are in the
//  payload already — ``CommunityPhotoPin`` carries a coordinate per picture,
//  uploaded beside the images and downloaded with them — and until now nothing
//  drew them, so the one thing the pins exist for was the one thing they were
//  not used for.
//
//  It matters twice over on the review screen. A reviewer deciding whether a
//  photograph belongs in a public list is deciding about a picture *of a
//  place*, and a picture with no place is a harder thing to judge; and once
//  they can take a single photograph off a submission, knowing which one
//  stands where is the difference between removing the right one and removing
//  the third one.
//
//  ## Only ever the open preview's
//
//  A page of nearby results gets lines and markers; it does not get these.
//  A photograph's coordinate lives in the submission's pins asset, which is
//  downloaded by the screen that opened the hike and by nothing else — see
//  ``CommunityListing``, which carries a count rather than the pictures for
//  the same reason. So this layer is empty except while a preview is up, and
//  ``CommunityBrowser/previewClosed(_:)`` is what empties it.
//
//  ## Why these do not declutter, where the hike markers do
//
//  A community *hike* marker is one of a list the hiker can still scroll, so
//  one hiding behind another costs nothing. A photo pin is not in any list:
//  the strip on the sheet says how many there are and this map is the only
//  place that says where. Two pictures taken a few metres apart are also the
//  ordinary case rather than the awkward one — a viewpoint gets photographed
//  twice — so a hidden pin here is a picture the screen has no other way to
//  place. The same argument ``MapPhotoAnnotations`` makes for the hiker's own.
//
//  ## Why not ``PhotoMapAnnotation``
//
//  Because that one is built on ``PhotoMapPin``, which holds a ``HikePhoto``:
//  a SwiftData model, in the hiker's own store, whose pixels
//  ``HikePhotoStore`` owns. These pictures are somebody else's, they are in a
//  directory the previewing screen deletes, and they must not be written into
//  that store — see ``CommunityPhotoTile``, which makes the same argument
//  about the same files one layer up. What the two share is MapKit, and that
//  is the part worth sharing: an `MKMarkerAnnotationView` with a picture in
//  its `detailCalloutAccessoryView`, which is the shape both of them are.
//

import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One photograph of the previewed hike, in the shape MapKit wants it.
final class CommunityPhotoMapAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "communityPhotoPin"

    let photo: CommunityPreviewPhoto
    @objc dynamic let coordinate: CLLocationCoordinate2D
    /// A callout needs a title to open at all. "Photo" is the whole of what
    /// the map has to say — the picture below it is the content, the same
    /// division ``PhotoMapAnnotation`` makes.
    @objc let title: String?
    /// When it was taken, which is the one fact about somebody else's
    /// photograph this app actually knows. It is also what the share sheet
    /// promised went with the picture, so saying it here is the app showing
    /// what it said it would carry.
    @objc let subtitle: String?

    init(photo: CommunityPreviewPhoto) {
        self.photo = photo
        coordinate = photo.coordinate
        title = String(localized: "Photo")
        subtitle = HikeFormat.timestamp(photo.capturedAt)
        super.init()
    }
}

#if os(iOS)
/// The picture inside a community photo pin's callout.
///
/// A plain view rather than a control, which is the one real difference from
/// ``PhotoCalloutPreview``: that one opens the hiker's gallery at the photo it
/// is showing, and this one opens nothing.
///
/// There *is* a gallery to open now — ``CommunityPhotoViewer``, reached from
/// the strip on the sheet in front of this map — so this is a deliberate
/// asymmetry rather than an absence. The strip is where a hike's photographs
/// are listed in order and is the thing a hiker is reading when they want to
/// see one properly; this pin's whole job is to answer *where*, and a tap that
/// opened a full-screen viewer over a preview would be a third screen deep
/// into a hike nobody has decided to keep yet. Revisit it as a change to what
/// a map callout is for, not as a gap left by the viewer.
final class CommunityPhotoCalloutPreview: UIView {
    /// The same 4:3 box ``PhotoCalloutPreview`` uses, for the same reason: wide
    /// enough to read as a photograph, narrow enough that MapKit's callout
    /// does not have to stretch around it.
    private static let previewWidth: CGFloat = 180
    private static let previewHeight: CGFloat = 135
    private static let cornerRadius: CGFloat = 10
    private static let placeholderPointSize: CGFloat = 28

    private let imageView = UIImageView()
    /// Which photograph is on screen, so a decode that lands after the view
    /// has been recycled onto another pin is dropped rather than drawn.
    private var photoID: Int?
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CommunityPhotoCalloutPreview is created in code only")
    }

    /// Points the preview at a photograph. Cheap to call again with the same
    /// one — MapKit re-runs `viewFor` on every reselect, and re-decoding there
    /// would flash the picture the reviewer is already looking at.
    func show(_ photo: CommunityPreviewPhoto) {
        accessibilityLabel = Self.label(for: photo)
        guard photoID != photo.index else { return }
        photoID = photo.index
        showPlaceholder("photo")
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            // The decode ``CommunityPhotoTile`` already owns, at this box's
            // size rather than the strip's. One decode path for these files,
            // so a picture that draws in the strip draws here.
            let decoded = await CommunityPhotoTile.decodeUIImage(
                photo.fileURL,
                maxPixelSize: Int(Self.previewWidth * 3)
            )
            guard let self, photoID == photo.index else { return }
            guard let decoded else {
                // The file is in a directory this app wrote a moment ago, so
                // this is the screen having been torn down mid-flight far more
                // often than a corrupt image. Either way there is nothing to
                // do about it from a callout.
                showPlaceholder("exclamationmark.triangle")
                return
            }
            imageView.contentMode = .scaleAspectFill
            imageView.image = decoded
        }
    }

    private func buildHierarchy() {
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemFill
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.previewWidth),
            heightAnchor.constraint(equalToConstant: Self.previewHeight),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        isAccessibilityElement = true
        accessibilityIdentifier = "community-photo-pin-preview"
    }

    /// A glyph rather than a spinner, for the reason the strip's tiles use
    /// one: the file is already on disk and arrives within a frame or two, and
    /// a spinner that appears and vanishes reads as a glitch.
    private func showPlaceholder(_ symbolName: String) {
        imageView.contentMode = .center
        imageView.tintColor = .tertiaryLabel
        imageView.image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Self.placeholderPointSize
            )
        )
    }

    /// VoiceOver cannot describe a photograph, so it says the one thing this
    /// app knows about this one — and does not offer to open it, because
    /// nothing here does.
    private static func label(for photo: CommunityPreviewPhoto) -> String {
        String(localized: "Photo taken \(HikeFormat.timestamp(photo.capturedAt))")
    }
}
#endif

// MARK: - The previewed hike's photo pins

extension MapView.Coordinator {
    /// Observes the pins the open preview has published and applies them
    /// imperatively, then re-registers — the arrangement every other layer on
    /// this map uses, so a preview's photographs landing moves MapKit's
    /// annotations and no SwiftUI view.
    ///
    /// Idempotent, like every other registration here: `withObservationTracking`
    /// offers no way to cancel one, so a second would leave two observers
    /// rebuilding the same annotations forever.
    func observeCommunityPhotoPins(_ browser: CommunityBrowser, on mapView: MKMapView) {
        guard !isObservingCommunityPhotoPins else { return }
        isObservingCommunityPhotoPins = true
        trackCommunityPhotoPins(browser, on: mapView)
    }

    private func trackCommunityPhotoPins(_ browser: CommunityBrowser, on mapView: MKMapView) {
        applyCommunityPhotoPins(browser.photoPins, on: mapView)
        withObservationTracking {
            _ = browser.photoPins
        } onChange: { [weak self, weak mapView, weak browser] in
            let coordinator = self
            let map = mapView
            let model = browser
            Task { @MainActor in
                guard let coordinator, let map, let model else { return }
                coordinator.trackCommunityPhotoPins(model, on: map)
            }
        }
    }

    /// Rebuilds the pins wholesale rather than diffing them.
    ///
    /// At most ``CommunityPublisher/maximumPhotos`` of them, and this runs when
    /// a preview opens, closes, or has a photograph taken off it — never at
    /// drag or fix frequency. The guard is what keeps a republish of the same
    /// photographs from dropping and re-dropping every marker.
    func applyCommunityPhotoPins(_ photos: [CommunityPreviewPhoto], on mapView: MKMapView) {
        guard communityPhotoAnnotations.map(\.photo) != photos else { return }
        if !communityPhotoAnnotations.isEmpty {
            mapView.removeAnnotations(communityPhotoAnnotations)
            communityPhotoAnnotations = []
        }
        guard !photos.isEmpty else { return }
        let annotations = photos.map(CommunityPhotoMapAnnotation.init)
        communityPhotoAnnotations = annotations
        mapView.addAnnotations(annotations)
    }

    /// A camera in a marker, with the photograph in the callout it opens.
    ///
    /// The app's tint, like the hike markers beside it and for the same
    /// reason: the route tint belongs to a hike the hiker owns, and this is
    /// somebody else's walk. What tells the two markers apart is the glyph,
    /// which is the honest difference — one is a trail, one is a picture of
    /// one.
    func communityPhotoAnnotationView(
        for annotation: CommunityPhotoMapAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView {
        let identifier = CommunityPhotoMapAnnotation.reuseIdentifier
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        view.annotation = annotation
        view.canShowCallout = true
        #if os(iOS)
        view.glyphImage = UIImage(systemName: "camera.fill")
        view.markerTintColor = .tintColor
        let preview = view.detailCalloutAccessoryView as? CommunityPhotoCalloutPreview
            ?? CommunityPhotoCalloutPreview()
        preview.show(annotation.photo)
        view.detailCalloutAccessoryView = preview
        #endif
        // Never hidden by a neighbour — see this file's header.
        view.displayPriority = .required
        // MapKit would otherwise speak "Photo" alone, which says nothing about
        // whose walk this picture is of.
        view.accessibilityLabel = String(
            localized: "Community hike photo, taken \(HikeFormat.timestamp(annotation.photo.capturedAt))"
        )
        view.accessibilityIdentifier = "community-photo-pin"
        return view
    }
}
