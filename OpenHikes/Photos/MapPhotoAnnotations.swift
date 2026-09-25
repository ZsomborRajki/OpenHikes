//
//  MapPhotoAnnotations.swift
//  OpenHikes
//
//  The photo pins themselves: a marker on the trail where a picture was taken,
//  and the picture inside its callout.
//
//  Built out of MapKit's own pieces rather than a custom annotation view.
//  `MKMarkerAnnotationView` already draws the balloon, the shadow, the drop
//  animation, the selection growth and the decluttering that keeps two pins a
//  few metres apart from sitting on top of each other — and its callout
//  already draws the rounded card, the arrow, the title and the dismissal.
//  What is actually app-specific is one square of pixels, and that is exactly
//  what ``detailCalloutAccessoryView`` is for. Redrawing the rest by hand
//  would be re-implementing MapKit in order to look like MapKit.
//
//  The preview is a `UIControl` rather than a plain image view because tapping
//  the picture is the way into the gallery. It carries its own action instead
//  of relying on `calloutAccessoryControlTapped(_:)`, which MapKit documents
//  for the left and right accessories; a control that handles its own touches
//  is true of every accessory slot.
//
//  Nothing here decodes on the main thread. The callout comes up with a
//  placeholder and the thumbnail arrives when ``HikePhotoLoader`` has it,
//  keyed on the photo so a recycled view never shows the previous pin's
//  picture.
//

import MapKit
import OpenHikesData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One ``PhotoMapPin``, in the shape MapKit wants it.
final class PhotoMapAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "photoMapPin"

    let pin: PhotoMapPin
    @objc dynamic let coordinate: CLLocationCoordinate2D
    /// Deliberately absent. The callout's content is the photograph itself,
    /// and a header reading "Photo" over a photograph says nothing the picture
    /// has not already said. MapKit draws the callout around the detail
    /// accessory on its own once there is nothing to head it with.
    @objc let title: String? = nil
    /// Only set where a point has more than one photo, so the callout admits
    /// that the picture above it is the first of several rather than the only
    /// one.
    @objc let subtitle: String?

    init(pin: PhotoMapPin) {
        self.pin = pin
        coordinate = pin.coordinate
        subtitle = pin.count > 1
            ? String(localized: "First of \(pin.count) photos taken here")
            : nil
        super.init()
    }
}

#if os(iOS)
/// The picture inside a photo pin's callout, and the way into the gallery.
final class PhotoCalloutPreview: PhotoCalloutPreviewControl {
    /// What the view is currently showing, so a decode that lands after the
    /// view has been recycled onto another pin is dropped rather than drawn.
    private var photoID: UUID?
    /// What the last finished load found, or `nil` while one is in flight and
    /// for a photo that drew.
    ///
    /// Kept because a reselect re-enters ``show(_:store:onTap:)`` for the same
    /// pin and returns without loading again: the glyph on screen survives
    /// that, and without this the sentence describing it would not.
    private var unavailability: PhotoUnavailability?
    private var loadTask: Task<Void, Never>?
    private var onTap: ((UUID) -> Void)?

    init() {
        super.init(accessibilityIdentifier: "photo-pin-preview")
    }

