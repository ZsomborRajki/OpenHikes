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
    /// Deliberately absent, the same division ``PhotoMapAnnotation`` makes: the
    /// picture below is the callout's content, and heading a photograph with
    /// the word "Photo" says nothing it has not already said.
    @objc let title: String? = nil
    /// When it was taken, which is the one fact about somebody else's
    /// photograph this app actually knows. It is also what the share sheet
    /// promised went with the picture, so saying it here is the app showing
    /// what it said it would carry.
    @objc let subtitle: String?

    init(photo: CommunityPreviewPhoto) {
        self.photo = photo
        coordinate = photo.coordinate
        subtitle = HikeFormat.timestamp(photo.capturedAt)
        super.init()
    }
}

#if os(iOS)
/// The picture inside a community photo pin's callout, and the way into the
/// gallery.
///
/// A `UIControl` for the reason ``PhotoCalloutPreview`` is, and now with the
/// same job: it opens ``CommunityPhotoViewer`` at the photograph it is showing.
///
/// This used to open nothing, on the argument that a pin's whole job is to
/// answer *where* and that the strip on the sheet is where pictures are looked
/// at properly. What that argument missed is the direction people arrive from:
/// somebody who has found a photograph on the map has already decided which
/// one they want, and sending them back to a strip to find it again is asking
/// them to do the pin's work twice. The map is now a way in as well as an
/// answer, for a stranger's hike as much as for the hiker's own.
final class CommunityPhotoCalloutPreview: PhotoCalloutPreviewControl {
    /// Which photograph is on screen, so a decode that lands after the view
    /// has been recycled onto another pin is dropped rather than drawn.
    ///
    /// The whole photograph rather than its ``CommunityPreviewPhoto/index``,
    /// which is what this was. An index numbers a picture *within one
    /// preview*, and these views are pooled across previews: closing one hike
    /// and opening another hands pin 0 a recycled view whose remembered index
    /// is already 0, so the reload below was skipped and the callout showed
    /// the previous hike's photograph — under a tap that opens this hike's
    /// gallery.
    private var shown: CommunityPreviewPhoto?
    private var loadTask: Task<Void, Never>?
    private var onTap: ((Int) -> Void)?

    init() {
        super.init(accessibilityIdentifier: "community-photo-pin-preview")
    }

    /// Points the preview at a photograph. Cheap to call again with the same
    /// one — MapKit re-runs `viewFor` on every reselect, and re-decoding there
    /// would flash the picture the reviewer is already looking at.
    func show(_ photo: CommunityPreviewPhoto, onTap: @escaping (Int) -> Void) {
        self.onTap = onTap
        accessibilityLabel = Self.label(for: photo)
        guard shown != photo else { return }
        shown = photo
        showPlaceholder("photo")
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            // The decode ``CommunityPhotoTile`` already owns, at this box's
            // size rather than the strip's. One decode path for these files,
            // so a picture that draws in the strip draws here.
            let decoded = await CommunityPhotoTile.decodeUIImage(
                photo.fileURL,
                maxPixelSize: Int(PhotoCalloutMetrics.previewWidth * 3)
            )
            guard let self, shown == photo else { return }
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

    override func handleTap() {
        guard let shown else { return }
        onTap?(shown.index)
    }

    /// VoiceOver cannot describe a photograph, so it says the one thing this
    /// app knows about this one, and the button trait above says what happens
    /// if you open it.
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
        // After the pins, always — see `applyPhotoPinSelection(_:on:)`, which
        // this mirrors and for the same reason: the gallery that asks is
        // pushed over the screen that owns them.
        applyCommunityPhotoPinSelection(browser.photoPinSelection, on: mapView)
        withObservationTracking {
            _ = browser.photoPins
            _ = browser.photoPinSelection
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
            // One of them may have been the open callout — see
            // ``refreshOpenCallout(on:)``.
            refreshOpenCallout(on: mapView)
        }
        guard !photos.isEmpty else { return }
        let annotations = photos.map(CommunityPhotoMapAnnotation.init)
        communityPhotoAnnotations = annotations
        mapView.addAnnotations(annotations)
    }

    /// Opens a pin's callout because the gallery asked for it. The community
    /// counterpart of `applyPhotoPinSelection(_:on:)`, down to keeping a
    /// request whose pin is not on the map yet.
    func applyCommunityPhotoPinSelection(
        _ selection: CommunityPhotoPinSelection?,
        on mapView: MKMapView
    ) {
        guard let selection,
              appliedCommunityPhotoPinSelection != selection.token else { return }
        guard let annotation = communityPhotoAnnotations.first(
            where: { $0.photo.index == selection.index }
        ) else { return }
        appliedCommunityPhotoPinSelection = selection.token
        mapView.selectAnnotation(annotation, animated: true)
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
        preview.show(annotation.photo) { [weak self, weak mapView] index in
            // Closed before the gallery opens, like the hiker's own pins: the
            // callout belongs to a map the sheet is about to cover, and one
            // left standing is what they come back to when they pop the viewer.
            mapView?.deselectAnnotation(annotation, animated: true)
            self?.community?.openPreviewPhoto(index)
        }
        view.detailCalloutAccessoryView = preview
        #endif
        // Never hidden by a neighbour — see this file's header.
        view.displayPriority = .required
        // The pin carries no title now, so without this MapKit would speak the
        // capture time alone, which says nothing about whose walk this picture
        // is of.
        view.accessibilityLabel = String(
            localized: "Community hike photo, taken \(HikeFormat.timestamp(annotation.photo.capturedAt))"
        )
        view.accessibilityIdentifier = "community-photo-pin"
        return view
    }
}
