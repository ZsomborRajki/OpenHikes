//
//  MapTrailDraftControls.swift
//  OpenHikes
//
//  The *make a trail* button, on the map's leading edge.
//
//  It sits in the slot ``MapPhotoControlsView`` occupies, and that is a
//  decision rather than a coincidence of layout. The camera pill is offered
//  only while a screen is pushed that has attached a hike to photograph, so on
//  the search screen — the one a hiker is looking at when they decide where to
//  walk on Saturday — that corner of the map is empty and has been since it
//  was built. `MapView.addPhotoControls` says so in its own comment. This is
//  what goes there.
//
//  UIKit for the reason the camera pill is, and it is the same reason twice
//  over: it has to sit at exactly the height the tracking button sits at,
//  follow the sheet through ``MapView/Coordinator/applySheetTop(on:)`` without
//  a SwiftUI pass in between, and fade exactly where the rest of that row
//  fades. It shares ``MapPhotoControlsView/controlSize``, the glass capsule
//  and ``MapView/Coordinator/applyCreditLineClearance()``.
//
//  One button rather than two, so there is no container effect here: a
//  `UIGlassContainerEffect` exists to merge neighbouring shapes, and a lone
//  capsule has nothing to merge with.
//

import Foundation
import MapKit

#if os(iOS)
import UIKit

/// The pill itself. Owns its appearance and its one action; where it sits is
/// decided by ``MapView/Coordinator/applySheetTop(on:)``, which positions the
/// whole leading-edge column together.
final class MapTrailDraftControlsView: UIView {
    /// The glyph a route is drawn with everywhere this app has one to draw:
    /// two points and the line between them.
    static let symbolName = "point.topleft.down.to.point.bottomright.curvepath"
    private static let symbolPointSize: CGFloat = 17

    private let onDraw: () -> Void

    init(onDraw: @escaping () -> Void) {
        self.onDraw = onDraw
        super.init(frame: .zero)
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MapTrailDraftControlsView is created in code only")
    }

    /// One glass capsule with a glyph-only button inside it, sized to
    /// ``AccessibilityMetrics/minimumTapTarget`` rather than to its symbol and
    /// carrying a spoken name of its own — a glyph is not a label, and
    /// `performAccessibilityAudit` measures both.
    private func buildHierarchy() {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: Self.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: Self.symbolPointSize,
                weight: .medium
            )
        )
        let button = UIButton(
            configuration: configuration,
            primaryAction: UIAction { [onDraw] _ in onDraw() }
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = String(localized: "Make a trail")
        button.accessibilityIdentifier = "map-trail-maker-button"

        let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerConfiguration = .capsule()
        glass.contentView.addSubview(button)
        addSubview(glass)

        let size = MapPhotoControlsView.controlSize
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.widthAnchor.constraint(equalToConstant: size),
            glass.heightAnchor.constraint(equalToConstant: size),
            button.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])
    }
}
#endif

#if os(iOS)
/// Where the pill is put on the map.
///
/// Here rather than in `MapView.swift` for the reason
/// ``MapView/addAreaSearchControl(to:_:alignedTo:)`` is in the community
/// folder: a feature owns the piece of the map it draws, and the file that
/// builds every control on this map is at its length limit.
extension MapView {
    /// The *make a trail* pill, in the same place the camera pill sits.
    ///
    /// Not merely nearby: it hangs off the same two constraints against the
    /// credit line that ``addPhotoControls(to:_:alignedTo:)`` builds, so the
    /// two occupy one slot and ride the sheet as one row. They can never both
    /// be visible — see ``TrailDraftController`` for why that falls out of the
    /// two availability rules rather than out of anything here — which is what
    /// makes sharing the slot safe rather than merely tidy.
    ///
    /// Sharing the *constraints* is not possible, because a constraint belongs
    /// to one view, so the pair is built again here against the same anchors.
    /// ``MapView/Coordinator/applyCreditLineClearance()`` activates whichever
    /// of each pair the current provider calls for.
    func addTrailDraftControls(
        to mapView: MKMapView,
        _ coordinator: Coordinator,
        alignedTo guide: UILayoutGuide
    ) {
        let controls = MapTrailDraftControlsView(
            onDraw: { [trailMaker] in trailMaker.requestOpen() }
        )
        controls.translatesAutoresizingMaskIntoConstraints = false
        // Starts out of the way, for the reason the camera pill does:
        // `observeTrailDraftControls` decides on its first pass whether there
        // is anything to offer, and a pill that flashed in before it answered
        // would be visible over a screen that is already pushed.
        controls.isHidden = true
        controls.alpha = 0
        mapView.addSubview(controls)
        coordinator.trailDraftControls = controls

        guard let attribution = coordinator.attributionView else { return }
        coordinator.trailDraftAboveCreditLine = controls.bottomAnchor.constraint(
            equalTo: attribution.topAnchor,
            constant: -Self.creditLineSpacing
        )
        coordinator.trailDraftWithoutCreditLine = controls.bottomAnchor.constraint(
            equalTo: attribution.bottomAnchor
        )

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(
                equalTo: guide.leadingAnchor,
                constant: Self.controlInset
            ),
        ])
        coordinator.applyCreditLineClearance()
    }
}
#endif

