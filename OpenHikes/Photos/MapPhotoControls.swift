//
//  MapPhotoControls.swift
//  OpenHikes
//
//  The camera pill: two buttons on the map's leading edge, opposite the "my
//  location" button, for photographing the trail you're on and for adding a
//  picture you already took.
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
//  The two buttons are grouped the way iOS groups a pair of bar items: a
//  `UIGlassContainerEffect` renders both glass shapes in one pass and merges
//  them as they come close, so they read as one pill with a seam rather than
//  as two floating circles.
//

import Foundation

#if os(iOS)
import UIKit

/// The pill itself. Owns its appearance and its two actions, and nothing else
/// — where it sits is decided by ``MapView/Coordinator/applySheetTop(on:)``,
/// which positions it and the tracking button together.
final class MapPhotoControlsView: UIView {
    /// Matches the tracking button's height, so the two controls line up
    /// across the map rather than merely sitting near each other.
    static let controlSize: CGFloat = 44
    /// Under the 4pt gap between the two buttons, so they are separate targets
    /// at rest and their glass merges into one shape — the same relationship
    /// ``ActionTileMetrics/glassSpacing`` describes for the tiles in the sheet.
    private static let glassMergeSpacing: CGFloat = 10
    private static let buttonSpacing: CGFloat = 4
    private static let symbolPointSize: CGFloat = 17

    private let onCamera: () -> Void
    private let onLibrary: () -> Void

    init(onCamera: @escaping () -> Void, onLibrary: @escaping () -> Void) {
        self.onCamera = onCamera
        self.onLibrary = onLibrary
        super.init(frame: .zero)
        buildHierarchy()
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

        let stack = UIStackView(arrangedSubviews: [
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
        stack.axis = .horizontal
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
    /// How long the pill takes to arrive or leave when the sheet navigates on
    /// to — or away from — a screen that can receive a photo. Short enough to
    /// feel like part of the push, long enough not to be a blink.
    private static let photoControlsFadeDuration: TimeInterval = 0.25

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
        withObservationTracking {
            _ = controller.isAvailable
        } onChange: { [weak self, weak controller] in
            let coordinator = self
            let model = controller
            Task { @MainActor in
                guard let coordinator, let model else { return }
                coordinator.applyPhotoControlsVisibility(animated: true)
                coordinator.trackPhotoControls(model)
            }
        }
    }

    private func applyPhotoControlsVisibility(animated: Bool) {
        #if os(iOS)
        guard let photoControls else { return }
        let visible = photoCaptureController?.isAvailable == true
        // Hidden as well as transparent: a control that is invisible but still
        // in the hierarchy answers hit tests, and this one sits over the map
        // the user is panning.
        //
        // Interaction goes at once rather than when the fade lands, for the
        // same reason: a pill on its way out is still a tap target for the
        // whole quarter-second it takes to leave.
        photoControls.isUserInteractionEnabled = visible
        if visible { photoControls.isHidden = false }
        let target = visible ? photoControlsSheetAlpha : 0
        guard animated else {
            photoControls.alpha = target
            photoControls.isHidden = !visible
            return
        }
        UIView.animate(withDuration: Self.photoControlsFadeDuration) {
            photoControls.alpha = target
        } completion: { [weak self] _ in
            // Re-read rather than trusting the value this animation started
            // with: a push and an immediate pop overlap, and a completion that
            // hid the pill the *next* animation had just brought back would
            // leave a visible control that answers no taps.
            guard let self,
                  photoCaptureController?.isAvailable != true else { return }
            photoControls.isHidden = true
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
