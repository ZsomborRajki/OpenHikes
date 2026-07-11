//
//  MapSheet.swift
//  OpenTrails
//
//  Apple Maps–style persistent bottom sheet. Starts with a search field,
//  and surfaces a Hikes section once expanded past the compact detent.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct MapSheet: View {
    @Binding var searchText: String
    @Binding var detent: PresentationDetent
    @Binding var selectedHike: Hike?
    var highlight: RouteHighlight

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

                if isCompact {
                    Spacer()
                } else {
                    hikesSection
                        .padding(.top, 24)
                }
            }
            .navigationDestination(for: Hike.self) { hike in
                HikeDetailView(hike: hike, highlight: highlight)
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
            Text("Hikes")
                .font(.title2.bold())
                .foregroundStyle(.primary)
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
                    hike.id == selectedHike?.id ? hike.tint.opacity(0.15) : Color.clear
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
        modelContext.delete(hike)
    }

    /// GPX has no first-party UTType; match by extension and fall back to XML.
    private static var gpxContentTypes: [UTType] {
        var types: [UTType] = []
        if let gpx = UTType(filenameExtension: "gpx") { types.append(gpx) }
        types.append(.xml)
        return types
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Button(action: onRecord) {
                Label("Record New Hike", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                showImporter = true
            } label: {
                Label("Import GPX File", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .padding(.top, 4)
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
                .background(hike.tint, in: Circle())

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
                .foregroundStyle(isSelected ? AnyShapeStyle(hike.tint) : AnyShapeStyle(.tertiary))
        }
    }
}
