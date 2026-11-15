//
//  SidePanelFit.swift
//  OpenHikes
//
//  How tall ``MapSidePanel`` stands where its window has height to spare.
//
//  The panel was the window's height everywhere, which is all an iPhone on its
//  side has. On an iPad the same column is close to three times as tall as a
//  recording has anything to say in: a card of figures at the top and glass
//  under it down to the bottom edge, over map the hiker could have been
//  reading. So at a regular height the panel is as tall as the screen on top
//  of the sheet's stack needs, and stands at the top of the leading edge, so
//  the search field and the bar stay where they were as it changes height.
//
//  ## What a screen asks for
//
//  A navigation stack takes whatever height it is offered, so nothing in
//  SwiftUI's own layout can say how tall its screen would like to be. The
//  screens say it themselves, in three figures that the model adds up:
//
//  - the bars the stack draws around the screen, from `sidePanelScreen(depth:)`;
//  - what the screen draws beside its scroll view rather than inside it — the
//    search field over the hikes list, *Details | History* over a hike — and
//  - what that scroll view has to scroll, both from `fitsSidePanel()`.
//
//  **Not one of them moves when the panel does**, and that is why there are
//  three. The plain measure is the one scroll view's overflow added to the
//  panel's height, which are two readings that both follow the panel and
//  arrive apart: a pass that has one new and the other old asks for a height
//  that is wrong by exactly the change under way, the panel takes it, and the
//  next pass is wrong by the correction. A sum of figures that do not depend
//  on the answer has nothing to chase.
//
//  The keyboard is in none of them. The panel is laid out inside the safe
//  area, the keyboard's included, so it is never under the keys; a list of
//  suggestions longer than what is left above them is given all of it, and
//  scrolls.
//
//  ## Which screen is asked
//
//  The one on top, by how deep it is in the stack — see
//  ``EnvironmentValues/sidePanelDepth``. A screen pushed over keeps what it
//  asked for, because nothing about it changes while it is covered and so it
//  will not say it again when the screen over it is popped. A screen that has
//  not asked yet changes nothing: the panel keeps the height it has until the
//  new screen is laid out, rather than opening to the whole window for the
//  frame in between.
//
//  A photo viewer asks for nothing. It is one picture, so it has the window's
//  height while it is a column beside the map — see
//  ``SheetRoute/prefersFullHeight`` — and the window itself the rest of the
//  time, which is ``MapSidePanel``'s own business.
//

import SwiftUI

@Observable
final class SidePanelFit {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// The coordinate space each of the sheet's screens is laid out in, which
    /// its scroll view measures itself against. Named by
    /// `sidePanelScreen(depth:)`.
    ///
    /// `nonisolated` because it is read inside `onGeometryChange`'s transform,
    /// which the iOS 26 SDK makes a `@Sendable` closure. Swift 6.4 lets the
    /// main-actor default pass there, and the Swift 6.3 that CodeQL builds
    /// with does not.
    nonisolated static let screenSpace = "side-panel-screen"

    /// How tall the panel stands, or `nil` for the whole height of its window:
    /// at a compact height, under a photo viewer, and until the first screen
    /// has been laid out.
    ///
    /// The one thing here a view reads, and ``MapSidePanel`` is the view.
    private(set) var height: CGFloat?

    /// Whether the window has height to spare, which a compact one has not:
    /// an iPhone on its side shows less of every screen than the screen has,
    /// so its panel keeps the window's height. Written by
    /// ``SheetLayoutReader``, where the size class is read.
    ///
    /// What the screens asked for is kept while this is off. A closed iPhone
    /// Duo turned on its side and opened again is the same panel and the same
    /// screens, and they will not ask twice.
    var fitsContent: Bool {
        get { storedFitsContent }
        set {
            guard newValue != storedFitsContent else { return }
            storedFitsContent = newValue
            settle()
        }
    }

    /// What a screen's scroll view asked for, and which screen it was.
    private struct Content {
        let screen: Int
        let height: CGFloat
    }

