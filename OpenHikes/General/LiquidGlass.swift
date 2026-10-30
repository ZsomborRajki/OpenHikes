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
//  The same stand-in is what lets the app run below iOS 26, where there is no
//  `Glass` either. There the surface falls back to what iOS 18 itself draws
//  under a floating control — the regular material, with a tint carried as a
//  wash over it — and the container, the spacer and the scroll edge fall
//  back to nothing, because each only refines how glass is drawn. Every one of
//  those fallbacks is a branch in this file, so a screen never asks. Each
//  branch is a `return` rather than a view builder's `if`, so each release
//  gets its own concrete type: a builder would wrap the newer branch in an
//  `AnyView`, on views the map redraws.
//
//  Where glass goes, and where it doesn't: Liquid Glass is the *controls*
//  layer. Buttons, badges, floating callouts and anything that hovers over the
//  map or a chart belong on it. The content those controls act on — stat
//  tiles, list rows, the surface/difficulty bars — stays on the ordinary
//  material below, because glass drawn on glass reads as neither.
//
//  ``Color/contentSurface`` is that material, and it is here rather than
//  beside a view because the rule above is what decides who uses it.
//

import SwiftUI

extension Color {
    /// What content sits on inside a glass sheet.
    ///
    /// Fine chart details, selection tints and breakdown bars need a stable
    /// backing regardless of the map underneath the sheet's adaptive glass.
    /// Opaque rather than a `Material`: another material would sample the
    /// same backdrop these details need separation from. This belongs only
    /// behind those content elements, never across the whole sheet.
    static let contentSurface: Color = {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }()
}

extension ShapeStyle where Self == Color {
    /// ``Color/contentSurface`` as a leading-dot shorthand, so `background(_:in:)`
    /// takes it the way it takes `.regularMaterial` — the shorthand resolves
    /// against `ShapeStyle` rather than `Color`, which a static on `Color`
    /// alone does not satisfy.
    static var contentSurface: Color { Color.contentSurface }
}

/// How a piece of glass should be drawn, described without naming `Glass`.
struct GlassSurface: Equatable {
    /// The default surface: adapts to whatever is behind it and stays legible
    /// over map imagery, a chart, or a plain background.
    static let regular = Self()

    /// The see-through surface, for a small control over map imagery where
    /// what is under it matters as much as what is on it. It frosts far less
    /// than ``regular``, so its contents need to be bold enough to read over
    /// whatever the map draws there.
    static let clear = Self(isClear: true)

    private let isClear: Bool
    private var tintColor: Color?
    private var isInteractive = false

    /// ``regular`` and ``clear`` are the two starting points; everything else
    /// is a modifier on one of them.
    private init(isClear: Bool = false) {
        self.isClear = isClear
    }

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
    @available(iOS 26.0, *) var resolved: Glass {
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

    /// What stands in for the glass where there is none: the regular
    /// material, or the ultra-thin one for ``clear``, and the tint washed over
    /// it, so a recording's red and a warning's orange still say what they say.
    func earlierBackground(in shape: some Shape) -> some View {
        ZStack {
            shape.fill(isClear ? .ultraThinMaterial : .regularMaterial)
            if let tintColor {
                shape.fill(tintColor.opacity(Self.earlierTintOpacity))
            }
        }
    }

    /// How strongly a tint shows through the material below iOS 26 — enough
    /// to read as the colour, not so much that the text on it loses contrast.
    private static let earlierTintOpacity = 0.3
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
        return content
        #else
        if #available(iOS 26.0, *) {
            return GlassEffectContainer(spacing: spacing) { content }
        } else {
            return content
        }
        #endif
    }
}

/// A break between two groups of toolbar items, so they are drawn as separate
/// pieces of glass instead of merging into one capsule.
///
/// Items sharing a placement are one glass group by default, which is right
/// for a set of related actions and wrong for a pair that are not: a
/// destructive button in the same capsule as a navigation one reads as another
/// facet of it, and the two are a fingertip apart with nothing between them.
///
/// Wrapped for the reason the rest of this file is — `ToolbarSpacer` is
/// `@available(visionOS, unavailable)`, where a toolbar is not a row of glass
/// capsules to be split in the first place. The visionOS branch is an empty
/// item rather than nothing at all, because a `body` has to produce some
/// `ToolbarContent` in either branch — there is no empty one to return.
///
/// Fixed rather than flexible: this separates two neighbours, it does not push
/// them to opposite ends of the bar.
struct GlassToolbarSpacer: ToolbarContent {
    /// The placement of the items being separated. A spacer only breaks up the
    /// group it is in, so this has to be the same placement they carry.
    let placement: ToolbarItemPlacement

    var body: some ToolbarContent {
        #if os(visionOS)
        return ToolbarItem(placement: placement) { EmptyView() }
        #else
        if #available(iOS 26.0, *) {
            return ToolbarSpacer(.fixed, placement: placement)
        } else {
            // No glass to split below 26, so the visionOS answer again.
            return ToolbarItem(placement: placement) { EmptyView() }
        }
        #endif
    }
}

extension View {
    /// Draws `shape` behind this view as Liquid Glass.
    ///
    /// The visionOS branch falls back to `.regularMaterial`, which is what a
    /// view-level background is there, and so does iOS below 26, with the
    /// surface's tint washed over it.
    func glassSurface(
        _ surface: GlassSurface,
        in shape: some Shape
    ) -> some View {
        #if os(visionOS)
        return background(.regularMaterial, in: shape)
        #else
        if #available(iOS 26.0, *) {
            return glassEffect(surface.resolved, in: shape)
        } else {
            return background { surface.earlierBackground(in: shape) }
        }
        #endif
    }

    /// Pins `content` to `edge` as chrome over a scrolling screen.
    ///
    /// `safeAreaBar` on iOS 26 and later, which gives the bar the system's
    /// glass and the scroll-edge behaviour that goes with it. Below 26 it is
    /// the `safeAreaInset` that came before, painting the `.bar` material it
    /// used to paint on itself.
    func glassBar(
        _ edge: VerticalEdge,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if #available(iOS 26.0, *) {
            return safeAreaBar(edge: edge, content: content)
        } else {
            return safeAreaInset(edge: edge) { content().background(.bar) }
        }
    }

    /// Lets a scroll view's content fade into a progressive blur under the bar
    /// above it, instead of meeting it at a hard line — the backdrop a glass
    /// navigation bar is drawn to sit on.
    ///
    /// Wrapped for the same reason the rest of this file is: the modifier is
    /// `@available(visionOS, unavailable)`, and iOS 26's. Below 26 the bar is
    /// not glass and content meets it the way it always has.
    func softScrollEdgeEffect(for edges: Edge.Set) -> some View {
        #if os(visionOS)
        return self
        #else
        if #available(iOS 26.0, *) {
            return scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            return self
        }
        #endif
    }
}
