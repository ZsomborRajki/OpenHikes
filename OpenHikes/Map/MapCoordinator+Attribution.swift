//
//  MapCoordinator+Attribution.swift
//  OpenHikes
//
//  The one thing about the credit line's placement that Auto Layout cannot do
//  on its own: closing the gap it leaves behind when there is nothing to
//  credit.
//
//  Everything else up there is a constraint. The line's bottom is the sheet's
//  to drive — `applySheetTop(on:)` next door writes it, once, for the whole
//  leading-edge stack — and the camera pill hangs a fixed gap above the line,
//  so a credit that wraps onto a second row or grows with the reader's text
//  size moves the pill without anybody being told. See
//  ``MapView/addPhotoControls(to:_:alignedTo:)``.
//
//  What breaks that is `isHidden`. A hidden view still takes part in layout,
//  and the system base map hides this one — MapKit draws its own **Legal**
//  link, so the app must not draw a second credit beside it. Left alone, the
//  pill would then float a credit line's height above the sheet with nothing
//  drawn in between. So the pill has two constraints, one for each case, and
//  this is where exactly one of them is on.
//
//  Two pills share that slot — the camera's and the maker's, which are offered
//  on opposite signals and so can never both draw — and each carries its own
//  pair, because a constraint belongs to one view. Both pairs are switched
//  here, together, off the same question.
//

import MapKit
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
/// One pill's ways of standing at the foot of the leading column: a fixed gap
/// above the credit line, flush with where the line's bottom would be when
/// there is no line drawn, and — while the activity capsule is up — a fixed
/// gap above the capsule, which takes the foot of the column then. See
/// `MapCoordinator+ActivityCapsule.swift`.
///
/// A constraint belongs to one view, so each pill in the slot carries a set of
/// its own, built against the same anchors by
/// ``MapView/placeInCreditLineSlot(_:on:_:alignedTo:)``. The capsule's own has
/// no third, because it is what the third stands on.
struct CreditLineClearance {
    let above: NSLayoutConstraint
    let flush: NSLayoutConstraint
    var onCapsule: NSLayoutConstraint?

    /// Turns on whichever of the three `wantsFlush` and `standsOnCapsule`
    /// call for, and does nothing when it is already the one that is on.
    func apply(flush wantsFlush: Bool, onCapsule standsOnCapsule: Bool = false) {
        let wanted = if standsOnCapsule, let onCapsule { onCapsule } else { wantsFlush ? flush : above }
        guard !wanted.isActive else { return }
        deactivate()
        NSLayoutConstraint.activate([wanted])
    }

    /// Turns all of them off, for a view standing on something else.
    func deactivate() {
        NSLayoutConstraint.deactivate([above, flush] + [onCapsule].compactMap(\.self))
    }
}

extension MapView {
    /// Puts a glyph pill in the slot on the map's leading edge directly above
    /// the credit line, withdrawn until its first visibility pass says
    /// otherwise, and hands back the pair that picks between the line's two
    /// cases — `nil` before there is a credit line to hang it from.
    ///
    /// Both pills in that slot — the camera's, see
    /// ``addPhotoControls(to:_:alignedTo:)``, and the maker's, see
    /// ``addTrailDraftControls(to:_:alignedTo:)`` — are placed here, because
    /// they take turns in one place and ride the sheet as one row. Two
    /// spellings of that geometry is two pills that drift a point apart as
    /// they change hands.
    func placeInCreditLineSlot(
        _ pill: UIView,
        on mapView: MKMapView,
        _ coordinator: Coordinator,
        alignedTo guide: UILayoutGuide
    ) -> CreditLineClearance? {
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.isHidden = true
        pill.alpha = 0
        mapView.addSubview(pill)

        guard let attribution = coordinator.attributionView else { return nil }
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(
                equalTo: guide.leadingAnchor,
                constant: Self.controlInset
            ),
        ])
        return CreditLineClearance(
            above: pill.bottomAnchor.constraint(
                equalTo: attribution.topAnchor,
                constant: -Self.creditLineSpacing
            ),
            flush: pill.bottomAnchor.constraint(equalTo: attribution.bottomAnchor),
            // Placed before the pills, so each of them can name it.
            onCapsule: coordinator.activityCapsule.host.map { capsule in
                pill.bottomAnchor.constraint(
                    equalTo: capsule.topAnchor,
                    constant: -Self.creditLineSpacing
                )
            }
        )
    }
}

extension MapView.Coordinator {
    /// Leaves room above the credit line for the pills in its slot, or closes
    /// that room when there is no line to leave it for.
    ///
    /// Idempotent, and deliberately so: this runs from the tile-source pass,
    /// which is reached on every provider change, and `NSLayoutConstraint`
    /// activation invalidates the map's layout whether or not anything moved.
    /// The map is the one view here that cannot afford a free layout pass.
    ///
    /// An absent pair is the ordinary case during `makeMapView`, where the
    /// pills are built one after the other and each calls this as soon as it
    /// has its own.
    func applyCreditLineClearance() {
        guard let attributionView else { return }
        let wantsFlush = attributionView.isHidden
        // The capsule takes the line's place at the foot of the column while
        // it is up, and the pills stand on it.
        activityCapsule.clearance?.apply(flush: wantsFlush)
        let onCapsule = activityCapsule.isUp
        photoControlsClearance?.apply(flush: wantsFlush, onCapsule: onCapsule)
        trailDraftClearance?.apply(flush: wantsFlush, onCapsule: onCapsule)
        // The junction warnings button stands on the line when neither pill
        // is up, so it takes the same answer.
        applyJunctionButtonPlacement()
    }
}
#endif
