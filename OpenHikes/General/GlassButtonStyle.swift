//
//  GlassButtonStyle.swift
//  OpenHikes
//
//  `.glass` and `.glassProminent` are the Liquid Glass counterparts of
//  `.bordered` and `.borderedProminent`, and are what a standard control in
//  this app should be drawn as.
//
//  Both are `@available(visionOS, unavailable)` — glass there is the window's
//  own material, not a control's — so they are wrapped the same way
//  ``glassSurface(_:in:)`` wraps `glassEffect`: the guard costs nothing
//  and keeps the visionOS path a build away rather than a rewrite away. Both
//  are iOS 26's too, and below 26 they are the bordered styles they replaced,
//  which is the visionOS answer again.
//
//  For a glass *surface* rather than a glass control — a badge, a floating
//  callout, a tile — see `LiquidGlass.swift`.
//

import SwiftUI

extension View {
    /// Standard glass control — the Liquid Glass form of `.bordered`.
    func glassButtonStyle() -> some View {
        #if os(visionOS)
        return buttonStyle(.bordered)
        #else
        if #available(iOS 26.0, *) {
            return buttonStyle(.glass)
        } else {
            return buttonStyle(.bordered)
        }
        #endif
    }

    /// The call to action in its context — the Liquid Glass form of
    /// `.borderedProminent`. Honours an enclosing `.tint()` exactly as the
    /// bordered style did.
    func prominentGlassButtonStyle() -> some View {
        #if os(visionOS)
        return buttonStyle(.borderedProminent)
        #else
        if #available(iOS 26.0, *) {
            return buttonStyle(.glassProminent)
        } else {
            return buttonStyle(.borderedProminent)
        }
        #endif
    }

    /// A section's own "go and find more" action — *Find Photos of This Hike*,
    /// *Places Around Trail* — drawn once so the two cannot drift apart.
    ///
    /// A capsule rather than a borderless row, because the rows above it in a
    /// section open something and this starts something; not full width and
    /// not prominent, because in Apple Maps those belong to the card's main
    /// actions, not to one section's.
    func sectionActionButtonStyle() -> some View {
        font(.subheadline).glassButtonStyle()
    }
}
