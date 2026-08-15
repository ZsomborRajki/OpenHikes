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
//  and keeps the visionOS path a build away rather than a rewrite away.
//
//  For a glass *surface* rather than a glass control — a badge, a floating
//  callout, a tile — see ``LiquidGlass.swift``.
//

import SwiftUI

extension View {
    /// Standard glass control — the Liquid Glass form of `.bordered`.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        #if os(visionOS)
        buttonStyle(.bordered)
        #else
        buttonStyle(.glass)
        #endif
    }

    /// The call to action in its context — the Liquid Glass form of
    /// `.borderedProminent`. Honours an enclosing `.tint()` exactly as the
    /// bordered style did.
    @ViewBuilder
    func prominentGlassButtonStyle() -> some View {
        #if os(visionOS)
        buttonStyle(.borderedProminent)
        #else
        buttonStyle(.glassProminent)
        #endif
    }
}
