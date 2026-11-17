//
//  MapCoordinator+JunctionButton.swift
//  OpenHikes
//
//  The junction warnings button, on the map's leading edge while a walk is
//  under way: what turns ``JunctionGuide`` on and off.
//
//  On the map rather than in Settings, by the owner's decision, so the
//  warnings are a tap away on the walk they are for. On the leading edge,
//  the side the walk's own buttons are not, standing on whatever stands in
//  the slot above the credit line — the camera pill on a hike's screen, the
//  maker's pill on the search screen, or the line itself when neither is up
//  — as the 2D button stands on the tracking pill across the map. It takes
//  the sheet's fade with the rest of that column.
//
//  A toggle, shown as the tracking button shows its state: the glyph in the
//  label colour while off, in the accent while on. The state is also its
//  accessibility trait, because a tint is not something VoiceOver can see.
//
//  Shown while a walk is under way, paused included, so the warnings can be
//  set before setting off again. A trail nobody is walking has nothing for
//  it to do: the guide speaks only for a walk that is following.
//

import MapKit
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
/// What the coordinator keeps of the button.
struct JunctionButtonParts {
    weak var glass: UIView?
    weak var button: UIButton?
    weak var guide: JunctionGuide?
    /// The three things the button can stand on, one constraint each, and
    /// the pair for the credit line.
    var onPhotoControls: NSLayoutConstraint?
    var onTrailDraftControls: NSLayoutConstraint?
    var onCreditLine: CreditLineClearance?
    /// The opacity the sheet's position alone calls for, as the camera
    /// pill's ``MapView/Coordinator/photoControlsSheetAlpha`` is.
    var sheetAlpha: CGFloat = 1
    var isObserving = false
}

extension MapView.Coordinator {
    /// Starts drawing what `guide` says: whether there is a walk to offer the
    /// button for, and whether the warnings are on. Idempotent, as every
    /// observation here is.
    func observeJunctionGuide(_ guide: JunctionGuide) {
        guard !junctionButton.isObserving else { return }
        junctionButton.isObserving = true
        junctionButton.guide = guide
        applyJunctionButton(animated: false)
        trackJunctionGuide(guide)
    }

    /// Applied once a change, animated: applied again unanimated as the
    /// observation was renewed, the button stopped fading and vanished.
    private func trackJunctionGuide(_ guide: JunctionGuide) {
        reobserving(self, guide) {
            _ = guide.isOffered
            _ = guide.isOn
        } onChange: { coordinator, guide in
            coordinator.applyJunctionButton(animated: true)
            coordinator.trackJunctionGuide(guide)
        }
    }

    private func applyJunctionButton(animated: Bool) {
        guard let glass = junctionButton.glass, let button = junctionButton.button else { return }
        let isOn = junctionButton.guide?.isOn == true
        button.configuration?.baseForegroundColor = isOn ? Self.accentAsset : .label
        button.accessibilityTraits = isOn ? [.button, .selected] : .button
        applyJunctionButtonPlacement()
        glass.fadeMapControl(
            visible: junctionButton.guide?.isOffered == true,
            restingAlpha: junctionButton.sheetAlpha,
            animated: animated
        ) { [weak self] in
            self?.junctionButton.guide?.isOffered != true
        }
    }

    /// Stands the button on the pill in the slot above the credit line,
    /// whichever is up, or on the line when neither is.
    ///
    /// Asked whenever either pill is offered or withdrawn and whenever the
    /// line is hidden or shown, which are the only things that move what it
    /// stands on. It moves when the pill is offered or withdrawn, while the
    /// pill is still fading, and does not animate the move: the two happen
    /// on a navigation, when the sheet is moving too.
    func applyJunctionButtonPlacement() {
        let parts = junctionButton
        guard let onPhotoControls = parts.onPhotoControls,
              let onTrailDraftControls = parts.onTrailDraftControls,
              let onCreditLine = parts.onCreditLine
        else { return }
        let onPhoto = photoCaptureController?.isAvailable == true
        let onMaker = !onPhoto && trailDraftController?.isAvailable == true
        if onPhoto != onPhotoControls.isActive { onPhotoControls.isActive = onPhoto }
        if onMaker != onTrailDraftControls.isActive { onTrailDraftControls.isActive = onMaker }
        if onPhoto || onMaker {
            NSLayoutConstraint.deactivate([onCreditLine.above, onCreditLine.flush])
        } else {
            onCreditLine.apply(flush: attributionView?.isHidden ?? false)
        }
    }

    /// Applies the sheet's fade, which the button shares with the column it
    /// stands in.
    func applyJunctionButtonAlpha(_ alpha: CGFloat) {
        junctionButton.sheetAlpha = alpha
        guard let glass = junctionButton.glass,
              junctionButton.guide?.isOffered == true,
              glass.alpha != alpha
        else { return }
        glass.alpha = alpha
    }
}

extension MapView {
    /// The gap between the button and the pill under it, as between the 2D
    /// button and the tracking pill.
    private static let junctionButtonSpacing: CGFloat = 8
    /// A fork: the one SF Symbol that draws a way dividing in two.
    static let junctionButtonSymbol = "arrow.triangle.branch"

    /// The button, in a glass capsule of its own, withdrawn until its first
    /// pass says a walk is under way.
    ///
    /// Built after the two pills it can stand on, because its constraints
    /// name them.
    func addJunctionButton(
        to mapView: MKMapView,
        _ coordinator: Coordinator,
        alignedTo guide: UILayoutGuide
    ) {
        let parts = MapGlassPill.button(
            symbol: Self.junctionButtonSymbol,
            label: String(localized: "Junction Warnings"),
            identifier: "map-junction-warnings-button"
        ) { [weak coordinator] in
            coordinator?.junctionButton.guide?.toggle()
        }
        parts.button.configuration?.baseForegroundColor = .label
        parts.button.accessibilityHint = String(
            localized: "Says which way to go before each junction while you follow a trail."
        )
        coordinator.junctionButton.glass = parts.glass
        coordinator.junctionButton.button = parts.button
        coordinator.junctionButton.onCreditLine = placeInCreditLineSlot(
            parts.glass,
            on: mapView,
            coordinator,
            alignedTo: guide
        )
        if let photoControls = coordinator.photoControls {
            coordinator.junctionButton.onPhotoControls = parts.glass.bottomAnchor.constraint(
                equalTo: photoControls.topAnchor,
                constant: -Self.junctionButtonSpacing
            )
        }
        if let trailDraftControls = coordinator.trailDraftControls {
            coordinator.junctionButton.onTrailDraftControls = parts.glass.bottomAnchor.constraint(
                equalTo: trailDraftControls.topAnchor,
                constant: -Self.junctionButtonSpacing
            )
        }
        coordinator.applyJunctionButtonPlacement()
    }
}
#endif
