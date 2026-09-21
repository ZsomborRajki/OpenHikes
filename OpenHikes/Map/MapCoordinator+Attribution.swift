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
extension MapView.Coordinator {
    /// Leaves room above the credit line for the camera pill, or closes that
    /// room when there is no line to leave it for.
    ///
    /// Idempotent, and deliberately so: this runs from the tile-source pass,
    /// which is reached on every provider change, and `NSLayoutConstraint`
    /// activation invalidates the map's layout whether or not anything moved.
    /// The map is the one view here that cannot afford a free layout pass.
    func applyCreditLineClearance() {
        guard let attributionView else { return }
        let wantsFlush = attributionView.isHidden
        apply(
            flush: wantsFlush,
            above: photoControlsAboveCreditLine,
            flushWith: photoControlsWithoutCreditLine
        )
        apply(
            flush: wantsFlush,
            above: trailDraftAboveCreditLine,
            flushWith: trailDraftWithoutCreditLine
        )
    }

    /// Switches one pill's pair. Absent constraints are the ordinary case
    /// during `makeMapView`, where the pills are built one after the other and
    /// each calls this as soon as it has its own.
    private func apply(
        flush wantsFlush: Bool,
        above: NSLayoutConstraint?,
        flushWith flush: NSLayoutConstraint?
    ) {
        guard let above, let flush else { return }
        let wanted = wantsFlush ? flush : above
        guard !wanted.isActive else { return }
        NSLayoutConstraint.deactivate([above, flush])
        NSLayoutConstraint.activate([wanted])
    }
}
#endif