    /// Points the preview at a pin. Cheap to call again with the same one —
    /// MapKit re-runs `viewFor` whenever a pin is reselected, and re-decoding
    /// there would flash the picture the user is already looking at.
    func show(
        _ pin: PhotoMapPin,
        store: HikePhotoStore,
        onTap: @escaping (UUID) -> Void
    ) {
        self.onTap = onTap
        // Recomputed on every call rather than only for a new photo: a pin's
        // count changes under a preview that is still showing the same leading
        // photo. What must *not* be lost with it is what the load found, which
        // is why that is remembered rather than re-derived — the reselect
        // below returns without asking the store again.
        accessibilityLabel = Self.label(for: pin, unavailable: unavailability)
        guard photoID != pin.photo.id else { return }
        photoID = pin.photo.id
        unavailability = nil
        showPlaceholder("photo")
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let display = await HikePhotoLoader.thumbnail(for: pin.photo, in: store)
            guard let self, photoID == pin.photo.id else { return }
            switch display {
            case .ready(let loaded):
                imageView.contentMode = .scaleAspectFill
                imageView.image = loaded.image
            case .unavailable(let reason):
                // The callout is the one place a photo is shown without the
                // user having asked for it, so it says the least it can and
                // leaves the explanation to the page a tap opens.
                unavailability = reason
                showPlaceholder(Self.symbol(for: reason))
                accessibilityLabel = Self.label(for: pin, unavailable: reason)
            case .loading:
                // Cancelled before it ran — this preview is being recycled
                // onto another pin, which will set its own placeholder.
                break
            }
        }
    }

    private static func symbol(for reason: PhotoUnavailability) -> String {
        switch reason {
        case .notOnThisDevice: "icloud.slash"
        case .unreadable: "exclamationmark.triangle"
        // A pin rather than a broken picture: on this surface the row is not
        // failing at anything. Where it was taken is exactly what it has, and
        // exactly what the map is for.
        case .placeOnly: "mappin.and.ellipse"
        }
    }

    override func handleTap() {
        guard let photoID else { return }
        onTap?(photoID)
    }

    /// VoiceOver cannot describe a photograph, so the preview says what the
    /// gallery's own tiles say about one — when it was taken, and that
    /// activating it opens it.
    private static func label(for pin: PhotoMapPin) -> String {
        let taken = HikeFormat.timestamp(pin.photo.capturedAt)
        return pin.count > 1
            ? String(localized: "Open photo taken \(taken), first of \(pin.count) taken here")
            : String(localized: "Open photo taken \(taken)")
    }

    /// The same, once the decode has come back with nothing: a glyph says as
    /// much to a sighted user, and this is the sentence that says it to
    /// everyone else. Still "open", because the page a tap opens is where the
    /// state is explained.
    ///
    /// `nil` is a picture that drew, or one still being decoded — both of
    /// which the name alone describes.
    private static func label(
        for pin: PhotoMapPin,
        unavailable reason: PhotoUnavailability?
    ) -> String {
        let base = label(for: pin)
        switch reason {
        case .none:
            return base
        case .notOnThisDevice:
            return String(localized: "\(base), not on this device")
        case .unreadable:
            return String(localized: "\(base), unavailable")
        case .placeOnly:
            return String(localized: "\(base), place only, no photo in the file")
        }
    }
}
#endif

// MARK: - Photo pins on the map

extension MapView.Coordinator {
    /// Observes the pins a screen has published and applies them imperatively,
    /// then re-registers — the same arrangement ``observeHighlight(_:on:)``
    /// uses, so taking a photo redraws MapKit's annotations and no SwiftUI
    /// view.
    ///
    /// Idempotent, like ``observePhotoControls(_:)``: `withObservationTracking`
    /// offers no way to cancel a registration, so a second one would leave two
    /// observers rebuilding the same annotations forever.
    func observePhotoPins(_ controller: PhotoMapPinController, on mapView: MKMapView) {
        guard !isObservingPhotoPins else { return }
        isObservingPhotoPins = true
        trackPhotoPins(controller, on: mapView)
    }

    private func trackPhotoPins(_ controller: PhotoMapPinController, on mapView: MKMapView) {
        photoPinController = controller
        applyPhotoPins(controller.pins, on: mapView)
        // After the pins, always: a selection asked for while they were off the
        // map — which is every one, since the gallery is pushed over the screen
        // that owns them — can only be applied once they are back.
        applyPhotoPinSelection(controller.selection, on: mapView)
        reobserving(self, mapView, controller) {
            _ = controller.pins
            _ = controller.selection
        } onChange: { coordinator, map, model in
            coordinator.trackPhotoPins(model, on: map)
        }
    }

    /// Rebuilds the pins wholesale rather than diffing them.
    ///
    /// A hike has a gallery's worth of photos, not a route's worth of points,
    /// and this runs when one is taken, imported or deleted — never at drag or
    /// fix frequency. The guard above it is what keeps a republish of the same
    /// list from dropping and re-dropping every marker on the map.
    func applyPhotoPins(_ pins: [PhotoMapPin], on mapView: MKMapView) {
        guard photoAnnotations.map(\.pin) != pins else { return }
        if !photoAnnotations.isEmpty {
            mapView.removeAnnotations(photoAnnotations)
            photoAnnotations = []
            // One of them may have been the open callout — see
            // ``refreshOpenCallout(on:)``.
            refreshOpenCallout(on: mapView)
        }
        guard !pins.isEmpty else { return }
        let annotations = pins.map(PhotoMapAnnotation.init)
        photoAnnotations = annotations
        mapView.addAnnotations(annotations)
    }

