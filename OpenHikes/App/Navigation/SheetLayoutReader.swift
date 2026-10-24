//
//  SheetLayoutReader.swift
//  OpenHikes
//
//  Where the window's shape is read — the vertical size class and the size of
//  the space the map screen is laid out in — and the reason it is not read in
//  `OpenHikesView`.
//
//  The app needs one bit from them: whether the sheet's contents belong in
//  ``MapSidePanel`` rather than in the sheet. Reading either in the root
//  view's body is the obvious way and it costs more than it looks: an
//  `@Environment` read makes that body re-run whenever SwiftUI thinks the
//  value *may* have moved, and the scene transitions a backgrounded recording
//  goes through are one of those times. Measured, with the read in
//  `OpenHikesView`: one extra root body pass per scene transition — which the
//  since-retired performance suite's background recording test failed on by
//  exactly that one — plus the map update pass and the tile requests that
//  follow it: 250-odd of them in an offline browse that is budgeted for none.
//  The whole of it went away when the read moved here.
//
//  A `View` of its own because that is the only render boundary SwiftUI has: a
//  helper `func`, a computed `var` and an `.overlay` closure are all inlined
//  into the body that declares them, so none of them would have moved
//  anything. See *Render isolation, in practice* in the repository
//  instructions.
//
//  What leaves here is the coarse flag rather than the inputs:
//  ``SheetPresentation/layout`` changes when the window changes shape — a
//  rotation, or an iPhone Duo opening or closing — and at no other time, so
//  the root view re-renders for those and for nothing else.
//

import SwiftUI

extension SheetLayout {
    /// The narrowest window, at a regular height, that the panel is used in:
    /// one that leaves the map at least as wide as the panel beside it.
    ///
    /// Below it a wide window keeps the sheet, which at least spends its
    /// width on the map. A compact height takes the panel whatever the width
    /// — see ``init(windowSize:isCompactHeight:)`` for why that is not a
    /// choice.
    static let minimumPanelWindowWidth = MapSidePanelLayout.mapInset * 2

    /// The shape the map screen takes in a window of `size` — the space it is
    /// laid out in, inside the safe area.
    ///
    /// **A compact height always gets the panel**, because there the system
    /// ignores the sheet's detents and presents it over the whole map — see
    /// ``SheetLayout``. iPhone landscape is that case, and so is a closed iPhone
    /// Duo turned on its side.
    ///
    /// **A window wider than tall gets it too, by choice**, once there is room
    /// for a map beside it. An unfolded iPhone Duo is the case that asked: its
    /// inner display is 951 × 669 points in landscape and of regular height, so
    /// the sheet stayed a sheet — a card in the middle of the bottom edge, with
    /// map on both sides of it and the map's own controls riding a top edge
    /// that nothing under them shared. Wide is the panel's shape, and taller
    /// than wide is the sheet's, so the rule is the window's and not the
    /// device's: an iPad, a Duo turned upright and a phone all answer it the
    /// same way.
    init(windowSize size: CGSize, isCompactHeight: Bool) {
        let isWide = size.width > size.height && size.width >= Self.minimumPanelWindowWidth
        self = isCompactHeight || isWide ? .sidePanel : .bottomSheet
    }
}

struct SheetLayoutReader: View {
    var presentation: SheetPresentation
    /// Withdrawn along with the sheet: in a side panel nothing reports a top
    /// edge, and the last reading of the sheet still lands on a map beside a
    /// panel.
    var metrics: SheetMetrics

    #if os(macOS)
    /// No compact height to answer to on a platform this app does not build
    /// for yet — see the `canImport` note in the repository instructions. A
    /// wide window still takes the panel.
    private var isCompactHeight: Bool { false }
    #else
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isCompactHeight: Bool { verticalSizeClass == .compact }
    #endif

    var body: some View {
        // The size of the root view's own space, which a background is laid
        // out in; read through a geometry reader rather than a change handler
        // so the first answer is already the window's own.
        //
        // Not shortened by the keyboard. On a large screen held upright — an
        // open iPhone Duo, an iPad — the space above a keyboard is wider than
        // tall, and the sheet must not turn into the panel because someone
        // started typing in it.
        GeometryReader { proxy in
            // Draws nothing and is never announced: this view exists for the
            // window it sits in, not for anything on screen.
            Color.clear
                .accessibilityHidden(true)
                // `initial`, because a launch straight into a wide window is
                // a change nothing here ever sees.
                .onChange(
                    of: SheetLayout(windowSize: proxy.size, isCompactHeight: isCompactHeight),
                    initial: true
                ) { _, layout in
                    presentation.layout = layout
                    if layout == .sidePanel { metrics.withdraw() }
                }
        }
        .ignoresSafeArea(.keyboard)
    }
}
