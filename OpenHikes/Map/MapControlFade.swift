//
//  MapControlFade.swift
//  OpenHikes
//
//  How a control floating over the map arrives and leaves.
//
//  Four of them do — the camera pill, the trail maker's pill, and the two
//  *Search this area* pills — and each wrote the same fade out in full: hidden
//  as well as transparent, interaction withdrawn at once, and a completion that
//  re-reads the model before hiding. Each copy carried the same three comments
//  saying why, and the same quarter-second. What differs between them is only
//  what "visible" means and which opacity the control rests at, so that is all
//  a caller says now.
//

#if os(iOS)
import UIKit

extension UIView {
    /// How long a map control takes to arrive or leave. Short enough to feel
    /// like part of the push or the settle that caused it, long enough not to
    /// be a blink — and one figure for all of them, because two controls that
    /// take turns in one slot at different speeds read as the slot twitching.
    static let mapControlFadeDuration: TimeInterval = 0.25

    /// Shows or withdraws a control floating over the map.
    ///
    /// **Hidden as well as transparent.** A control that is invisible but
    /// still in the hierarchy answers hit tests, and every one of these sits
    /// over a map the hiker is panning or drawing on. Interaction goes at once
    /// rather than when the fade lands, for the same reason: a control on its
    /// way out is otherwise still a tap target for the whole of the fade.
    ///
    /// - Parameters:
    ///   - visible: Whether the control should be there.
    ///   - alpha: The opacity it rests at when it is — `1`, or the sheet's own
    ///     fade for the controls that ride the sheet's edge.
    ///   - animated: `false` for a first pass arranging a control nobody has
    ///     seen yet.
    ///   - isStillWithdrawn: Asked when a fade-out lands, and the control is
    ///     hidden only if it answers `true`. Re-read rather than trusting the
    ///     value the animation started with: two fades overlap when a push and
    ///     a pop do, and a completion that hid the control the *next* fade had
    ///     just brought back would leave a visible control answering no taps.
    func fadeMapControl(
        visible: Bool,
        restingAlpha alpha: CGFloat,
        animated: Bool,
        isStillWithdrawn: @escaping @MainActor () -> Bool
    ) {
        isUserInteractionEnabled = visible
        if visible { isHidden = false }
        let target = visible ? alpha : 0
        guard animated else {
            self.alpha = target
            isHidden = !visible
            return
        }
        Self.animate(withDuration: Self.mapControlFadeDuration) {
            self.alpha = target
        } completion: { _ in
            if isStillWithdrawn() { self.isHidden = true }
        }
    }
}
#endif
