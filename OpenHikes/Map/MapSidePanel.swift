//
//  MapSidePanel.swift
//  OpenHikes
//
//  The wide half of the map's primary surface: the sheet's own contents, drawn
//  down the leading edge with the map beside them instead of underneath.
//
//  `.presentationDetents` are not honoured at a compact height by a sheet left
//  to adapt, as `MapSheet` is; ``SheetLayout`` has the sheets that opt out.
//  iPhone landscape is compact height, so the system ignores them and presents
//  the sheet full-screen — and because `OpenHikesView` keeps that sheet up
//  permanently and puts it back whenever it is dismissed, full-screen there
//  does not mean "a taller sheet" but "no map, and no way back to one". A phone
//  taken out of a pocket at a junction rotates on its own; a hiker who cannot
//  see the map is the whole cost of that.
//
//  So landscape gets a panel rather than a sheet, and so does any window at a
//  regular height with room for a map beside it — an unfolded iPhone Duo, an
//  iPad either way up — where the sheet would be a card in the middle of the
//  bottom edge; ``SheetLayout`` has the rule. It is a plain overlay, not a
//  presentation: nothing about it is modal, the map keeps taking touches
//  beside it, and `MapSheet` is handed to it unchanged — the same view, the
//  same navigation stack, the same screens. What the two shapes disagree
//  about is carried by ``SheetLayout`` and by ``MapSidePanelLayout``, whose
//  numbers the map is told as well so its own controls stay clear of the
//  panel rather than behind it.
//
//  How tall it stands depends on what the window has. A compact height is
//  less than nearly every screen wants, so there the panel is the window's.
//  Where there is height to spare — an iPad, an unfolded iPhone Duo on its
//  side — it stands as tall as the screen on top needs, at the top of the
//  leading edge: a recording's card of figures is a third of an iPad's
//  height, and the rest was a slab of glass over map. ``SidePanelFit`` has
//  the measuring. The map's controls keep the panel's width clear either
//  way, so nothing on the map moves when the panel grows.
//
//  One screen is the exception: a photo viewer. In portrait it raises the sheet
//  to `.large`; here the equivalent is the whole window, so the panel widens to
//  it — edge to edge, past the safe area, the way a photograph is shown — and
//  narrows again when the viewer is popped, or when the hiker's own gallery's
//  *Show on map* brings the map back beside it with the gallery still open —
//  see ``SheetPresentation/isShowingFullHeightScreen``. The same view widening
//  rather than a cover presented over it, so the navigation stack, the back
//  gesture and the page being looked at all carry on through the change.
//

import SwiftUI

/// The panel's fixed geometry.
///
/// A type of its own because ``MapSidePanel`` is generic over its contents, so
/// it can carry no stored static of its own — and because the map has to spend
/// these numbers without naming whatever content type the panel was built with.
enum MapSidePanelLayout {
    /// Wide enough for a hike row's title, distance and badge — a shade under
    /// the 375 pt an iPhone SE gives the same rows in portrait — and narrow
    /// enough to leave the map the larger half on every iPhone this app runs
    /// on. Fixed rather than a fraction of the screen because the map is told
    /// the same number and a fraction would need the container's width in the
    /// root view's body to compute.
    static let width: CGFloat = 320

    /// The gap between the panel and the edges of the screen.
    static let margin: CGFloat = 12

    static let cornerRadius: CGFloat = 24

    /// The least a panel fitted to its screen stands — see ``SidePanelFit``.
    /// As tall as it is wide: room for the search field and a row or two
    /// under it, so a library of one hike is still a panel and not a bar.
    static let minimumHeight: CGFloat = width

    /// The room a fitted panel leaves under a plain list's last row, which
    /// would otherwise end in the panel's rounded corners. The panel's own
    /// margin, so the row stands as far from the glass's edge as the glass
    /// does from the window's.
    static let listClearance: CGFloat = margin

    /// How far the map's own controls have to be pushed off the leading edge
    /// to clear the panel. Handed to ``MapView``, which spends it as
    /// additional safe-area inset, so the credit line and the camera pill sit
    /// beside the panel rather than behind it.
    static var mapInset: CGFloat { width + margin * 2 }
}

struct MapSidePanel<Content: View>: View {
    /// Whether the panel covers the whole window — while a photo viewer is the
    /// screen on top. See ``SheetPresentation/isShowingFullHeightScreen``.
    var fillsWindow = false
    /// How tall the panel stands where the window has height to spare. Read
    /// here and by nothing above, so a screen that grows a row re-runs this
    /// body and not the root view's — see ``SidePanelFit``.
    var fit: SidePanelFit
    @ViewBuilder var content: Content

    var body: some View {
        // Every change below is a value rather than a branch, so widening
        // keeps the content's identity — a branch would rebuild the navigation
        // stack, and the gallery with it, mid-push.
        content
            // Where the screens inside say how tall they are. Only here, so
            // the same screens in a sheet report to nobody.
            .environment(\.sidePanelFit, fit)
            .frame(width: fillsWindow ? nil : MapSidePanelLayout.width)
            // A ceiling rather than a height, so a screen longer than the
            // window is given the window and scrolls. The stack this is
            // inside stands it at the top, and leaves the map what is under it.
            .frame(
                maxWidth: fillsWindow ? .infinity : nil,
                maxHeight: fillsWindow ? .infinity : fit.height ?? .infinity
            )
            // An overlay has no system sheet material of its own. Use
            // adaptive glass here too, bounded by the panel's four edges —
            // or, below iOS 26, the material ``glassSurface(_:in:)`` stands
            // in with.
            .background {
                #if os(visionOS)
                Color.clear
                #else
                Color.clear.glassSurface(
                    .regular,
                    in: .rect(cornerRadius: MapSidePanelLayout.cornerRadius)
                )
                #endif
            }
            .clipShape(
                PanelClip(
                    cornerRadius: fillsWindow ? 0 : MapSidePanelLayout.cornerRadius,
                    outset: fillsWindow ? PanelClip.safeAreaReach : 0
                )
            )
            .padding(fillsWindow ? 0 : MapSidePanelLayout.margin)
            .animation(.snappy, value: fillsWindow)
            .accessibilityIdentifier("map-side-panel")
    }
}

/// The panel's clip: its rounded rectangle, or — filling the window — a rect
/// grown past its own edges.
///
/// The panel is laid out inside the safe area, and a full-screen photograph's
/// black is drawn past it into the Dynamic Island's edge and the home
/// indicator's. A clip at the panel's own bounds would cut that back off and
/// leave a strip of map down both sides of the picture, so the filled clip
/// reaches beyond the bounds rather than being dropped — dropping it would be
/// a branch, and a branch is a new navigation stack.
///
/// `@Animatable` animates every stored property, so the corners and the
/// outset ease together when the panel fills the window or gives it back. A
/// stored property added later animates too, unless it is
/// `@AnimatableIgnored`.
@Animatable
nonisolated private struct PanelClip: Shape {
    /// Further than any iPhone's landscape safe-area inset.
    static let safeAreaReach: CGFloat = 200

    var cornerRadius: CGFloat
    var outset: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(
            roundedRect: rect.insetBy(dx: -outset, dy: -outset),
            cornerRadius: cornerRadius,
            style: .continuous
        )
    }
}