    /// Opens a pin's callout because the gallery asked for it.
    ///
    /// A request for a pin that is not on the map is kept rather than dropped:
    /// the pins are republished a moment later when the screen that owns them
    /// comes back, and this runs again then. Which also means the token is
    /// recorded only once a pin has actually answered.
    func applyPhotoPinSelection(
        _ selection: PinSelection?,
        on mapView: MKMapView
    ) {
        guard let selection, appliedPhotoPinSelection != selection.token else { return }
        guard let annotation = photoAnnotations.first(
            where: { $0.pin.photo.id == selection.photoID }
        ) else { return }
        appliedPhotoPinSelection = selection.token
        mapView.selectAnnotation(annotation, animated: true)
    }

    /// Recolours the markers in place when the route's tint moves, so a colour
    /// drag doesn't leave the pins on the previous hue until something else
    /// rebuilds them — the same job ``refreshHighlightColor(on:)`` does for the
    /// selection dot, done without removing an annotation the user may have
    /// open.
    func refreshPhotoPinColor(on mapView: MKMapView) {
        for annotation in photoAnnotations {
            guard let view = mapView.view(for: annotation) as? MKMarkerAnnotationView else { continue }
            applyMarkerTint(to: view)
        }
    }

    /// A marker in the route's tint with a camera glyph, and the photo itself
    /// in the callout MapKit draws for it.
    func photoAnnotationView(
        for annotation: PhotoMapAnnotation,
        on mapView: MKMapView
    ) -> MKAnnotationView {
        let view = mapView.reusableView(
            MKMarkerAnnotationView.self,
            for: annotation,
            reuseIdentifier: PhotoMapAnnotation.reuseIdentifier
        )
        view.canShowCallout = true
        view.glyphImage = Self.photoPinGlyph
        // A photo is a place the user asked to be shown; letting MapKit hide
        // one to declutter would answer the "show me where this was taken"
        // button with an empty map.
        view.displayPriority = .required
        // The pin carries no title now, so without this MapKit would speak the
        // subtitle alone, or nothing at all where a point holds one photo.
        view.accessibilityLabel = Self.markerLabel(for: annotation.pin)
        view.accessibilityIdentifier = "photo-pin"
        applyMarkerTint(to: view)
        attachPreview(for: annotation, to: view, on: mapView)
        return view
    }

    /// What the marker itself says, as distinct from the preview inside its
    /// callout: this one is a place on the trail, not the way into the photo.
    private static func markerLabel(for pin: PhotoMapPin) -> String {
        let taken = HikeFormat.timestamp(pin.photo.capturedAt)
        return pin.count > 1
            ? String(localized: "\(pin.count) photos taken here, first on \(taken)")
            : String(localized: "Photo taken \(taken)")
    }

    private func applyMarkerTint(to view: MKMarkerAnnotationView) {
        #if os(macOS)
        view.markerTintColor = NSColor(routeTint)
        #else
        view.markerTintColor = UIColor(routeTint)
        #endif
    }

    private func attachPreview(
        for annotation: PhotoMapAnnotation,
        to view: MKMarkerAnnotationView,
        on mapView: MKMapView
    ) {
        #if os(iOS)
        let preview = view.detailCalloutAccessoryView as? PhotoCalloutPreview
            ?? PhotoCalloutPreview()
        view.detailCalloutAccessoryView = preview
        let store = photoPinController?.store ?? .shared
        preview.show(annotation.pin, store: store) { [weak self, weak mapView] photoID in
            // Closed before the gallery opens: the callout belongs to a map
            // the sheet is about to cover, and one left standing is what the
            // user comes back to when they pop the viewer.
            mapView?.deselectAnnotation(annotation, animated: true)
            self?.photoPinController?.open(photoID)
        }
        #endif
    }

    /// A camera rather than a picture: the glyph sits inside a marker at about
    /// 20pt, where a thumbnail would be a smudge. The picture is what the
    /// callout is for.
    private static var photoPinGlyph: PhotoImage? {
        #if os(iOS)
        UIImage(systemName: "camera.fill")
        #else
        nil
        #endif
    }
}
