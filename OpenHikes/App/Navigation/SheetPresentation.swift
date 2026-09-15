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
//  ``layout`` is the second input those flags are derived from. In landscape
//  the sheet is not a sheet at all — see ``MapSidePanel`` — and a panel that
//  fills its side of the screen is never compact and never at a detent,
//  whatever the stored detent happens to say. Keeping that in the flags rather
//  than at the call sites is what stops the sheet's own screens from having to
//  ask which shape they are being drawn in.
//

import SwiftUI

/// The shape the sheet's contents are drawn in.
///
/// Not a cosmetic choice: `.presentationDetents` are honoured only in a
/// compact-width, regular-height presentation, and iPhone landscape is compact
/// *height* — so the system presents the sheet full-screen there. For an app
/// that keeps this sheet up permanently and re-presents it when it is
/// dismissed, that is not a taller sheet but the whole UI, with the map behind
/// it and no way back. Landscape gets a side panel instead.
enum SheetLayout {
    /// Portrait: an Apple Maps-style detented sheet over the map.
    case bottomSheet
    /// Compact height: a panel down the leading edge, with the map beside it.
    case sidePanel
}

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

    /// True at the smallest detent, where only the search field shows. Never
    /// true in a side panel, which has the height for the hikes list whatever
    /// detent the sheet would have rested at.
    private(set) var isCompact: Bool

    /// True where the sheet's contents have the full height available to them:
    /// the largest detent, or a side panel, which is always that tall.
    private(set) var isFullHeight: Bool

    /// True at the middle detent — the only one ``SheetMetrics`` learns a
    /// resting height for. A side panel rests at no detent and reports none.
    private(set) var isAtMiddleDetent: Bool

    /// Which shape the contents are drawn in. Written by ``SheetLayoutReader``,
    /// which is where the vertical size class is read — on iPhone, a change to
    /// it is a rotation. Read by `OpenHikesView`, which is why it is a
    /// published flag and not an environment value: see that file for what the
    /// environment read cost when it was in the root view's body.
    var layout: SheetLayout {
        get {
            access(keyPath: \.layout)
            return storedLayout
        }
        set {
            guard newValue != storedLayout else { return }
            withMutation(keyPath: \.layout) { storedLayout = newValue }
            recomputeDetentFlags()
        }
    }

    /// The hosts are replaced on rotation, but their destinations keep these
    /// objects until the corresponding route is popped. Cache lookup must not
    /// subscribe MapSheet to a destination's interaction state.
    @ObservationIgnored private var hikeInteractions: [UUID: HikeDetailInteraction] = [:]
    @ObservationIgnored private var photoSelections: [SheetRoute: PhotoViewerSelection] = [:]
    /// The same, for a shared hike's gallery. A second dictionary rather than
    /// a second field on ``PhotoViewerSelection``, because the two galleries
    /// identify a page differently — see ``CommunityPhotoSelection``.
    @ObservationIgnored private var communityPhotoSelections: [SheetRoute: CommunityPhotoSelection] = [:]

    func hikeInteraction(for hike: Hike) -> HikeDetailInteraction {
        if let existing = hikeInteractions[hike.id] { return existing }
        let interaction = HikeDetailInteraction()
        hikeInteractions[hike.id] = interaction
        return interaction
    }

    /// Opens a published hike's preview, from anywhere.
    ///
    /// Here rather than at the call sites because the rules it keeps belong to
    /// the sheet rather than to whatever asked, and because there are two ways
    /// in that must not disagree: the map's shared-hike pins and its line taps
    /// — see ``OpenHikesView``'s `onAppear` — and the sheet's own community
    /// rows, which reach this through ``MapSheet``'s `select(_:)`. Both are a
    /// tap on the same hike, so both can arrive at one already open.
    ///
    /// **A listing is never on the stack twice**, and that is this method's
    /// job rather than a happy accident. ``isPresentingCommunityHike(_:)`` is
    /// what a disappearing preview asks to tell a push over it from the hiker
    /// leaving, and it asks about the *listing*: a second copy of the same one
    /// answers for the copy being popped, so that screen cancels no download,
    /// cancels no analysis, tells the map nothing and leaves its downloads in
    /// `tmp` forever. Guarding only the top of the stack left that a gesture
    /// away — pin A, pin B, pin A — and left `[A, A]`, where Back lands the
    /// hiker on the screen they were already looking at.
    ///
    /// Popping back to the open copy rather than refusing, because the two are
    /// the same answer to *show me this hike* and only one of them moves: a
    /// hiker who taps A's pin over B's preview asked to see A.
    func showCommunityHike(_ listing: CommunityListing) {
        let route = SheetRoute.communityHike(listing)
        guard path.last != route else { return }
        // The compact detent is only tall enough for the search field, so a
        // screen pushed into it would arrive with nowhere to draw — the same
        // reason opening a recording moves the sheet. Before either branch,
        // since a preview popped back to is as unreadable down there as one
        // pushed: the hiker can have dragged the sheet down over it.
        //
        // Unconditional rather than only from compact. Opening a preview puts
        // somebody else's line on the map and frames it, and the framing aims
        // at the strip above the middle detent — so arriving at `.large`
        // means the map moved to show a route under a sheet that covers it.
        // The detent a reader chose is worth less than the thing they opened
        // the screen to look at.
        makeRoomForTheMap()
        if let open = path.firstIndex(of: route) {
            path.removeSubrange((open + 1)...)
        } else {
            path.append(route)
        }
    }

    /// Opens a published hike: the hiker's own copy of it when they have one,
    /// and the stranger's preview when they do not.
    ///
    /// `imported` is that copy, resolved by the caller rather than here,
    /// because the two doors already know it by different routes — the
    /// sheet's rows read it out of the `@Query` they are drawn from, which is
    /// the same fact that puts *Saved* on the row, and the map's pins fetch
    /// it. What the two must not do is decide *what to open* separately: a
    /// hiker who taps one trail on the map and then in the list would get two
    /// different screens for the same hike.
    ///
    /// A hike already in the library goes to the library's own screen for it.
    /// The preview is the page that asks whether to keep somebody else's
    /// hike, and for a hike already kept it offered one control — *Open in My
    /// Hikes* — which is a tap spent on the answer to the question the first
    /// tap had already asked.
    ///
    /// The selection goes with it for the reason ``MapSheet``'s own `open`
    /// sets one: it is what draws the route on the map behind the sheet, and
    /// a hike reached from a community row has to land exactly as the same
    /// hike reached from the hiker's own list does.
    func open(
        _ listing: CommunityListing,
        importedAs imported: Hike?,
        selectedHike: inout Hike?
    ) {
        guard let imported else {
            showCommunityHike(listing)
            return
        }
        // Before the push, for the reason ``showCommunityHike(_:)`` gives: the
        // compact detent is only tall enough for the search field, a map pin
        // can be tapped with the sheet dragged down over it, and selecting the
        // imported hike draws its route and frames it above the sheet.
        makeRoomForTheMap()
        selectedHike = imported
        // Assigned rather than appended, exactly as `MapSheet.open` assigns:
        // this is a jump to one trail rather than a step deeper into the
        // screen the hiker was on.
        let route = SheetRoute.hike(imported)
        guard path != [route] else { return }
        path = [route]
    }

    /// Whether `listing`'s preview is the screen the hiker is on.
    ///
    /// What an import asks before it navigates. The save itself is already
    /// authorized and finishes either way — see
    /// ``CommunityHikeView``'s `performImport` — but the trip to the saved
    /// hike belongs to the screen that asked for it, and a copy of somebody's
    /// photographs can outlast the screen by seconds. Without this, going
    /// Back and opening something else while one was running had the hiker's
    /// newer choice replaced by the older one.
    ///
    /// The top of the stack rather than membership in it, because the
    /// navigation this guards assigns the whole path: acting while another
    /// screen sits over the preview would take that screen away too.
    func isShowingCommunityHike(_ listing: CommunityListing) -> Bool {
        path.last == .communityHike(listing)
    }

    /// Whether `listing`'s preview is still *somewhere* in the sheet's stack.
    ///
    /// The other half of the question above, and the one a disappearing
    /// screen asks. SwiftUI takes a pushed-over view out of the hierarchy
    /// exactly as it takes a popped one out, and a community preview treated
    /// both as the hiker leaving: it retired its line from the map and
    /// deleted the stranger's photographs it had downloaded, while the screen
    /// itself was still on the stack with its answer intact. A map pin can
    /// push a second preview over an open one, so this is a gesture away.
    ///
    /// Membership rather than the top of the stack, because that is precisely
    /// what separates a push over this screen from this screen being popped.
    ///
    /// Which makes this an answer about the *listing* being asked by one
    /// screen, and it is only the right one because a listing cannot be on the
    /// stack twice — see ``showCommunityHike(_:)``, which is the single door
    /// every push goes through and the reason that holds.
    func isPresentingCommunityHike(_ listing: CommunityListing) -> Bool {
        path.contains(.communityHike(listing))
    }

    func photoSelection(for route: SheetRoute) -> PhotoViewerSelection {
        if let existing = photoSelections[route] { return existing }
        let selection = PhotoViewerSelection()
        photoSelections[route] = selection
        return selection
    }

    func communityPhotoSelection(for route: SheetRoute) -> CommunityPhotoSelection {
        if let existing = communityPhotoSelections[route] { return existing }
        let selection = CommunityPhotoSelection()
        communityPhotoSelections[route] = selection
        return selection
    }

    @ObservationIgnored private var storedPath: [SheetRoute] = []
    @ObservationIgnored private var storedDetent: PresentationDetent
    @ObservationIgnored private var storedLayout: SheetLayout = .bottomSheet
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

    /// Puts the sheet where the map's framing expects to find it.
    ///
    /// **The one rule every camera move in this app shares.** A zoom decides
    /// what to show by measuring the map that is *not* behind the sheet — see
    /// ``MapView/Coordinator/obstructionInsets(in:)`` — and that measurement
    /// is taken against the middle detent, because the middle detent is where
    /// the sheet is about to be. Anywhere the two disagree, the hiker gets a
    /// camera move aimed at a strip of screen that is not the strip they can
    /// see: too far down and half the route is under the sheet, too far up and
    /// it is squeezed into the top third for no reason.
    ///
    /// Called by everything that asks the map to move and reaches this type —
    /// a search, a preview, an imported hike, the hike screen's *Zoom*, a
    /// walk's *Show on Map*. The photo viewer takes the same decision through
    /// ``restAtMiddleWhenFullHeightScreenPops()``, because it has to survive a
    /// pop rather than apply now.
    ///
    /// Unconditional, and that is the change rather than an oversight: this
    /// used to move only a *compact* sheet, which left `.large` — a height a
    /// reader chose, and one that covers the whole map — to swallow the thing
    /// they had just asked to be shown.
    func makeRoomForTheMap() {
        guard detent != .medium else { return }
        withAnimation { detent = .medium }
    }

    /// Sends the sheet to its middle detent when the full-height screen pops,
    /// rather than back to the height the hike was being read at.
    ///
    /// Called by the photo viewer's "show on map" button and by nothing else.
    /// That button dismisses the picture *because* the user asked where it was
    /// taken, and the restore below — which exists so a reader who was at
    /// `.large` is put back there — would answer by covering the very thing
    /// they asked to see. Overwriting the remembered height is enough: the pop
    /// runs the same restore and finds the decision already made.
    ///
    /// The middle detent rather than the smallest, which is what this did
    /// before. Every camera move in this app now frames what it is aiming at
    /// into the map *above* the sheet at that height — see
    /// ``MapView/Coordinator/obstructionInsets(in:)`` — so a sheet that drops
    /// further than the framing assumed leaves the photograph's pin sitting in
    /// the top half of a screen whose bottom half is map. Landing where the
    /// framing expects is what makes "show me where this was taken" put the
    /// pin in the middle of what is visible.
    func restAtMiddleWhenFullHeightScreenPops() {
        detentBeforeFullHeight = .medium
    }

    private func pathDidChange() {
        hikeInteractions = hikeInteractions.filter { id, _ in
            storedPath.contains { $0.shows(hikeID: id) }
        }
        photoSelections = photoSelections.filter { storedPath.contains($0.key) }
        communityPhotoSelections = communityPhotoSelections.filter { storedPath.contains($0.key) }
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
        recomputeDetentFlags()
    }

    /// The three coarse flags, from the detent *and* the layout.
    ///
    /// A side panel keeps the detent it would have rested at — a rotation back
    /// to portrait puts the sheet where it was, and the full-height policy
    /// above goes on working while a photo is open in landscape — but none of
    /// the heights it describes are true of a panel, so the answers are fixed
    /// rather than read while one is on screen.
    private func recomputeDetentFlags() {
        let isPanel = storedLayout == .sidePanel
        let compact = !isPanel && storedDetent == Self.compactDetent
        if isCompact != compact { isCompact = compact }
        let full = isPanel || storedDetent == .large
        if isFullHeight != full { isFullHeight = full }
        let middle = !isPanel && storedDetent == .medium
        if isAtMiddleDetent != middle { isAtMiddleDetent = middle }
    }
}
