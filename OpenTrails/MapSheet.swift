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
    var highlight: RouteHighlight
    var mapController: MapController
    var autoSave: AutoSaveController

    var onRecord: () -> Void = {}
    var onImportGPX: (URL) -> Void = { _ in }
    /// Reports the sheet's top edge (global Y) as it's dragged, so the map can
    /// keep the "my location" button riding just above the sheet.
    var onSheetTopChange: (CGFloat) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Hike.date, order: .reverse) private var hikes: [Hike]
    @FocusState private var searchFocused: Bool
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var path = NavigationPath()
    @State private var completer = SearchCompleter()

    /// True while the search field is active and has suggestions to offer.
    private var isSearching: Bool { searchFocused && !completer.suggestions.isEmpty }

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
            if case let .success(url) = result { onImportGPX(url) }
        }
        // Also presented from inside the sheet so it layers above it.
        .sheet(isPresented: $showSettings) {
            SettingsView()
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

    /// Always-visible icon buttons for starting a recording or importing a GPX.
    private var hikeActions: some View {
        HStack(spacing: 8) {
            Button(action: onRecord) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular, in: Circle())
            }
            .accessibilityLabel("Record new hike")

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

    /// Hikes with "spring" in the title are pinned to the top; the rest keep the
    /// query's newest-first order.
    private var sortedHikes: [Hike] {
        let keyword = "spring"
        let pinned = hikes.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
        let rest = hikes.filter { !$0.title.localizedCaseInsensitiveContains(keyword) }
        return pinned + rest
    }

    private var hikesList: some View {
        List {
            ForEach(sortedHikes) { hike in
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
        if hike.id == selectedHike?.id {
            selectedHike = nil
            highlight.coordinate = nil
        }
        // Free any tiles this hike had saved offline before it goes away. The
        // key computation is real CPU work (tile-grid enumeration per download
        // record), so it happens inside the detached task, not here.
        let route = hike.route
        let offlineDownloads = hike.offlineDownloads
        let autoSavedTileKeys = hike.autoSavedTileKeys
        if !offlineDownloads.isEmpty || !autoSavedTileKeys.isEmpty {
            Task.detached {
                let coordinates = route.map(\.clCoordinate)
                let keys = Array(
                    Set(OfflineTileDownloader.storedTileKeys(route: coordinates, offlineDownloads: offlineDownloads))
                        .union(autoSavedTileKeys)
                )
                TileCache.shared.removeTiles(forKeys: keys)
            }
        }
        modelContext.delete(hike)
    }

    /// Autocomplete suggestions shown under the search field while typing.
    private var suggestionsList: some View {
        List(completer.suggestions, id: \.self) { suggestion in
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
            Text("Tap \(recordIcon) to record or \(importIcon) to import a GPX file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // Interpolated into `emptyState`'s Text as `Text` values (not plain
    // strings), so each keeps its own icon color inside the sentence.
    private var recordIcon: Text {
        Text(Image(systemName: "record.circle")).foregroundStyle(.red)
    }

    private var importIcon: Text {
        Text(Image(systemName: "square.and.arrow.down")).foregroundStyle(.tint)
    }
}

private struct HikeRow: View {
    let hike: Hike
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: hike.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(hike.tintOpaque, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(hike.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(hike.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(hike.tintOpaque) : AnyShapeStyle(.tertiary))
        }
    }
}
