//
//  SidePanelFitReport.swift
//  OpenHikes
//
//  Where the sheet's screens say how tall they would like the side panel to
//  be — see ``SidePanelFit`` for what is done with it, and for why each
//  figure measured here is one that does not move when the panel does.
//
//  Two modifiers, because there are two things only the screen can know.
//  ``SwiftUICore/View/sidePanelScreen(depth:)`` goes on every screen in the
//  sheet's stack, from ``MapSheet``, and a screen never sees it.
//  ``SwiftUICore/View/fitsSidePanel()`` goes on the scroll view a screen is
//  built around, which only the screen can point at: a screen is often more
//  than one scroll view — a strip of photographs across a hike — and the
//  first one SwiftUI finds is not always the one that scrolls the screen.
//
//  Both say nothing outside a panel. The model reaches them through the
//  environment, and only ``MapSidePanel`` puts it there, so the same screens
//  in a phone's sheet measure and report to nobody.
//

import SwiftUI

// `nonisolated` for the reason `sheetDepth`'s extension is — see
// `ScreenClaims.swift`.
nonisolated extension EnvironmentValues {
    /// The panel the screens report to, or `nil` where they are in a sheet.
    @Entry var sidePanelFit: SidePanelFit?

    /// How deep in the sheet's stack a screen is, for the panel's fit: 0 for
    /// the root, and `nil` for a screen no longer on the stack.
    ///
    /// Not ``sheetDepth``, which counts a screen being popped as the first:
    /// a pop builds the screen it is taking away once more, with its route
    /// already gone from the path, and a screen that reported from there
    /// would speak for the screen the hiker is going back to.
    @Entry var sidePanelDepth: Int?
}

extension View {
    /// Marks one screen of the sheet's stack: names the space its scroll view
    /// measures itself in, says how deep it is, and reports the bars the
    /// stack draws around it.
    ///
    /// - Parameter depth: 0 for the root, 1 for the first screen pushed, and
    ///   `nil` for a screen whose route has left the path.
    func sidePanelScreen(depth: Int?) -> some View {
        modifier(SidePanelScreen(depth: depth))
    }

    /// Marks the scroll view a screen is built around, so the side panel can
    /// stand as tall as what it scrolls and no taller.
    ///
    /// On the `ScrollView`, `List` or `Form` itself. What is measured is what
    /// it scrolls and what the screen draws above and below it, so a bar the
    /// scroll view is given as a safe-area inset is not counted: such a bar
    /// goes in the screen's own layout, as *Render isolation, in practice*
    /// already asks of one.
    ///
    /// A screen without one keeps the height the panel had when it was pushed.
    ///
    /// - Parameter clearance: Room to leave under the last thing scrolled. A
    ///   plain list's last row ends where the list does, which in a fitted
    ///   panel is the panel's own rounded corners; a scroll view whose
    ///   content is padded has left its own.
    func fitsSidePanel(clearance: CGFloat = 0) -> some View {
        modifier(SidePanelFitReport(clearance: clearance))
    }
}

private struct SidePanelScreen: ViewModifier {
    let depth: Int?

    @Environment(\.sidePanelFit) private var fit

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(SidePanelFit.screenSpace))
            .environment(\.sidePanelDepth, depth)
            // The screen is laid out inside the stack's bars, so its safe
            // area is their height.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            } action: { bars in
                guard let depth else { return }
                fit?.report(bars: bars, atDepth: depth)
            }
    }
}

private struct SidePanelFitReport: ViewModifier {
    /// The two halves of what the scroll view asks for, which arrive apart.
    ///
    /// A reference, so that keeping one half until the other comes writes no
    /// state and re-runs nothing.
    private final class Reading {
        var screen: Int?
        /// What the screen draws beside the scroll view.
        var beside: CGFloat?
        /// What the scroll view scrolls.
        var scrolled: CGFloat?
    }

    let clearance: CGFloat

    @Environment(\.sidePanelFit) private var fit
    @Environment(\.sidePanelDepth) private var depth
    @State private var reading = Reading()

    func body(content: Content) -> some View {
        content
            // What it scrolls, and not the insets around it: the bars it
            // scrolls under are the screen's to count, and counted here as
            // well they would arrive a callback apart from the screen's own
            // word for them, the panel a bar too tall in between.
            //
            // `nil` until the scroll view has a height of its own. A list is
            // asked before it has been laid out, and says it holds nothing:
            // taken at its word, every push closed the panel down to its
            // minimum on the way to the height the list then asked for.
            .onScrollGeometryChange(for: CGFloat?.self) { geometry in
                geometry.containerSize.height > 0 ? geometry.contentSize.height : nil
            } action: { _, scrolled in
                reading.scrolled = scrolled
                report()
            }
            // The rest of the screen: its height less the scroll view's, in
            // one reading, so the two cannot disagree while the panel moves.
            // `nil` where no screen is named — a sheet presented over the
            // panel inherits its environment, and must not speak for the
            // screen underneath.
            .onGeometryChange(for: CGFloat?.self) { proxy in
                proxy.bounds(of: .named(SidePanelFit.screenSpace)).map { $0.height - proxy.size.height }
            } action: { beside in
                reading.beside = beside
                report()
            }
    }

    private func report() {
        guard let fit, let depth, let beside = reading.beside, let scrolled = reading.scrolled else { return }
        let screen = reading.screen ?? fit.nameScreen()
        reading.screen = screen
        fit.report(content: beside + scrolled + clearance, from: screen, atDepth: depth)
    }
}
