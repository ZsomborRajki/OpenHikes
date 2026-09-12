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

    @Binding var searchText: String
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

    var onImportGPX: (URL) -> Void = { _ in /* no-op default */ }
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
    @State private var showAreaPicker = false
    @State private var locationUnavailable = false
    @State private var completer = SearchCompleter()
    @State private var searchTask: Task<Void, Never>?

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
        RenderSignpost.mark("MapSheetBody")
        return NavigationStack(path: presentation.pathBinding) {
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

                searchControls

                MapSheetHikes(
                    searchText: searchText,
                    isSearchFocused: searchFocused,
                    searchSession: appModel.searchSession,
                    isCompact: presentation.isCompact,
                    completer: completer,
                    recorder: hikeRecorder,
                    walkSession: appModel.walkSession,
                    community: appModel.community,
                    selectedHikeID: selectedHike?.id,
                    onOpen: open,
                    onSelectResult: select,
                    onSelectCompletion: select,
                    onFindCommunity: findCommunity,
                    onFindCommunityQuery: findCommunityQuery,
                    onSelectListing: select,
                    onDelete: delete,
                    onRecord: openRecording,
                    onImport: presentImporter
                )
                    // The list of every hike, rebuilt only when one of the
                    // values above actually differs. Without this it is rebuilt
                    // whenever this body runs, because the action closures are
                    // new objects every pass — which made a photo tap three
                    // screens away redraw every row on the map screen.
                    .equatable()
            }
            .navigationDestination(for: SheetRoute.self, destination: navigationDestinationView)
            #if os(iOS)
            // Set the title mode at the stack level so it's resolved before
            // any push — avoids the large-title bar expanding/flicking in.
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .accessibilityIdentifier("map-sheet")
        // Presented from inside the sheet so it isn't blocked by the sheet's
        // own presentation context.
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.gpxContentTypes) { result in
            switch result {
            case let .success(url): onImportGPX(url)
            // Rare — the picker couldn't hand over the file at all — but
            // dropping it here would be the same silent no-op the import path
            // itself was just fixed for. From the user's side it's the same
            // story as an unreadable file, so it's told the same way.
            case .failure: onImportFailed()
            }
        }
        // Also presented from inside the sheet so it layers above it.
        .sheet(isPresented: $showSettings) {
            SettingsView(
                autoSave: appModel.autoSaveController,
                backgroundTracker: appModel.backgroundTracker,
                blocks: appModel.communityBlocks,
                cloudSync: appModel.cloudSync,
                entitlement: appModel.entitlement
            )
        }
        .sheet(isPresented: $showAreaPicker) {
            CommunityPlacePicker { region, name in
                showAreaPicker = false
                commitCommunityPlace(region, name: name, clearQuery: false)
            }
        }
        .alert("Location unavailable", isPresented: $locationUnavailable) {
            Button("Choose a place") { showAreaPicker = true }
            Button("Cancel", role: .cancel) { /* Keep the selected area. */ }
        } message: {
            Text("Your current location isn't available. Enable location access in Settings, or choose a place.")
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

    @ViewBuilder private var searchControls: some View {
        if !presentation.isCompact {
            MapSearchControls(
                session: appModel.searchSession,
                community: appModel.community,
                onScopeChange: changeScope,
                onAreaChoice: chooseArea,
                onChoosePlace: { searchFocused = false; showAreaPicker = true }
            )
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search hikes and places", text: $searchText)
                .minimumTapTarget()
                .accessibilityIdentifier("map-search")
                .focused($searchFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(performSearch)
                .onChange(of: searchText) { _, value in
                    guard !appModel.searchSession.consumesProgrammaticChange(value) else { return }
                    searchTask?.cancel()
                    appModel.searchSession.showsResults = true
                    updateSearch(value)
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
                        .minimumTapTarget()
                }
                .buttonStyle(.plain)
                // The glyph above is the button's only content and is hidden,
                // which left this announcing itself as an unnamed button.
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("clear-search-button")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        // A capsule rather than a 12pt rounded rectangle: a search field is a
        // capsule everywhere in iOS 26, and it is what lets the circular
        // settings button beside it read as the same family of control.
        .glassSurface(.regular, in: .capsule)
    }

    /// Profile/settings entry point, sitting to the right of the search field —
    /// like Apple Maps' account button.
    ///
    /// The circular glass here is the real button style rather than a glass
    /// background under a `.plain` button, so it picks up the press and
    /// morph response the style draws and the search field's chrome cannot.
    private var settingsButton: some View {
        Button {
            searchFocused = false
            showSettings = true
        } label: {
            Image(systemName: "person.crop.circle")
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
                // `open` assigns the whole path rather than appending to it, so
                // the preview is replaced rather than left underneath — which
                // is what should happen: backing out of a hike that is now in
                // the library, into a screen offering to add it, describes a
                // decision already made.
                onImport: open,
                // Back to the list, which the block has already taken this hike
                // out of — ``CommunityBrowser`` filters on read, so the row is
                // gone by the time the pop lands. The refresh is for the case
                // where it took *every* row with it.
                onBlock: {
                    appModel.community.refreshAfterBlock()
                    presentation.path.removeAll()
                }
            )
        }
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
                communityTransport: appModel.communityTransport,
                onOpenPhoto: { photo in presentation.path.append(.photo(hike, photo.id)) },
                onOpenWalk: { walk in presentation.path.append(.walk(walk)) },
                onZoomToRoute: { withAnimation { presentation.detent = .medium } },
                interaction: presentation.hikeInteraction(for: hike)
            )
        case let .communityHike(listing):
            communityHikeDestination(listing)
        case .recording:
            RecordingView(
                recorder: appModel.hikeRecorder,
                mapController: mapController,
                photoCapture: photoCapture,
                photoPins: photoPins,
                onSaved: showSavedRecording,
                onDiscarded: closeDiscardedRecording,
                onOpenPhoto: { hike, photo in
                    presentation.path.append(.photo(hike, photo.id))
                }
            )
        case let .photo(hike, photoID):
            HikePhotoViewer(
                hike: hike,
                startID: photoID,
                highlight: highlight,
                mapController: mapController,
                onShowOnMap: presentation.collapseWhenFullHeightScreenPops,
                selection: presentation.photoSelection(for: route)
            )
        case let .walk(walk):
            WalkSummaryView(
                walk: walk,
                walkHighlight: walkHighlight,
                mapController: mapController,
                onShowOnMap: { withAnimation { presentation.detent = .medium } }
            )
        }
    }
}

