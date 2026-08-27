//
//  SheetPresentation.swift
//  OpenHikes
//
//  Where the sheet rests, and what is pushed into it.
//
//  Both of these used to be `@State` on `OpenHikesView`: the path because a
//  widget tap has to be able to push a hike from outside the sheet, and the
//  detent because `.presentationDetents(_:selection:)` is attached out there
//  too. That is what made opening a photo — three pushes down, inside a screen
//  that covers the whole sheet — re-evaluate the root view, the sheet and the
//  hikes list underneath it. `@State` invalidates the view that declares it
//  whether or not its body reads it, so "the root doesn't render a photo" was
//  never going to be enough on its own; the state had to leave the view.
//
//  Held in a reference type instead, for the reason ``SheetMetrics``,
//  ``RouteStyle`` and ``MapController`` are. The difference is what is
//  published: ``path`` and ``detent`` are driven through bindings that no body
//  reads, and everything a view actually needs to *know* is a derived flag
//  beside them. Observation is per-property, so a push from one screen to
//  another inside the same hike changes none of those flags and re-evaluates
//  nothing above the navigation stack.
//
//  A flag here earns its place by being coarser than the thing it is derived
//  from. `hasPushedScreen` is not `path`, and `isCompact` is not `detent`:
//  that is the whole point, and a view that reads `path` or `detent` in its
//  body has quietly put the old cost back.
//

import SwiftUI

@Observable
final class SheetPresentation {
    /// Non-isolated so releasing the last reference never requires proving
    /// we're on the main actor — see ``LocationManager``'s deinit for why.
    nonisolated deinit { /* intentionally empty */ }

    /// Height of the compact detent, where only the search field shows.
    ///
    /// Lived in `OpenHikesView` and again in `MapSheet` before this type
    /// existed — one declaring the detent and the other testing for it, with
    /// nothing keeping the two numbers equal.
    static let compactDetentHeight: CGFloat = 80
    static let compactDetent: PresentationDetent = .height(compactDetentHeight)
    static let detents: Set<PresentationDetent> = [compactDetent, .medium, .large]

    /// The sheet's navigation stack.
    ///
    /// A computed property over untracked storage so the setter can recompute
    /// the flags below in the same breath as the write — including the write
    /// `NavigationStack` itself makes when the user swipes back, which no call
    /// site here would ever see.
    var path: [SheetRoute] {
        get {
            access(keyPath: \.path)
            return storedPath
        }
        set {
            withMutation(keyPath: \.path) { storedPath = newValue }
            pathDidChange()
        }
    }

    /// Where the sheet rests. Written by the drag, by the detent picker's own
    /// write-back, and by the screens that need room.
    var detent: PresentationDetent {
        get {
            access(keyPath: \.detent)
            return storedDetent
        }
        set {
            guard newValue != storedDetent else { return }
            withMutation(keyPath: \.detent) { storedDetent = newValue }
            detentDidChange()
        }
    }

    /// Whether the recording screen is the one on top. Read by the map's route
    /// selection, which draws a live recording differently from a saved hike —
    /// and by nothing else, so pushing a hike's photo leaves it alone.
    private(set) var isRecordingPresented = false

    /// Whether anything at all is pushed over the sheet's root. What the map's
    /// camera pill and photo pins belong to: a screen, any screen, rather than
    /// a particular one.
    private(set) var hasPushedScreen = false

    /// True at the smallest detent, where only the search field shows.
    private(set) var isCompact: Bool

    /// True at the largest detent, where the sheet covers the map.
    private(set) var isFullHeight: Bool

    /// True at the middle detent — the only one ``SheetMetrics`` learns a
    /// resting height for.
    private(set) var isAtMiddleDetent: Bool

    @ObservationIgnored private var storedPath: [SheetRoute] = []
    @ObservationIgnored private var storedDetent: PresentationDetent
    /// Whether the top of the stack is currently a screen that wants the whole
    /// sheet, so ``applyFullHeightPolicy()`` acts on the transition rather than
    /// on every path write.
    @ObservationIgnored private var isShowingFullHeightScreen = false
    /// The height the sheet was at before a full-height screen was pushed, so
    /// popping back restores it rather than collapsing a detail view that was
    /// being read at `.large`.
    @ObservationIgnored private var detentBeforeFullHeight: PresentationDetent?

    init(detent: PresentationDetent? = nil) {
        let initial = detent
            ?? (AppLaunchEnvironment.startsWithExpandedSheet ? .medium : Self.compactDetent)
        storedDetent = initial
        isCompact = initial == Self.compactDetent
        isFullHeight = initial == .large
        isAtMiddleDetent = initial == .medium
    }

    /// Drives `NavigationStack`. A binding rather than the property itself
    /// because building one reads nothing: the stack calls the getter during
    /// its own update, which registers the dependency on the stack and not on
    /// whichever body happened to construct it.
    var pathBinding: Binding<[SheetRoute]> {
        Binding(get: { self.path }, set: { self.path = $0 })
    }

    /// Drives `.presentationDetents(_:selection:)`, and a binding for the same
    /// reason.
    var detentBinding: Binding<PresentationDetent> {
        Binding(get: { self.detent }, set: { self.detent = $0 })
    }

    /// Sends the sheet to its smallest detent when the full-height screen pops,
    /// rather than back to the height the hike was being read at.
    ///
    /// Called by the photo viewer's "show on map" button and by nothing else.
    /// That button dismisses the picture *because* the user asked where it was
    /// taken, and the restore below — which exists so a reader who was at
    /// `.large` is put back there — would answer by covering the very thing
    /// they asked to see. Overwriting the remembered height is enough: the pop
    /// runs the same restore and finds the decision already made.
    func collapseWhenFullHeightScreenPops() {
        detentBeforeFullHeight = Self.compactDetent
    }

    private func pathDidChange() {
        let recording = storedPath.last == .recording
        if isRecordingPresented != recording { isRecordingPresented = recording }
        let pushed = !storedPath.isEmpty
        if hasPushedScreen != pushed { hasPushedScreen = pushed }
        applyFullHeightPolicy()
    }

    /// The photo viewer draws one picture and nothing else, so it takes the
    /// whole sheet. Decided here rather than in the viewer's own `onAppear`
    /// because popping back has to restore the height the hike screen was read
    /// at — a viewer dismissed to a full-height detail view has swallowed the
    /// map, and one dismissed to a fixed `.medium` has thrown away a reader's
    /// own choice of `.large`.
    ///
    /// Derived from the path rather than driven by a push event, so an
    /// abandoned back-swipe recomputes to the same answer rather than leaving
    /// the sheet remembering a height it never left.
    private func applyFullHeightPolicy() {
        let wantsFullHeight = storedPath.last?.prefersFullHeight ?? false
        guard wantsFullHeight != isShowingFullHeightScreen else { return }
        isShowingFullHeightScreen = wantsFullHeight
        guard wantsFullHeight else {
            let restored = detentBeforeFullHeight ?? .medium
            detentBeforeFullHeight = nil
            withAnimation { detent = restored }
            return
        }
        detentBeforeFullHeight = storedDetent
        withAnimation { detent = .large }
    }

    private func detentDidChange() {
        let compact = storedDetent == Self.compactDetent
        if isCompact != compact { isCompact = compact }
        let full = storedDetent == .large
        if isFullHeight != full { isFullHeight = full }
        let middle = storedDetent == .medium
        if isAtMiddleDetent != middle { isAtMiddleDetent = middle }
    }
}
