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
    private static let compactDetentHeight: CGFloat = 80
    private static let topPadding: CGFloat = 18
    private static let selectedHikeHighlightOpacity: Double = 0.15

    @Binding var searchText: String
    @Binding var detent: PresentationDetent
    @Binding var selectedHike: Hike?
    /// Owned by `OpenHikesView` rather than this view, so a widget tap can push
    /// a hike's detail view from outside the sheet. Typed as `[SheetRoute]` (not
    /// `NavigationPath`) because the caller has to be able to ask what's
    /// already on screen before deciding to navigate — `NavigationPath` can
    /// be appended to but never read back.
    @Binding var path: [SheetRoute]
    var highlight: RouteHighlight
    var mapController: MapController

    var onImportGPX: (URL) -> Void = { _ in /* no-op default */ }
    /// The document picker failed to produce a file at all.
    var onImportFailed: () -> Void = { /* no-op default */ }
    /// Reports the sheet's top edge (global Y) as it's dragged, so the map can
    /// keep the "my location" button riding just above the sheet.
    var onSheetTopChange: (CGFloat) -> Void = { _ in /* no-op default */ }

    @Environment(OpenHikesModel.self)
    private var appModel
    @Environment(\.modelContext)
    private var modelContext
    @FocusState private var searchFocused: Bool
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var completer = SearchCompleter()
    @State private var searchTask: Task<Void, Never>?

    private var autoSave: AutoSaveController {
        appModel.autoSaveController
    }

    private var hikeRecorder: HikeRecorder {
        appModel.hikeRecorder
    }

    /// True at the smallest detent, where only the search field shows.
    private var isCompact: Bool { detent == .height(Self.compactDetentHeight) }

    var body: some View {
        // Deliberately reads no `Hike`. This body runs on every detent change
        // a sheet drag produces, and it is also the `NavigationStack` the hike
        // detail view — with its touch-frequency tint and width sliders — is
        // pushed into. `MapSheetHikes` holds the `@Query`, which has no
        // per-property granularity, so keeping it out of here is what stops a
        // slider drag re-evaluating the search field and the navigation stack.
        RenderSignpost.mark("MapSheetBody")
        return NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    searchField
                    settingsButton
                }
                    .padding(.horizontal)
                    .padding(.top, Self.topPadding)

                MapSheetHikes(
                    searchText: searchText,
                    isSearchFocused: searchFocused,
                    isCompact: isCompact,
                    completer: completer,
                    recorder: hikeRecorder,
                    selectedHikeID: selectedHike?.id,
                    onOpen: open,
                    onSelectResult: select,
                    onSelectCompletion: select,
                    onDelete: delete,
                    onRecord: openRecording,
                    onImport: presentImporter
                )
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
                backgroundTracker: appModel.backgroundTracker
            )
        }
        // Focusing the search field expands the sheet to full height.
        .onChange(of: searchFocused) { _, focused in
            if focused {
                withAnimation { detent = .large }
            }
        }
        // Collapsing below full height (e.g. dragging to medium) drops focus.
        .onChange(of: detent) { _, newValue in
            if newValue != .large {
                searchFocused = false
            }
        }
        // Track the sheet's top edge continuously (including during interactive
        // drags) and hand it to the map so it can position the location button.
        .onTopEdgeChange(perform: onSheetTopChange)
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

            TextField("Search Maps", text: $searchText)
                .accessibilityIdentifier("map-search")
                .focused($searchFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(performSearch)
                .onChange(of: searchText) { _, value in completer.update(query: value) }
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
        .sheetGlassBackground(in: RoundedRectangle(cornerRadius: 12))
    }

    /// Profile/settings entry point, sitting to the right of the search field —
    /// like Apple Maps' account button.
    private var settingsButton: some View {
        Button {
            searchFocused = false
            showSettings = true
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .sheetGlassBackground(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile and settings")
        .accessibilityIdentifier("settings-button")
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
                locationManager: appModel.locationManager,
                backgroundTracker: appModel.backgroundTracker,
                trailGraphProvider: appModel.trailGraphProvider
            ) { withAnimation { detent = .medium } }
        case .recording:
            RecordingView(
                recorder: appModel.hikeRecorder,
                mapController: mapController,
                onSaved: showSavedRecording,
                onDiscarded: closeDiscardedRecording
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

    // Before anything else: tiles auto-saved in the last couple of seconds
    // live only in AutoSaveTileStore's pending set. Folding them into the
    // manifest first is what stops them outliving the hike with nothing
    // pointing at them — and stopping auto-save here, rather than waiting
    // for the selection change below to make its way back through SwiftUI,
    // closes the window where a tile still in flight lands on disk claimed
    // by a hike that no longer exists.
    autoSave.hikeWillBeDeleted(hike)

    if hike.id == selectedHike?.id {
        selectedHike = nil
        highlight.move(to: nil)
    }

    // The same treatment for the navigation stack, which drives
    // `navigationDestination(for: SheetRoute.self)` off this very array. Clearing
    // the selection stops the *map* drawing a deleted trail; without this
    // its detail view stays pushed, showing a hike that no longer exists —
    // stats, elevation chart, and live Offline/Auto-Save controls writing
    // to a detached object nothing will persist. SwiftData detaches rather
    // than invalidates, so it's a stale screen rather than a crash.
    //
    // Unconditional, unlike the selection check above: a widget deep link
    // pushes onto this path directly, so "pushed" and "selected" aren't
    // guaranteed to be the same hike.
    path.removeAll { route in
        if case let .hike(pushedHike) = route {
            pushedHike.id == hike.id
        } else {
            false
        }
    }

    // Free the tiles this hike had saved offline — but only the ones no
    // surviving hike still claims. Cache keys carry no hike identity, so
    // deleting this hike's keys outright would strip coverage from any
    // trail sharing the area (and at low zoom, that's most of them) while
    // leaving their manifests claiming tiles that are gone.
    if hike.hasStoredTiles {
        let deletionPlan = StoredTileDeletionPlan(removing: hike, among: hikes)
        // Enumerating a route's tile grid is real CPU work, per download
        // record, for every hike involved — all of it belongs off the
        // main thread.
        Task(priority: .utility) {
            await deletionPlan.removeExclusiveTiles(from: .shared)
        }
    }

    modelContext.delete(hike)
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

/// Resolves a tapped suggestion to a place and zooms the map to it.
private func select(_ completion: MKLocalSearchCompletion) {
    searchText = completion.title
    searchFocused = false
    completer.clear()
    startSearch(request: .init(completion: completion))
}

/// Geocodes the raw search text (when the user hits Return without picking a
/// suggestion) and zooms the map to the matching region.
private func performSearch() {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    searchFocused = false
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    startSearch(request: request)
}

/// Cancels and invalidates the previous request before starting another.
/// The explicit cancellation check also protects against a MapKit request
/// that finishes after cancellation rather than throwing immediately.
private func startSearch(request: MKLocalSearch.Request) {
    searchTask?.cancel()
    searchTask = Task {
        guard let response = try? await MKLocalSearch(request: request).start(),
              !Task.isCancelled else { return }
        mapController.show(response.boundingRegion)
        // Drop to a partial detent so the zoomed map is visible.
        withAnimation { detent = .medium }
    }
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
        in: &path
    )
    highlight.move(to: nil)
    withAnimation { detent = .medium }
}

private func closeRecording() {
    path.removeAll { $0 == .recording }
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
    path = [.hike(hike)]
    withAnimation { detent = .medium }
}

private func open(_ hike: Hike) {
    selectedHike = hike
    if belongsToActiveRecording(hike) {
        openRecording()
    } else {
        path = [.hike(hike)]
    }
}

private func belongsToActiveRecording(_ hike: Hike) -> Bool {
    hike.belongsToActiveRecording(
        currentHikeID: hikeRecorder.currentHike?.id
    )
}
}

/// Shared by the sheet's own chrome and by ``MapSheetHikes``, which is why it
/// is not fileprivate.
extension View {
    @ViewBuilder
    func sheetGlassBackground<S: Shape>(in shape: S) -> some View {
        #if os(visionOS)
        background(.regularMaterial, in: shape)
        #else
        glassEffect(.regular, in: shape)
        #endif
    }
}