    @ObservationIgnored private var storedFitsContent = false
    @ObservationIgnored private var bars: [Int: CGFloat] = [:]
    @ObservationIgnored private var contents: [Int: Content] = [:]
    @ObservationIgnored private var depth = 0
    @ObservationIgnored private var topFillsPanel = false
    @ObservationIgnored private var lastScreen = 0
    /// Whether the panel has stood at a fitted height since it was put up,
    /// which is when a change to it starts being animated — see ``settle()``.
    @ObservationIgnored private var hasFitted = false

    /// A name for one screen's scroll view, newer than every name before it.
    ///
    /// Two screens can stand at one depth for a moment: a preview tapped over
    /// another replaces it in place, and the one going can still be laid out
    /// on its way off. The newer screen's word is the one kept — see
    /// ``report(content:from:atDepth:)``.
    func nameScreen() -> Int {
        lastScreen += 1
        return lastScreen
    }

    /// The height of the bars the navigation stack draws around the screen at
    /// `depth` — its safe area, top and bottom. Reported more than once for
    /// one screen: a pushed screen is laid out before its bar is, and the bar
    /// is ten points taller once the push has finished.
    func report(bars height: CGFloat, atDepth depth: Int) {
        guard bars[depth] != height else { return }
        bars[depth] = height
        settle()
    }

    /// The height the screen at `depth` needs inside those bars: what its
    /// scroll view has to scroll, and what it draws beside that scroll view.
    ///
    /// Ignored from a screen older than the one already heard from at that
    /// depth, which is a screen on its way off — see ``nameScreen()`` — and
    /// from one deeper than the stack goes, which is a screen being popped.
    func report(content height: CGFloat, from screen: Int, atDepth depth: Int) {
        guard depth <= self.depth else { return }
        if let heard = contents[depth] {
            guard screen >= heard.screen else { return }
            guard screen != heard.screen || height != heard.height else { return }
        }
        contents[depth] = Content(screen: screen, height: height)
        settle()
    }

    /// The sheet's stack changed: `depth` screens are pushed, the first `kept`
    /// of them are the screens that were there before, and the one on top
    /// takes the panel's whole height if `fillingPanel`.
    ///
    /// What any other screen asked for goes with it. A screen popped is
    /// gone, and so is one a jump replaced from deeper in the stack — a tap
    /// on a trail's line, or *Record*, assigns the whole path. The next
    /// screen at that depth is another screen, and the panel would otherwise
    /// open to the old one's height on its way to the new one's.
    func show(depth: Int, keeping kept: Int, fillingPanel: Bool) {
        self.depth = depth
        topFillsPanel = fillingPanel
        bars = bars.filter { $0.key <= kept }
        contents = contents.filter { $0.key <= kept }
        settle()
    }

    /// The panel was taken down — the window is a sheet's again. The screens
    /// are built anew in the next panel and each says what it needs as it is
    /// laid out, so nothing heard in this one is kept.
    func forget() {
        bars = [:]
        contents = [:]
        hasFitted = false
        if height != nil { height = nil }
    }

    /// Works ``height`` out again, and publishes it if it moved.
    ///
    /// **Animated, except for the first.** A push to a longer screen, a place
    /// added to a recording and a photo viewer popped are all the panel
    /// changing in front of the hiker. The first height a panel takes is not:
    /// it is put up at the window's height because nothing has been laid out
    /// to measure, and a launch that began with it closing down to its
    /// contents would be an animation about bookkeeping.
    private func settle() {
        let fitted: CGFloat?
        if !storedFitsContent || topFillsPanel {
            fitted = nil
        } else if let around = bars[depth], let content = contents[depth] {
            fitted = max((around + content.height).rounded(.up), MapSidePanelLayout.minimumHeight)
        } else {
            // The screen on top has not been laid out yet. Keep the height
            // the panel has — see the header.
            return
        }
        guard fitted != height else { return }
        if hasFitted {
            withAnimation(.snappy) { height = fitted }
        } else {
            height = fitted
        }
        if fitted != nil { hasFitted = true }
    }
}
