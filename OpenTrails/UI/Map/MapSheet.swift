//
//  MapSheet.swift
//  OpenTrails
//
//  Apple Maps–style persistent bottom sheet. Starts with a search field,
//  and surfaces a Hikes section once expanded past the compact detent.
//

import SwiftUI
import SwiftData
import MapKit
import UniformTypeIdentifiers

struct MapSheet: View {
    @Binding var searchText: String
    @Binding var detent: PresentationDetent
    @Binding var selectedHike: Hike?
    /// Owned by `ContentView` rather than this view, so a widget tap can push
    /// a hike's detail view from outside the sheet. Typed as `[Hike]` (not
    /// `NavigationPath`) because the caller has to be able to ask what's
    /// already on screen before deciding to navigate — `NavigationPath` can
    /// be appended to but never read back.
    @Binding var path: [Hike]
    var highlight: RouteHighlight
    var mapController: MapController
    var autoSave: AutoSaveController
    var locationManager: LocationManager
    var backgroundTracker: BackgroundTrailTracker

    var onImportGPX: (URL) -> Void = { _ in }
    /// The document picker failed to produce a file at all.
    var onImportFailed: () -> Void = {}
    /// Reports the sheet's top edge (global Y) as it's dragged, so the map can
    /// keep the "my location" button riding just above the sheet.
    var onSheetTopChange: (CGFloat) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Hike.date, order: .reverse) private var hikes: [Hike]
    @FocusState private var searchFocused: Bool
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var completer = SearchCompleter()

    /// True while the search field is active and has suggestions to offer.
    private var isSearching: Bool {
        searchFocused && (!completer.suggestions.isEmpty || !matchingHikes.isEmpty)
    }

    /// Imported/recorded hikes whose title matches the current query, with
    /// titles that start with the query ranked above ones that merely contain
    /// it — surfaced above map suggestions so a user's own trails come first.
    private var matchingHikes: [Hike] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return hikes
            .filter { $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { lhs, rhs in
                let lhsPrefix = lhs.title.range(of: query, options: [.caseInsensitive, .anchored]) != nil
                let rhsPrefix = rhs.title.range(of: query, options: [.caseInsensitive, .anchored]) != nil
                if lhsPrefix != rhsPrefix { return lhsPrefix }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    /// True at the smallest detent, where only the search field shows.
    private var isCompact: Bool { detent == .height(80) }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    searchField
                    settingsButton
                }
                    .padding(.horizontal)
                    .padding(.top, 18)

                if isSearching {
                    suggestionsList
                        .padding(.top, 12)
                } else if isCompact {
                    Spacer()
                } else {
                    hikesSection
                        .padding(.top, 24)
                }
            }
            .navigationDestination(for: Hike.self) { hike in
                HikeDetailView(
                    hike: hike,
                    highlight: highlight,
                    mapController: mapController,
                    autoSave: autoSave,
                    locationManager: locationManager,
                    backgroundTracker: backgroundTracker,
                    onZoomToRoute: { withAnimation { detent = .medium } }
                )
            }
            #if os(iOS)
            // Set the title mode at the stack level so it's resolved before
            // any push — avoids the large-title bar expanding/flicking in.
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
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
            SettingsView(autoSave: autoSave, backgroundTracker: backgroundTracker)
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
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search Maps", text: $searchText)
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
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
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
                .glassEffect(.regular, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile and settings")
    }

    private var hikesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Hikes")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Spacer()
                hikeActions
            }
            .padding(.horizontal)

            if hikes.isEmpty {
                emptyState
                    .padding(.horizontal)
                Spacer()
            } else {
                hikesList
            }
        }
    }

    /// Always-visible icon button for importing a GPX.
    ///
    /// A record button sat beside this one, fully styled and tappable, wired to
    /// an empty function — the one thing worse than an app that can't record a
    /// hike is one that appears to and then doesn't. It comes back when there's
    /// a recording session behind it.
    private var hikeActions: some View {
        HStack(spacing: 8) {
            Button {
                showImporter = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular, in: Circle())
            }
            .accessibilityLabel("Import GPX file")
        }
        .font(.title3)
        .buttonStyle(.plain)
    }

    private var hikesList: some View {
        List {
            ForEach(hikes) { hike in
                Button {
                    selectedHike = hike
                    path.append(hike)
                } label: {
                    HikeRow(hike: hike, isSelected: hike.id == selectedHike?.id)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    hike.id == selectedHike?.id ? hike.tintOpaque.opacity(0.15) : Color.clear
                )
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        delete(hike)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func delete(_ hike: Hike) {
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

        // Free the tiles this hike had saved offline — but only the ones no
        // surviving hike still claims. Cache keys carry no hike identity, so
        // deleting this hike's keys outright would strip coverage from any
        // trail sharing the area (and at low zoom, that's most of them) while
        // leaving their manifests claiming tiles that are gone.
        let doomed = TileOwnership(hike)
        if doomed.hasStoredTiles {
            let survivors = hikes
                .filter { $0.id != hike.id && $0.hasStoredTiles }
                .map(TileOwnership.init)
            // Enumerating a route's tile grid is real CPU work, per download
            // record, for every hike involved — all of it belongs off the
            // main thread.
            Task.detached {
                let keys = doomed.exclusiveTileKeys(against: survivors)
                guard !keys.isEmpty else { return }
                TileCache.shared.removeTiles(forKeys: Array(keys))
            }
        }

        modelContext.delete(hike)
    }

    /// Autocomplete suggestions shown under the search field while typing.
    /// Matching hikes (imported or recorded) are listed first, ahead of
    /// MapKit's place suggestions.
    private var suggestionsList: some View {
        List {
            if !matchingHikes.isEmpty {
                Section("Your Hikes") {
                    ForEach(matchingHikes) { hike in
                        Button {
                            select(hike)
                        } label: {
                            HikeRow(hike: hike, isSelected: hike.id == selectedHike?.id)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !completer.suggestions.isEmpty {
                Section {
                    ForEach(completer.suggestions, id: \.self) { suggestion in
                        Button {
                            select(suggestion)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title)
                                        .foregroundStyle(.primary)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    if !matchingHikes.isEmpty {
                        Text("Maps")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Opens a tapped hike suggestion straight to its detail view.
    private func select(_ hike: Hike) {
        searchText = ""
        searchFocused = false
        completer.clear()
        selectedHike = hike
        path.append(hike)
    }

    /// Resolves a tapped suggestion to a place and zooms the map to it.
    private func select(_ completion: MKLocalSearchCompletion) {
        searchText = completion.title
        searchFocused = false
        completer.clear()
        Task {
            guard let response = try? await MKLocalSearch(request: .init(completion: completion)).start() else { return }
            mapController.show(response.boundingRegion)
            withAnimation { detent = .medium }
        }
    }

    /// Geocodes the raw search text (when the user hits Return without picking a
    /// suggestion) and zooms the map to the matching region.
    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchFocused = false
        Task {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            guard let response = try? await MKLocalSearch(request: request).start() else { return }
            mapController.show(response.boundingRegion)
            // Drop to a partial detent so the zoomed map is visible.
            withAnimation { detent = .medium }
        }
    }

    /// GPX has no first-party UTType; match by extension and fall back to XML.
    private static var gpxContentTypes: [UTType] {
        var types: [UTType] = []
        if let gpx = UTType(filenameExtension: "gpx") { types.append(gpx) }
        types.append(.xml)
        return types
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "map")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No hikes yet")
                .font(.headline)
            Text("Tap \(importIcon) to import a GPX file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // Interpolated into `emptyState`'s Text as a `Text` value (not a plain
    // string), so the icon keeps its own color inside the sentence.
    private var importIcon: Text {
        Text(Image(systemName: "square.and.arrow.down")).foregroundStyle(.tint)
    }
}