// MARK: - Actions

private extension MapSheet {
private func delete(_ hike: Hike, among hikes: [Hike]) {
    guard !belongsToActiveRecording(hike) else {
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
        autoSave: autoSave
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
    searchFocused = false
    open(hike)
}

/// Pushes a published hike's preview, so it can be looked at before it is
/// imported.
///
/// The search field is left alone: this push is
/// a detour rather than an answer, and a walker who backs out of a preview
/// should find the query they typed still there.
private func select(_ listing: CommunityListing) {
    searchTask?.cancel()
    searchTask = nil
    searchFocused = false
    presentation.path.append(.communityHike(listing))
}

/// Resolves a tapped suggestion to a place and zooms the map to it.
private func select(_ completion: MKLocalSearchCompletion) {
    setSearchText(completion.title)
    searchFocused = false
    completer.commit(query: completion.title)
    startSearch(request: .init(completion: completion), fallbackName: completion.title)
}

/// Submit keeps hike results visible. Only the Places scope resolves and moves the map.
private func performSearch() {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    searchFocused = false
    appModel.searchSession.showsResults = true
    if appModel.searchSession.scope == .places {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        startSearch(request: request, fallbackName: query)
    } else {
        updateSearch(query)
    }
}

/// Cancels and invalidates the previous request before starting another.
/// The explicit cancellation check also protects against a MapKit request
/// that finishes after cancellation rather than throwing immediately.
///
/// A failure is reported rather than swallowed. No network, a rate limit or a
/// query MapKit cannot resolve all used to produce the same thing — nothing at
/// all — which reads as a search field that has simply stopped working.
private func startSearch(request: MKLocalSearch.Request, fallbackName: String, community: Bool = false) {
    searchTask?.cancel()
    searchTask = Task {
        do {
            let place = try await SearchPlace.resolve(request, fallbackName: fallbackName)
            try Task.checkCancellation()
            if community {
                commitCommunityPlace(place.region, name: place.name, clearQuery: true)
            } else {
                appModel.searchSession.showsResults = false
                showPlace(place.region, name: place.name)
            }
        } catch {
            guard !Task.isCancelled else { return }
            onSearchFailed(error as? SearchFailure ?? SearchFailure(underlying: error))
        }
    }
}

private func updateSearch(_ query: String) {
    let scope = appModel.searchSession.scope
    if scope == .yourHikes { completer.clear() } else { completer.update(query: query) }
    appModel.community.search(
        matching: scope.includesCommunity ? query : "",
        inSelectedArea: scope == .community
    )
}

private func changeScope(_ scope: MapSearchScope) {
    searchTask?.cancel()
    appModel.searchSession.scope = scope
    appModel.searchSession.showsResults = true
    updateSearch(searchText)
    if scope == .community { appModel.community.startBrowsing() } else { appModel.community.stopBrowsing() }
}

private func chooseArea(_ choice: CommunityAreaChoice) {
    searchTask?.cancel()
    if choice == .nearMe {
        // Read once in the action. The sheet body never observes live GPS.
        guard let coordinate = appModel.locationManager.coordinate else {
            locationUnavailable = true
            return
        }
        let diameter = CommunityQueryPolicy.minimumRadiusMeters * 2
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: diameter, longitudinalMeters: diameter)
        appModel.community.selectArea(.nearMe, region: region)
        showPlace(region, name: String(localized: "Near me"))
    } else {
        appModel.community.selectArea(choice)
    }
}

private func findCommunity(_ completion: MKLocalSearchCompletion) {
    searchFocused = false
    startSearch(request: .init(completion: completion), fallbackName: completion.title, community: true)
}

private func findCommunityQuery() {
    searchFocused = false
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = searchText
    startSearch(request: request, fallbackName: searchText, community: true)
}

private func commitCommunityPlace(_ region: MKCoordinateRegion, name: String, clearQuery: Bool) {
    if clearQuery { setSearchText(""); completer.clear() }
    appModel.searchSession.scope = .community
    appModel.searchSession.showsResults = true
    appModel.community.selectArea(.place(name), region: region)
    updateSearch(searchText)
    appModel.community.startBrowsing()
    showPlace(region, name: name)
}

private func setSearchText(_ value: String) {
    if searchText != value {
        appModel.searchSession.programmaticQuery = value
        searchText = value
    }
}

private func showPlace(_ region: MKCoordinateRegion, name: String) {
    mapController.show(region)
    appModel.weatherFocus.focus(on: .place(region.center, name: name))
    withAnimation { presentation.detent = .medium }
}

/// GPX has no system-declared UTType; the app imports topografix's, which
/// is what makes the lookup below resolve. XML stays as a fallback for a
/// track exported under a different extension.
private static var gpxContentTypes: [UTType] {
    var types: [UTType] = []
    if let gpx = UTType(filenameExtension: "gpx") { types.append(gpx) }
    types.append(.xml)
    return types
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
    withAnimation { presentation.detent = .medium }
}

private func closeRecording() {
    presentation.path.removeAll { $0 == .recording }
}

private func closeDiscardedRecording(_ hikeID: UUID?) {
    closeRecording()
    if let hikeID, selectedHike?.id == hikeID {
        selectedHike = nil
        highlight.move(to: nil)
    }
}

private func showSavedRecording(_ hike: Hike) {
    selectedHike = hike
    presentation.path = [.hike(hike)]
    withAnimation { presentation.detent = .medium }
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
}