extension MapView.Coordinator {
    /// The same fade the camera pill arrives and leaves on, because the two
    /// take turns in one slot and a different duration would read as the slot
    /// itself twitching.
    private static let trailDraftControlsFadeDuration: TimeInterval = 0.25

    /// Observes whether a trail can be made right now and shows or hides the
    /// pill, then re-registers — the same imperative arrangement
    /// ``observePhotoControls(_:)`` uses, so navigating between screens never
    /// re-renders the map.
    ///
    /// Idempotent for the reason every registration here is: a second one
    /// would leave two observers running two overlapping fades against the
    /// same view, and `withObservationTracking` offers no way to cancel the
    /// first.
    func observeTrailDraftControls(_ controller: TrailDraftController) {
        guard !isObservingTrailDraftControls else { return }
        isObservingTrailDraftControls = true
        trackTrailDraftControls(controller)
    }

    private func trackTrailDraftControls(_ controller: TrailDraftController) {
        trailDraftController = controller
        applyTrailDraftControlsVisibility(animated: false)
        reobserving(self, controller) {
            _ = controller.isAvailable
        } onChange: { coordinator, model in
            coordinator.applyTrailDraftControlsVisibility(animated: true)
            coordinator.trackTrailDraftControls(model)
        }
    }

    private func applyTrailDraftControlsVisibility(animated: Bool) {
        #if os(iOS)
        guard let trailDraftControls else { return }
        let visible = trailDraftController?.isAvailable == true
        // Hidden as well as transparent, for the reason the camera pill is: a
        // control that is invisible but still in the hierarchy answers hit
        // tests, and this one sits over the map the hiker is panning.
        // Interaction goes at once rather than when the fade lands.
        trailDraftControls.isUserInteractionEnabled = visible
        if visible { trailDraftControls.isHidden = false }
        let target = visible ? photoControlsSheetAlpha : 0
        guard animated else {
            trailDraftControls.alpha = target
            trailDraftControls.isHidden = !visible
            return
        }
        UIView.animate(withDuration: Self.trailDraftControlsFadeDuration) {
            trailDraftControls.alpha = target
        } completion: { [weak self] _ in
            // Re-read rather than trusting the value this animation started
            // with: a push and an immediate pop overlap, and a completion that
            // hid a pill the *next* animation had just brought back would
            // leave a visible control answering no taps.
            guard let self,
                  trailDraftController?.isAvailable != true else { return }
            trailDraftControls.isHidden = true
        }
        #endif
    }

    /// Applies the sheet's own fade, shared with the tracking button and the
    /// credit line.
    ///
    /// Kept apart from the visibility above for the reason
    /// ``applyPhotoControlsAlpha(_:)`` is: the two answer different questions
    /// — "is there a trail to make?" and "has the sheet covered this part of
    /// the map?" — and both have to be true for the pill to be seen. The
    /// sheet's value is the one the camera pill already remembers, since the
    /// two share a slot and therefore share a row.
    func applyTrailDraftControlsAlpha(_ alpha: CGFloat) {
        #if os(iOS)
        guard let trailDraftControls,
              trailDraftController?.isAvailable == true,
              trailDraftControls.alpha != alpha else { return }
        trailDraftControls.alpha = alpha
        #endif
    }
}
