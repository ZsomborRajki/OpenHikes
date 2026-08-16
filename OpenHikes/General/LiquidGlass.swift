//
//  LiquidGlass.swift
//  OpenHikes
//
//  The app's one description of a glass surface, and the container that makes
//  a group of them render — and blend — as one.
//
//  SwiftUI's own `Glass` is `@available(visionOS, unavailable)`: glass there is
//  the window's material rather than a view's, so naming `Glass` in a signature
//  would turn every call site into a visionOS build error. ``GlassSurface``
//  stands in for it and is resolved to a real `Glass` only inside the platform
//  branch that has one — the same "a build away, not a rewrite away" guard
//  ``glassButtonStyle()`` already uses.
//
//  Where glass goes, and where it doesn't: Liquid Glass is the *controls*
//  layer. Buttons, badges, floating callouts and anything that hovers over the
//  map or a chart belong on it. The content those controls act on — stat
//  tiles, list rows, the surface/difficulty bars — stays on the ordinary
//  material below, because glass drawn on glass reads as neither.
//

import SwiftUI

/// How a piece of glass should be drawn, described without naming `Glass`.
struct GlassSurface: Equatable {
    /// The default surface: adapts to whatever is behind it and stays legible
    /// over map imagery, a chart, or a plain background.
    static let regular = Self()

    /// Thinner and more transparent — for chrome laid over something the user
    /// is meant to keep seeing through it, such as the sheet over the map.
    static let clear = Self(isClear: true)

    private var isClear = false
    private var tintColor: Color?
    private var isInteractive = false

    /// Colours the glass without making it opaque. Use it to carry a meaning
    /// the shape already has — a recording's red, a warning's orange — not for
    /// decoration.
    func tint(_ color: Color?) -> Self {
        var copy = self
        copy.tintColor = color
        return copy
    }

    /// Adds the press response: the scale, bounce and highlight a Liquid Glass
    /// control answers a touch with. Only for something actually tappable —
    /// on a static badge it promises an interaction that isn't there.
    func interactive(_ isEnabled: Bool = true) -> Self {
        var copy = self
        copy.isInteractive = isEnabled
        return copy
    }

    #if !os(visionOS)
    /// The SwiftUI value this stands for. Only reachable where `Glass` exists.
    var resolved: Glass {
        var glass: Glass = isClear ? .clear : .regular
        if let tintColor {
            glass = glass.tint(tintColor)
        }
        if isInteractive {
            glass = glass.interactive()
        }
        return glass
    }
    #endif
}

/// Groups the glass shapes inside it so they are rendered in one pass and
/// blend into each other as they come close, instead of each paying for its
/// own backdrop sample.
///
/// This is the performance half of Liquid Glass as much as the visual one: a
/// row of separate `glassEffect` views each samples what is behind it, while a
/// container samples once for the group. Anywhere this app puts more than one
/// glass shape side by side, they go in one of these.
struct GlassStack<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    /// - Parameter spacing: How close two glass shapes must be before they
    ///   merge. `nil` keeps the system's own distance.
    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        #if os(visionOS)
        content
        #else
        GlassEffectContainer(spacing: spacing) { content }
        #endif
    }
}

extension View {
    /// Draws `shape` behind this view as Liquid Glass.
    ///
    /// The visionOS branch falls back to `.regularMaterial`, which is what a
    /// view-level background is there.
    @ViewBuilder
    func glassSurface(
        _ surface: GlassSurface,
        in shape: some Shape
    ) -> some View {
        #if os(visionOS)
        background(.regularMaterial, in: shape)
        #else
        glassEffect(surface.resolved, in: shape)
        #endif
    }

    /// Lets a scroll view's content fade into a progressive blur under the bar
    /// above it, instead of meeting it at a hard line — the backdrop a glass
    /// navigation bar is drawn to sit on.
    ///
    /// Wrapped for the same reason the rest of this file is: the modifier is
    /// `@available(visionOS, unavailable)`.
    @ViewBuilder
    func softScrollEdgeEffect(for edges: Edge.Set) -> some View {
        #if os(visionOS)
        self
        #else
        scrollEdgeEffectStyle(.soft, for: edges)
        #endif
    }
}
