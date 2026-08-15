//
//  TapTarget.swift
//  OpenHikes
//
//  A glyph-only button is drawn at the size of its symbol, which is smaller
//  than a finger. Apple's Human Interface Guidelines put the floor at 44pt,
//  and `performAccessibilityAudit`'s hit-region check enforces it — the same
//  measurement Switch Control and Voice Control navigate by.
//
//  This widens the *target* without widening the glyph, so a control keeps the
//  size it was designed at and still answers to a touch that lands near it.
//

import SwiftUI

extension View {
    /// Expands a control to the smallest size a finger can reliably hit,
    /// leaving whatever it draws centred and unchanged.
    func minimumTapTarget(
        _ size: CGFloat = AccessibilityMetrics.minimumTapTarget
    ) -> some View {
        frame(minWidth: size, minHeight: size)
            .contentShape(.rect)
    }
}

nonisolated enum AccessibilityMetrics {
    /// Human Interface Guidelines, "Buttons": the minimum tappable area.
    static let minimumTapTarget: CGFloat = 44
}
