//
//  MapSheet.swift
//  OpenHikes
//
//  Apple Maps–style persistent bottom sheet. Starts with a search field,
//  and surfaces a Hikes section once expanded past the compact detent.
//

import MapKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MapSheet: View {
    private static let topPadding: CGFloat = 18
    /// How close the search field and the settings button have to come before
    /// their glass merges. Slightly under the 10pt gap between them, so they
    /// stay two shapes at rest and blend as the layout tightens.
    private static let chromeGlassSpacing: CGFloat = 8

    @Binding var selectedHike: Hike?
    /// Where the sheet rests and what is pushed into it. Owned by
    /// `OpenHikesView` rather than this view, so a widget tap can push a hike's
    /// detail view from outside the sheet and so the detent picker can be
    /// attached out there — but handed over by reference, so a push that
    /// changes neither the resting height nor whether anything is pushed at all
    /// re-evaluates neither that view nor this one. The path is typed as
    /// `[SheetRoute]` (not `NavigationPath`) because the caller has to be able
    /// to ask what's already on screen before deciding to navigate —
    /// `NavigationPath` can be appended to but never read back.
    var presentation: SheetPresentation

    /// What is typed in the field below, which lives on ``presentation``
    /// rather than here or in `OpenHikesView`.
    ///
    /// It was `@State` out there, handed down as a `@Binding`, and `@State`
    /// invalidates the view that declares it whether or not that view's body
    /// reads the value — so every keystroke re-evaluated the root view: the
    /// map, the side panel, the three alerts and the six `onChange` handlers
    /// attached alongside them. None of that draws a character of it. See
    /// ``SheetPresentation/searchText`` for why it is stored raw there when
    /// the path and the detent are not.
    ///
    /// Forwarded rather than read at each site so this view keeps writing the
    /// text the way it always did — clearing it on a tapped hike, filling it
    /// from a tapped completion — and `nonmutating` because the storage is a
    /// reference this struct merely points at.
    private var searchText: String {
        get { presentation.searchText }
        nonmutating set { presentation.searchText = newValue }
    }

    var highlight: RouteHighlight
    /// Handed down so a walk's summary can draw what it covered on the map.
    /// See ``WalkHighlight``.
    var walkHighlight: WalkHighlight
    var mapController: MapController
    /// Handed down so a pushed screen can offer the map's camera pill, and
    /// taken away again when it goes. See ``PhotoCaptureController``.
    var photoCapture: PhotoCaptureController
    /// Handed down so a pushed hike can draw its photos on the map, and a
    /// tapped pin can push the gallery back. See ``PhotoMapPinController``.
    var photoPins: PhotoMapPinController
    /// Handed down so a pushed hike can draw its marked places on the map, and
    /// taken away again when it goes. See ``TrailPlacePinController``.
    var placePins: TrailPlacePinController
    /// Handed down so the maker's screen can rename, cancel and save the draft
    /// the map is drawing, and so this view can tell it when it is on top. See
    /// ``TrailDraftController``.
    var trailMaker: TrailDraftController

    var onImportGPX: ([URL]) -> Void = { _ in /* no-op default */ }
    /// The document picker failed to produce a file at all.
    var onImportFailed: () -> Void = { /* no-op default */ }
    /// A place search reached MapKit and came back with an error.
    var onSearchFailed: (SearchFailure) -> Void = { _ in /* no-op default */ }
    /// Reports the sheet's top edge (global Y) as it's dragged, so the map can
    /// keep the "my location" button riding just above the sheet.
    var onSheetTopChange: (CGFloat) -> Void = { _ in /* no-op default */ }
    /// Reports the sheet coming to rest at (or leaving) its middle detent,
    /// which is the only one the map learns a resting height for.
    var onSheetDetentCommitted: (Bool) -> Void = { _ in /* no-op default */ }

    @Environment(OpenHikesModel.self)
    private var appModel
    @FocusState private var searchFocused: Bool
    @State private var showImporter = false
    @State private var showSettings = false
    /// The hike whose takedown request is up, offered from the delete dialog.
    ///
    /// Held here rather than in ``MapSheetHikes`` because the form has to
    /// outlive the dialog that offered it: a `confirmationDialog` dismisses
    /// itself the moment a button is tapped, and a sheet presented from the
    /// view that dialog belongs to would be torn down with it.
    @State private var withdrawingHike: Hike?
    @State private var searchTask: Task<Void, Never>?

    /// Autocomplete for the search field. Owned by the model rather than held
    /// here, because the map is what tells it where the hiker is looking —
    /// see ``SearchCompleter/regionDidSettle(_:)``.
    private var completer: SearchCompleter {
        appModel.searchCompleter
    }

    private var autoSave: AutoSaveController {
        appModel.autoSaveController
    }

    private var hikeRecorder: HikeRecorder {
        appModel.hikeRecorder
    }

    var body: some View {
        // Deliberately reads no `Hike`, and no `path` or `detent` either. This
        // body is the `NavigationStack` the hike detail view — with its
        // touch-frequency tint and width sliders — is pushed into, and
        // `MapSheetHikes` holds the `@Query`, which has no per-property
        // granularity; keeping both out of here is what stops a slider drag,
        // and a push two screens deep, re-evaluating the search field and the
        // navigation stack. The three flags below are coarse on purpose — see
        // ``SheetPresentation``.
        NavigationStack(path: presentation.pathBinding) {
            VStack(spacing: 0) {
                // One container for the two pieces of chrome side by side:
                // they sample the map behind them once between them, and the
                // field's capsule and the button's circle blend as the
                // keyboard pushes them together rather than sliding past each
                // other as two unrelated panes.
                GlassStack(spacing: Self.chromeGlassSpacing) {
                    HStack(spacing: 10) {
                        searchField
                        settingsButton
                    }
                }
                    .padding(.horizontal)
                    .padding(.top, Self.topPadding)

                MapSheetHikes(
                    searchText: searchText,
                    isSearchFocused: searchFocused,
                    isCompact: presentation.isCompact,
                    completer: completer,
                    recorder: hikeRecorder,
                    walkSession: appModel.walkSession,
                    community: appModel.community,
                    review: appModel.communityReview,
                    selectedHikeID: selectedHike?.id,
                    onOpen: open,
                    onSelectResult: select,
                    onSelectCompletion: select,
                    onSubmitQuery: performSearch,
                    onSelectListing: select,
                    onSelectPending: { presentation.path.append(.pendingSubmission($0)) },
                    onSelectPendingPhotos: { presentation.path.append(.pendingPhotos($0)) },
                    onDelete: delete,
                    onWithdraw: { withdrawingHike = $0 },
                    onImport: presentImporter
                )
                    // The list of every hike, rebuilt only when one of the
                    // values above actually differs. Without this it is rebuilt
                    // whenever this body runs, because the action closures are
                    // new objects every pass — which made a photo tap three
                    // screens away redraw every row on the map screen.
                    .equatable()
            }
            .navigationDestination(for: SheetRoute.self, destination: pushedScreen)
            #if os(iOS)
            // The sheet's own screen has no navigation bar: the search field
            // and the settings button are its chrome, and they are drawn at
            // the top of the sheet rather than under a bar.
            //
            // Said outright rather than left to be inferred from "this view
            // sets no title". The inferred answer is right until a pushed
            // screen that *does* set one is popped programmatically — a
            // discarded recording, which pops from inside its confirmation
            // dialog's own dismissal — and then the bar the pushed screen
            // brought stays behind, 54 points of empty glass above the search
            // field. Pushing anything else and coming back cleared it, which
            // is what made it look like padding that came and went. An
            // explicit hidden bar is a preference the root re-asserts every
            // time it is shown, so the pop has something to restore *to*
            // rather than an absence to infer from.
            .toolbar(.hidden, for: .navigationBar)
            // Set the title mode at the stack level so it's resolved before
            // any push — avoids the large-title bar expanding/flicking in.
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .accessibilityIdentifier("map-sheet")
        // Presented from inside the sheet so it isn't blocked by the sheet's
        // own presentation context.
        .gpxFileImporter(isPresented: $showImporter, onImport: onImportGPX, onFailed: onImportFailed)
        // Presented from here rather than from the row that offered it, for
        // the reason ``withdrawingHike`` gives: the dialog is already gone by
        // the time this opens.
        .sheet(item: $withdrawingHike) { hike in
            if let withdrawal = CommunityWithdrawal(hike: hike) {
                CommunityWithdrawalSheet(withdrawal: withdrawal)
            }
        }
        // Also presented from inside the sheet so it layers above it.
        .sheet(isPresented: $showSettings) {
            SettingsView(
                autoSave: appModel.autoSaveController,
                backgroundTracker: appModel.backgroundTracker,
                locationManager: appModel.locationManager,
                blocks: appModel.communityBlocks,
                cloudSync: appModel.cloudSync,
                entitlement: appModel.entitlement
            )
        }
        // Focusing the search field expands the sheet to full height.
        .onChange(of: searchFocused) { _, focused in
            if focused {
                withAnimation { presentation.detent = .large }
            }
        }
        // Collapsing below full height (e.g. dragging to medium) drops focus.
        //
        // The flag rather than the detent itself: this only ever asks whether
        // the sheet is still at `.large`, and reading the detent here would put
        // every drag that settles somewhere new through this body.
        .onChange(of: presentation.isFullHeight) { _, isFullHeight in
            if !isFullHeight {
                searchFocused = false
            }
        }
        // The map's photo controls belong to whatever screen is pushed, and a
        // pushed screen's `onDisappear` arrives only once the pop animation has
        // finished — which left the camera pill and this hike's photo pins over
        // the map, fully opaque and answering taps, for the whole of a back
        // navigation. Reported here as a function of the path rather than as a
        // pop event, so an abandoned back-swipe recomputes to the same answer
        // rather than withdrawing them for good.
        //
        // "A screen, any screen" is deliberately all this asks: a hike and the
        // photo viewer pushed on top of it are both a screen that can offer the
        // pill, so moving between them changes nothing here.
        .onChange(of: presentation.hasPushedScreen, initial: true) { _, isPushed in
            photoCapture.setHostScreenPresent(isPushed)
            photoPins.setHostScreenPresent(isPushed)
            placePins.setHostScreenPresent(isPushed)
            // The inverse of the same signal, which is the whole of what keeps
            // the maker's pill and the camera's out of each other's way — see
            // ``TrailDraftController``.
            trailMaker.setHostScreenPresent(isPushed)
        }
        // And whether the map is the maker's canvas, which is a narrower
        // question than "is anything pushed" and has to be asked separately:
        // pushing a hike over the maker would leave the map taking waypoints
        // for a screen nobody is looking at.
        .onChange(of: presentation.isTrailDraftPresented, initial: true) { _, isDrafting in
            trailMaker.setEditing(isDrafting)
        }
        // Track the sheet's top edge continuously (including during interactive
        // drags) and hand it to the map so it can position the location button.
        .onTopEdgeChange(perform: onSheetTopChange)
        .onChange(of: presentation.isAtMiddleDetent) { _, atMiddle in
            onSheetDetentCommitted(atMiddle)
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search Maps", text: presentation.searchTextBinding)
                .accessibilityIdentifier("map-search")
                .focused($searchFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(performSearch)
                .onChange(of: searchText) { _, value in
                    completer.update(query: value)
                    // The same fragment, asked of the community. Gated by its
                    // own trimming rather than the completer's policy: the two
                    // answer different questions and a place suggestion the
                    // hiker has already committed to is still a trail name
                    // worth looking up.
                    appModel.community.prepareTitleSearch(matching: value)
                }
                .task(id: CommunityBrowser.normalizedTitle(searchText)) {
                    await appModel.community.searchAfterQuietPeriod(matching: searchText)
                }
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif

            if !searchText.isEmpty {
                Button {
                    searchTask?.cancel()
                    searchTask = nil
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                // The glyph above is the button's only content and is hidden,
                // which left this announcing itself as an unnamed button.
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("clear-search-button")
            }
        }
        .padding(10)
        // A capsule rather than a 12pt rounded rectangle: a search field is a
        // capsule everywhere in iOS 26, and it is what lets the circular
        // settings button beside it read as the same family of control.
        .glassSurface(.regular, in: .capsule)
    }

    /// Profile/settings entry point, sitting to the right of the search field —
    /// where Apple Maps puts its account button, but drawn as a gear because
    /// what it opens is Settings, not a profile.
    ///
    /// The circular glass here is the real button style rather than a glass
    /// background under a `.plain` button, so it picks up the press and
    /// morph response the style draws and the search field's chrome cannot.
    private var settingsButton: some View {
        Button {
            searchFocused = false
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.title2)
                .foregroundStyle(.secondary)
                .minimumTapTarget()
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .accessibilityLabel("Profile and settings")
        .accessibilityIdentifier("settings-button")
    }

    /// Somebody else's hike, or nothing at all on a launch that must not reach
    /// CloudKit — see ``OpenHikesModel/makeCommunityTransport()``.
    ///
    /// Its own method rather than a case body: it is the only destination that
    /// takes two closures, and folding them into the switch pushed the
    /// surrounding function past what the linter allows.
    @ViewBuilder
    private func communityHikeDestination(_ listing: CommunityListing) -> some View {
        if let transport = appModel.communityTransport {
            CommunityHikeView(
                listing: listing,
                transport: transport,
                blockList: appModel.communityBlocks,
                // Written by the screen, never read by it: it is what puts
                // this hike's real route on the map behind the sheet — see
                // ``CommunityHikeView``'s `browser`.
                browser: appModel.community,
                // Read for one thing: whether to offer *Take Down*. See
                // ``CommunityReviewQueue/isReviewer``.
                review: appModel.communityReview,
                // `open` assigns the whole path rather than appending to it, so
                // the preview is replaced rather than left underneath — which
                // is what should happen: backing out of a hike that is now in
                // the library, into a screen offering to add it, describes a
                // decision already made. That same assignment is why it is
                // guarded — see ``openImported(_:from:)``.
                onImport: { openImported($0, from: listing) },
                // Back to the list, which the block has already taken this hike
                // out of — ``CommunityBrowser`` filters on read, so the row is
                // gone by the time the pop lands. The refresh is for the case
                // where it took *every* row with it.
                onBlock: {
                    appModel.community.refreshAfterBlock()
                    presentation.path.removeAll()
                },
                // The gallery goes *over* the preview rather than replacing
                // it, and that is what keeps the pictures alive: the files
                // belong to the screen underneath, `remainsPushed` below is
                // what stops it collecting them while it is pushed over, and
                // popping the gallery lands back on the hike they are of.
                onOpenPhoto: { photos, index in
                    presentation.path.append(.communityPhoto(listing, photos, index))
                },
                // Asked while the screen is going, to tell a push over it from
                // the hiker leaving: the pop has already taken the route out
                // of the path by then, and a push has not.
                remainsPushed: { presentation.isPresentingCommunityHike(listing) },
                // The same graph the hiker's own hikes are measured against,
                // and the same region cache — so a shared trail through a
                // valley they have already walked costs nothing to describe.
                trailGraphProvider: appModel.trailGraphProvider
            )
        }
    }

    /// A shared hike's gallery, over the preview that downloaded it.
    ///
    /// Its own method for the reason ``communityHikeDestination(_:)`` is one:
    /// the switch below is already at the length the linter allows, and a
    /// destination taking four arguments is what pushes it past.
    ///
    /// The listing in the route is not read here — it is what identifies the
    /// screen, which is ``SheetPresentation``'s business and not this view's.
    private func communityPhotoDestination(
        _ listing: CommunityListing,
        _ photos: [CommunityGalleryPhoto],
        startIndex: Int,
        route: SheetRoute
    ) -> some View {
        CommunityPhotoViewer(
            photos: photos,
            startIndex: startIndex,
            mapController: mapController,
            onShowOnMap: presentation.restAtMiddleWhenFullHeightScreenPops,
            community: appModel.community,
            selection: presentation.communityPhotoSelection(for: route),
            // Absent on a launch with no transport, which is every hosted
            // suite and every UI scenario that did not ask for one — the rule
            // the share button and the community list already follow, so a
            // menu is never drawn over an action the launch could not perform.
            actions: appModel.communityTransport.map { transport in
                CommunityPhotoViewer.Context(
                    listing: listing,
                    blockList: appModel.communityBlocks,
                    transport: transport,
                    // Whether this account may take a contribution down —
                    // a fact about the account rather than about the
                    // photograph — and where a takedown is recorded so the
                    // trail behind this gallery stops drawing it. See
                    // ``CommunityReviewQueue``.
                    review: appModel.communityReview
                )
            },
            // Back one screen, to the trail. Deliberately one and not all the
            // way out: unlike blocking a hike's author — which leaves the
            // hiker looking at the whole of what they hid — the hike here is
            // somebody else's and stays perfectly visible. What has to go is
            // the gallery, which reopens without those pictures.
            //
            // Guarded rather than assumed: this screen is only ever reached by
            // a push, so the path cannot be empty — but `removeLast` on an
            // empty array is a crash rather than a no-op, and a callback held
            // by a view that outlives its own dismissal is not somewhere to
            // rely on an invariant nothing enforces.
            onLeave: {
                guard !presentation.path.isEmpty else { return }
                presentation.path.removeLast()
            }
        )
    }

    /// A destination on the sheet's own glass.
    ///
    /// A pushed screen otherwise gets the stack's opaque system background,
    /// which the root never has: the sheet was clear glass on the search screen
    /// and a white slab on every screen pushed over it, plainest at the compact
    /// detent where only the bar shows. Cleared here, once, so every
    /// destination shares the root's glass rather than each opting in.
    private func pushedScreen(for route: SheetRoute) -> some View {
        navigationDestinationView(for: route)
            .containerBackground(.clear, for: .navigation)
    }

    @ViewBuilder
    private func navigationDestinationView(for route: SheetRoute) -> some View {
        switch route {
        case .hike(let hike):
            HikeDetailView(
                hike: hike,
                highlight: highlight,
                mapController: mapController,
                autoSave: appModel.autoSaveController,
                entitlement: appModel.entitlement,
                locationManager: appModel.locationManager,
                backgroundTracker: appModel.backgroundTracker,
                trailGraphProvider: appModel.trailGraphProvider,
                walkSession: appModel.walkSession,
                photoCapture: photoCapture,
                photoPins: photoPins,
                placePins: placePins,
                placeSearch: appModel.placeSearchScope,
                communityTransport: appModel.communityTransport,
                onOpenPhoto: { photo in presentation.path.append(.photo(hike, photo.id)) },
                onOpenPlace: { placeID in openPlace(placeID, of: hike) },
                onOpenWalk: { walk in presentation.path.append(.walk(walk)) },
                onZoomToRoute: presentation.makeRoomForTheMap,
                isSheetCompact: presentation.isCompact,
                interaction: presentation.hikeInteraction(for: hike)
            )
        case let .communityHike(listing):
            communityHikeDestination(listing)
        case let .communityPhoto(listing, photos, startIndex):
            communityPhotoDestination(listing, photos, startIndex: startIndex, route: route)
        case let .pendingSubmission(pending):
            pendingSubmissionDestination(pending)
        case let .pendingPhotos(pending):
            pendingPhotosDestination(pending)
        case let .place(hike, placeID):
            placeDestination(placeID, of: hike)
        case let .newPlace(hike, spot):
            placeAdderDestination(at: spot, on: hike)
        case .trailDraft:
            trailDraftDestination
        case .recording:
            recordingDestination
        case let .photo(hike, photoID):
            HikePhotoViewer(
                hike: hike,
                startID: photoID,
                highlight: highlight,
                mapController: mapController,
                onShowOnMap: presentation.restAtMiddleWhenFullHeightScreenPops,
                photoPins: photoPins,
                selection: presentation.photoSelection(for: route)
            )
        case let .walk(walk):
            WalkSummaryView(
                walk: walk,
                walkHighlight: walkHighlight,
                mapController: mapController,
                onShowOnMap: presentation.makeRoomForTheMap
            )
        }
    }
}

// MARK: - The recorder

private extension MapSheet {
    /// The recording screen.
    ///
    /// Its own property for the reason ``trailDraftDestination`` and the two
    /// reviewer methods below are: the switch they came out of is at the
    /// length the linter allows, and it reads as a list of destinations rather
    /// than as the destinations themselves.
    var recordingDestination: some View {
        RecordingView(
            recorder: appModel.hikeRecorder,
            mapController: mapController,
            photoCapture: photoCapture,
            photoPins: photoPins,
            onSaved: showSavedHike,
            onDiscarded: closeDiscardedRecording,
            onOpenPhoto: { hike, photo in
                presentation.path.append(.photo(hike, photo.id))
            },
            placePins: placePins,
            placeSource: appModel.placeSource,
            onOpenPlace: { hike, placeID in openPlace(placeID, of: hike) }
        )
    }
}

// MARK: - The maker

private extension MapSheet {
    /// The trail maker.
    ///
    /// Its own property rather than a case body, for the reason the two
    /// reviewer destinations below have their own methods: the switch it comes
    /// out of is at the length the linter allows, and a destination taking
    /// five arguments is what pushes it past.
    var trailDraftDestination: some View {
        TrailDraftView(
            maker: trailMaker,
            // The same completer the sheet's own field uses, which the map
            // feeds its settled region to — see ``SearchCompleter``.
            completer: completer,
            mapController: mapController,
            locationManager: appModel.locationManager,
            onClose: closeTrailDraft,
            // A drawn trail lands exactly where a saved recording lands:
            // selected, drawn, and open at its own screen.
            onSaved: showSavedHike
        )
    }
}

// MARK: - The reviewer's two destinations

// An extension rather than more of the struct above, and the reason is the
// length limit doing its job: these two are one subject — where a queue row
// goes — and they are reachable only by somebody the *server* has decided is a
// reviewer, which is almost nobody. Reading them beside the destinations every
// hiker reaches obscured both.
private extension MapSheet {
    /// The review screen, or nothing.
    ///
    /// Guarded on the transport exactly as the preview above is, and
    /// unreachable without one for a second reason: the route that gets here
    /// comes from a queue that only a transport can fill.
    @ViewBuilder
    private func pendingSubmissionDestination(
        _ pending: CommunityPendingSubmission
    ) -> some View {
        if let transport = appModel.communityTransport {
            CommunityReviewView(
                pending: pending,
                transport: transport,
                queue: appModel.communityReview,
                browser: appModel.community,
                // Back to the list the row was on. The row itself is already
                // gone — the screen tells the queue before it pops — so this
                // lands on a list that agrees with the decision just made.
                onFinished: { presentation.path.removeAll() }
            )
        }
    }

    /// The contributed-photo review screen, or nothing.
    ///
    /// Guarded on the transport for the reason the one above is, and
    /// unreachable without one for the same second reason: the route that
    /// gets here comes from a queue only a transport can fill.
    @ViewBuilder
    private func pendingPhotosDestination(
        _ pending: CommunityPendingPhotos
    ) -> some View {
        if let transport = appModel.communityTransport {
            CommunityPhotoReviewView(
                pending: pending,
                transport: transport,
                queue: appModel.communityReview,
                browser: appModel.community,
                onFinished: { presentation.path.removeAll() }
            )
        }
    }
}

// MARK: - Actions

private extension MapSheet {
private func delete(_ hike: Hike, among hikes: [Hike]) {
    // An abandoned draft deletes like any other hike rather than bouncing to
    // the recorder: the screen it would open cannot adopt one — recovery
    // needs a journal this device does not have — so this was the second half
    // of a dead end. See ``Hike/canBeDeletedFromLibrary(currentHikeID:)``.
    guard canDeleteFromLibrary(hike) else {
        openRecording()
        return
    }

    // Everything that has to happen while the hike is still in the store, in
    // the order it has to happen in: auto-save stood down, its offline tiles
    // planned, then the sidecar, the row and the photo files. `HikeDeletion`
    // owns that order and puts all of it back — auto-save included — if the
    // store refuses the save, which is why nothing on screen is touched until
    // it answers: a refusal leaves the sheet exactly as the user left it,
    // showing a hike that is still there.
    guard case let .committed(deletionPlan) = HikeDeletion.delete(
        hike,
        among: hikes,
        autoSave: autoSave,
        // The fourth store this hike may be in. Taken from the recorder
        // because that is where the writer lives — it is the same instance
        // that wrote the workout — and passed rather than reached for inside
        // `HikeDeletion`, which has no composition root to ask.
        workouts: hikeRecorder.workoutWriter
    ) else { return }

    // Clearing the selection stops the *map* drawing a deleted trail; clearing
    // the path stops its detail view staying pushed, showing a hike that no
    // longer exists — stats, elevation chart, and live Offline/Auto-Save
    // controls writing to a detached object nothing will persist. SwiftData
    // detaches rather than invalidates, so it's a stale screen rather than a
    // crash. `SheetRoute.removeHike` owns both, including why the path is
    // cleared unconditionally where the selection is not.
    //
    // Safe to leave until after the save because no body runs in between:
    // this method holds the main actor from the delete to here, and SwiftUI
    // cannot draw the intervening state.
    if SheetRoute.removeHike(hike.id, selectedHike: &selectedHike, from: &presentation.path) {
        highlight.move(to: nil)
    }
    // After the commit: the sidecar column went with the hike, and what is
    // left is the session's memory of it and the pin on the tracker.
    appModel.walkSession.discardWalk(forDeletedHike: hike.id)

    if let deletionPlan {
        // Enumerating a route's tile grid is real CPU work, per download
        // record, for every hike involved — all of it belongs off the
        // main thread.
        Task(priority: .utility) {
            await deletionPlan.removeExclusiveTiles(from: .shared)
        }
    }
}

/// Opens a tapped hike suggestion straight to its detail view.
private func select(_ hike: Hike) {
    searchTask?.cancel()
    searchTask = nil
    searchText = ""
    searchFocused = false
    completer.clear()
    open(hike)
}

/// Opens a tapped published hike: the hiker's own copy of it when they have
/// one, and the preview of a stranger's when they do not.
///
/// The search field is left alone, unlike a tapped hike or place: browsing the
/// community list is a detour rather than an answer, and a hiker who backs out
/// of one of these should find the query they typed still there.
///
/// Through ``SheetPresentation/open(_:importedAs:selectedHike:)`` rather than
/// deciding here, so this row and the map's pins answer the same tap the same
/// way — and, for the preview half, push on the same terms. Appending was the
/// half that did not check: a second tap on a row before the push commits put
/// one listing on the stack twice, and a preview whose twin is still on the
/// stack disposes of nothing when it goes.
private func select(_ listing: CommunityListing, importedAs imported: Hike?) {
    searchFocused = false
    presentation.open(listing, importedAs: imported, selectedHike: &selectedHike)
}

/// Resolves a tapped suggestion to a place and zooms the map to it.
private func select(_ completion: MKLocalSearchCompletion) {
    searchText = completion.title
    searchFocused = false
    completer.commit(query: completion.title)
    startSearch(request: .init(completion: completion), fallbackName: completion.title)
}

/// Geocodes the raw search text (when the user hits Return without picking a
/// suggestion) and zooms the map to the matching region.
private func performSearch() {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    appModel.community.search(matching: query)
    searchFocused = false
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    // The three the suggestions are drawn from — see ``SearchCompleter`` for
    // why a summit or a lake is one of them.
    request.resultTypes = [.address, .pointOfInterest, .physicalFeature]
    // The same bias the completer's suggestions already carry. Without it a
    // typed Return is answered globally while the suggestions above it are
    // answered locally, so the two halves of one search field disagree.
    if let region = completer.region {
        request.region = region
        // `.default` for the reason ``SearchCompleter`` gives: a distant exact
        // match stays reachable.
        request.regionPriority = .default
    }
    startSearch(request: request, fallbackName: query)
}

/// Cancels and invalidates the previous request before starting another.
/// The explicit cancellation check also protects against a MapKit request
/// that finishes after cancellation rather than throwing immediately.
///
/// A failure is reported rather than swallowed. No network, a rate limit or a
/// query MapKit cannot resolve all used to produce the same thing — nothing at
/// all — which reads as a search field that has simply stopped working.
private func startSearch(request: MKLocalSearch.Request, fallbackName: String) {
    searchTask?.cancel()
    searchTask = Task {
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch {
            guard !Task.isCancelled else { return }
            onSearchFailed(SearchFailure(underlying: error))
            return
        }
        guard !Task.isCancelled else { return }
        // An empty response is a successful request with nothing in it, and
        // its `boundingRegion` is not a place — zooming to it would move the
        // map somewhere the user never asked for.
        guard !response.mapItems.isEmpty else {
            onSearchFailed(SearchFailure(reason: .noResults))
            return
        }
        mapController.show(response.boundingRegion)
        // The map moved, so the weather badge moves with it: a hiker who has
        // just zoomed to Budapest is asking about Budapest. Ignored while a
        // recording holds the badge, which `WeatherFocus` decides rather than
        // this call site.
        //
        // The region's centre rather than the first result's coordinate — the
        // badge is about the place the map is now showing, and a search for a
        // city resolves to a region whose centre is the city. MapKit's own
        // name for the first result is preferred over what was typed, so
        // "budapest" is drawn as "Budapest".
        appModel.weatherFocus.focus(
            on: .place(
                response.boundingRegion.center,
                name: response.mapItems.first?.name ?? fallbackName
            )
        )
        // Drop to the detent the map framed the result against.
        presentation.makeRoomForTheMap()
    }
}

/// A method rather than a closure at the call site, so the sheet's content
/// view is constructed from named actions throughout.
private func presentImporter() {
    showImporter = true
}

private func openRecording() {
    SheetRoute.openRecording(
        hike: hikeRecorder.currentHike,
        selectedHike: &selectedHike,
        in: &presentation.path
    )
    highlight.move(to: nil)
    presentation.makeRoomForTheMap()
}

private func closeRecording() {
    presentation.path.removeAll { $0 == .recording }
}

/// Leaves the maker. The draft itself is the maker's to keep or throw away —
/// this only takes the screen down.
private func closeTrailDraft() {
    presentation.path.removeAll { $0 == .trailDraft }
}

private func closeDiscardedRecording(_ hikeID: UUID?) {
    closeRecording()
    if let hikeID, selectedHike?.id == hikeID {
        selectedHike = nil
        highlight.move(to: nil)
    }
}

/// Where a hike this app has just written lands: selected, drawn on the map,
/// and open at its own screen. Shared by a stopped recording and a saved
/// drawing, because the two produce the same thing and should arrive the same
/// way.
private func showSavedHike(_ hike: Hike) {
    selectedHike = hike
    presentation.path = [.hike(hike)]
    presentation.makeRoomForTheMap()
}

/// A hike a published preview has just added to the library.
///
/// Navigated to only while that preview is still the screen in front. The
/// import is unstructured on purpose — a stranger's photographs are still
/// being copied when the hiker may walk away, and that copy is finished
/// rather than abandoned — so its success can arrive after they went Back and
/// opened something else. The hike is saved either way; what is skipped is
/// replacing a newer navigation with an older screen's answer.
private func openImported(_ hike: Hike, from listing: CommunityListing) {
    guard presentation.isShowingCommunityHike(listing) else { return }
    open(hike)
}

private func open(_ hike: Hike) {
    selectedHike = hike
    if belongsToActiveRecording(hike) {
        openRecording()
    } else {
        presentation.path = [.hike(hike)]
    }
}

private func belongsToActiveRecording(_ hike: Hike) -> Bool {
    hike.belongsToActiveRecording(
        currentHikeID: hikeRecorder.currentHike?.id
    )
}

private func canDeleteFromLibrary(_ hike: Hike) -> Bool {
    hike.canBeDeletedFromLibrary(
        currentHikeID: hikeRecorder.currentHike?.id
    )
}
}
