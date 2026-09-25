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
//  The buttons are grouped the way iOS groups bar items: a
//  `UIGlassContainerEffect` renders every glass shape in one pass and merges
//  them as they come close, so they read as one pill with seams rather than
//  as floating circles. Stacked vertically since *Add Place* joined them —
//  three abreast took a third of a phone's width off the map — with *Add
//  Place* on top, so the pill grows upward from the edge it is pinned to and
//  the camera and the library buttons stay put whether it is offered or not.
//

import Foundation

#if os(iOS)
import OpenHikesData
import UIKit

/// The pill itself. Owns its appearance and its actions, and nothing else
/// — where it sits is decided by ``MapView/Coordinator/applySheetTop(on:)``,
/// which positions it and the tracking button together.
final class MapPhotoControlsView: UIView {
    /// The height every floating control on this map shares, so they line up
    /// across it rather than merely sitting near each other. The tracking
    /// button's capsule takes its size from here too — see
    /// ``MapView/makeTrackingButton(for:_:)``.
    static let controlSize: CGFloat = 44
    /// Over the 4pt gap between the buttons, so their glass merges into one
    /// shape at rest while each button stays a target of its own — the
    /// opposite of ``ActionTileMetrics/glassSpacing``, which keeps the sheet's
    /// tiles apart until their row tightens.
    private static let glassMergeSpacing: CGFloat = 10
    private static let buttonSpacing: CGFloat = 4
    private static let symbolPointSize: CGFloat = 17

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
        let container = UIVisualEffectView(
            effect: {
                let effect = UIGlassContainerEffect()
                effect.spacing = Self.glassMergeSpacing
                return effect
            }()
        )
        container.translatesAutoresizingMaskIntoConstraints = false

        let addPlace = glassButton(
            symbol: "mappin.and.ellipse",
            label: String(localized: "Add a place to this trail"),
            identifier: "map-add-place-button",
            action: onAddPlace
        )
        // Withdrawn until a screen says where a place would go.
        addPlace.isHidden = true
        addPlaceButton = addPlace

        let stack = UIStackView(arrangedSubviews: [
            addPlace,
            glassButton(
                symbol: "camera.fill",
                label: String(localized: "Take a photo of this trail"),
                identifier: "map-camera-button",
                action: onCamera
            ),
            glassButton(
                symbol: "photo.on.rectangle.angled",
                label: String(localized: "Add a photo from your library"),
                identifier: "map-photo-library-button",
                action: onLibrary
            ),
        ])
        stack.axis = .vertical
        stack.spacing = Self.buttonSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(container)
        container.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor),
        ])
    }

    /// One glass capsule with a glyph-only button inside it.
    ///
    /// The button is sized to ``AccessibilityMetrics/minimumTapTarget`` rather
    /// than to its symbol, and carries a spoken name of its own: a glyph is
    /// not a label, and `performAccessibilityAudit` measures both — the same
    /// rule ``minimumTapTarget()`` and the explicit `accessibilityLabel`s
    /// enforce on the SwiftUI side.
    private func glassButton(
        symbol: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> UIView {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Self.symbolPointSize,
                weight: .medium
            )
        )
        let button = UIButton(
            configuration: configuration,
            primaryAction: UIAction { _ in action() }
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier

        let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerConfiguration = .capsule()
        glass.contentView.addSubview(button)

        NSLayoutConstraint.activate([
            glass.widthAnchor.constraint(equalToConstant: Self.controlSize),
            glass.heightAnchor.constraint(equalToConstant: Self.controlSize),
            button.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])
        return glass
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
