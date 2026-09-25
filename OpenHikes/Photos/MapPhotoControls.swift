//
//  MapPhotoControls.swift
//  OpenHikes
//
//  The camera pill: buttons on the map's leading edge, opposite the "my
//  location" button, for photographing the trail you're on, for adding a
//  picture you already took, and — on a saved hike's screen — for adding a
//  place of your own to the trail (see ``HikePlaceAdder``).
//
//  UIKit rather than a SwiftUI overlay, and that is the whole point of it. The
//  pill has to sit at exactly the height the tracking button sits at, follow
//  the sheet exactly as it follows it, and fade out exactly where it fades —
//  and the tracking button does all of that through a constraint constant that
//  a drag reaches without a SwiftUI pass in between. A second control drawn in
//  SwiftUI would have to re-derive the same geometry from a `GeometryReader`
//  that cannot see the safe area the map ignores, and would re-render at drag
//  frequency to stay level with a button that never re-renders at all. Sharing
//  `applySheetTop` instead makes misalignment impossible rather than unlikely.
//
//  The buttons are grouped the way iOS groups bar items — see
//  ``MapGlassPill``, which the trail maker's pill is built from too. Stacked
//  vertically since *Add Place* joined them — three abreast took a third of a
//  phone's width off the map — with *Add Place* on top, so the pill grows
//  upward from the edge it is pinned to and the camera and the library buttons
//  stay put whether it is offered or not.
//

import Foundation

#if os(iOS)
import OpenHikesData
import UIKit

/// The pill itself. Owns its appearance and its actions, and nothing else
/// — where it sits is decided by ``MapView/Coordinator/applySheetTop(on:)``,
/// which positions it and the tracking button together.
final class MapPhotoControlsView: UIView {
    private let onCamera: () -> Void
    private let onLibrary: () -> Void
    private let onAddPlace: () -> Void
    /// The *Add Place* button's glass, hidden while the screen offering the
    /// pill has nowhere to put a place. A hidden arranged subview leaves the
    /// stack, so the pill is two buttons tall then rather than three with a
    /// gap. See ``setAddPlaceVisible(_:)``.
    private(set) var addPlaceButton: UIView?

    init(
        onCamera: @escaping () -> Void,
        onLibrary: @escaping () -> Void,
        onAddPlace: @escaping () -> Void = { /* no-op default */ }
    ) {
        self.onCamera = onCamera
        self.onLibrary = onLibrary
        self.onAddPlace = onAddPlace
        super.init(frame: .zero)
        buildHierarchy()
    }

    /// Offers or withdraws *Add Place*, leaving the other two where they are.
    ///
    /// The map is told to lay out as well. The stack re-arranges itself at
    /// once, but nothing marks the map as needing a pass, so until something
    /// else moved it the pill kept its two-button frame with the third button
    /// standing above it — drawn, and outside the bounds a tap is tested
    /// against.
    func setAddPlaceVisible(_ visible: Bool) {
        guard let addPlaceButton, addPlaceButton.isHidden == visible else { return }
        addPlaceButton.isHidden = !visible
        superview?.setNeedsLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MapPhotoControlsView is created in code only")
    }

    private func buildHierarchy() {
        let addPlace = MapGlassPill.button(
            symbol: "mappin.and.ellipse",
            label: String(localized: "Add a place to this trail"),
            identifier: "map-add-place-button",
            action: onAddPlace
        ).glass
        // Withdrawn until a screen says where a place would go.
        addPlace.isHidden = true
        addPlaceButton = addPlace

        MapGlassPill.install(
            [
                addPlace,
                MapGlassPill.button(
                    symbol: "camera.fill",
                    label: String(localized: "Take a photo of this trail"),
                    identifier: "map-camera-button",
                    action: onCamera
                ).glass,
                MapGlassPill.button(
                    symbol: "photo.on.rectangle.angled",
                    label: String(localized: "Add a photo from your library"),
                    identifier: "map-photo-library-button",
                    action: onLibrary
                ).glass,
            ],
            in: self
        )
    }
}
#endif

extension MapView.Coordinator {
    /// Observes whether a photo can be taken right now and shows or hides the
    /// pill, then re-registers — the same imperative arrangement
    /// ``observeSheetMetrics(_:on:)`` uses, so navigating between screens never
    /// re-renders the map.
    ///
    /// Idempotent, like ``observeLocation(_:on:)``: a second registration
    /// would leave two observers running two overlapping fade animations
    /// against the same view, and `withObservationTracking` offers no way to
    /// cancel the first.
    func observePhotoControls(_ controller: PhotoCaptureController) {
        guard !isObservingPhotoControls else { return }
        isObservingPhotoControls = true
        trackPhotoControls(controller)
    }

    private func trackPhotoControls(_ controller: PhotoCaptureController) {
        photoCaptureController = controller
        applyPhotoControlsVisibility(animated: false)
        reobserving(self, controller) {
            _ = controller.isAvailable
            _ = controller.canAddPlace
        } onChange: { coordinator, model in
            coordinator.applyPhotoControlsVisibility(animated: true)
            coordinator.trackPhotoControls(model)
        }
    }

    private func applyPhotoControlsVisibility(animated: Bool) {
        #if os(iOS)
        guard let photoControls else { return }
        let visible = photoCaptureController?.isAvailable == true
        // Decided only while the pill is showing: one on its way out keeps
        // the buttons it had, rather than shrinking as it fades.
        if visible {
            photoControls.setAddPlaceVisible(photoCaptureController?.canAddPlace == true)
        }
        photoControls.fadeMapControl(
            visible: visible,
            restingAlpha: photoControlsSheetAlpha,
            animated: animated
        ) { [weak self] in
            guard let self else { return false }
            return photoCaptureController?.isAvailable != true
        }
        #endif
    }

    /// Applies the sheet's own fade, which is shared with the tracking button.
    ///
    /// Kept apart from the visibility above because the two answer different
    /// questions — "is there a hike to photograph?" and "has the sheet covered
    /// this part of the map?" — and both have to be true for the pill to be
    /// seen. The sheet's value is remembered so a fade-in that starts mid-drag
    /// arrives at the right opacity rather than at 1.
    func applyPhotoControlsAlpha(_ alpha: CGFloat) {
        #if os(iOS)
        photoControlsSheetAlpha = alpha
        guard let photoControls,
              photoCaptureController?.isAvailable == true,
              photoControls.alpha != alpha else { return }
        photoControls.alpha = alpha
        #endif
    }
}
