//
//  MapSheetHikes.swift
//  OpenHikes
//
//  Everything in the sheet that reads a `Hike`, and nothing that doesn't.
//
//  The split is not cosmetic. `@Query` has no per-property granularity: it
//  invalidates on *any* write to the queried type, including fields nothing on
//  screen renders. The hike detail view is pushed into this sheet's own
//  `NavigationStack`, and its line-width and tint sliders write straight to the
//  model at touch frequency — so while the query lived in `MapSheet`, dragging
//  one re-evaluated the search field, the settings button, the file importer,
//  the settings sheet and the navigation stack along with it.
//
//  Holding the query down here bounds that to the rows that actually draw a
//  hike. `SheetQueryIsolationTests` measures both halves of the claim.
//

import MapKit
import SwiftData
import SwiftUI

struct MapSheetHikes: View {
    private static let selectedHikeHighlightOpacity: Double = 0.15

    @Query(sort: \Hike.date, order: .reverse)
    private var hikes: [Hike]
    /// Keeps the matching-hike ranking across body passes — see ``HikeSearch``.
    @State private var hikeSearch = HikeSearch()

    let searchText: String
    let isSearchFocused: Bool
    /// True at the smallest detent, where only the search field shows.
    let isCompact: Bool
    var completer: SearchCompleter
    var recorder: HikeRecorder
    let selectedHikeID: UUID?
    let onOpen: (Hike) -> Void
    /// A hike tapped in the search results: the caller clears the field and
    /// drops focus before opening it.
    let onSelectResult: (Hike) -> Void
    let onSelectCompletion: (MKLocalSearchCompletion) -> Void
    /// The surviving hikes are handed over with the doomed one because freeing
    /// its tiles means asking which of them are still claimed elsewhere.
    let onDelete: (Hike, [Hike]) -> Void
    let onRecord: () -> Void
    let onImport: () -> Void

    var body: some View {
        // The ranking below is the only real work here. Two things keep it off
        // the sheet-drag path: the results can only be shown while the field is
        // focused, so an unfocused pass doesn't rank at all — and a focused
        // pass reuses the last ranking unless the query or the hikes
        // themselves changed.
        //
        // This is where SwiftData's `@Query` lands, and a query has no
        // per-property granularity: any write to any `Hike` re-runs it. The
        // mark is how a recording that writes to its draft hike per fix would
        // show up — as this body ticking at fix rate.
        RenderSignpost.mark(
            "MapSheetHikesBody",
            "\(hikes.count) hikes searching=\(isSearchFocused)"
        )
        let matchingHikes = isSearchFocused ? hikeSearch.rankedHikes(matching: searchText, in: hikes) : []
        let isSearching = isSearchFocused && (!completer.suggestions.isEmpty || !matchingHikes.isEmpty)

        return Group {
            if isSearching {
                suggestionsList(matchingHikes: matchingHikes)
                    .padding(.top, 12)
            } else if isCompact {
                Spacer()
            } else {
                hikesSection
                    .padding(.top, 24)
            }
        }
        .onChange(of: isSearchFocused) { _, focused in
            // Nothing ranks while the field is unfocused, so there is no
            // cached ranking worth keeping — and holding one would keep every
            // matched hike alive behind a search nobody is running.
            if !focused { hikeSearch.clear() }
        }
    }
}

// MARK: - Hikes list

private extension MapSheetHikes {
    var hikesSection: some View {
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

    /// Always-visible recording and GPX import actions.
    var hikeActions: some View {
        HStack(spacing: 8) {
            #if os(iOS)
            Button {
                Task {
                    if !recorder.isActive {
                        await recorder.start()
                    }
                    onRecord()
                }
            } label: {
                Image(
                    systemName: recorder.isActive
                        ? "stop.circle.fill"
                        : "record.circle"
                )
                    .foregroundStyle(.red)
                    .frame(width: 40, height: 40)
                    .sheetGlassBackground(in: Circle())
            }
            .accessibilityLabel(
                recorder.isActive
                    ? "Open hike recording"
                    : "Record a hike"
            )
            .accessibilityIdentifier("record-hike-button")
            #endif

            Button {
                onImport()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .sheetGlassBackground(in: Circle())
            }
            .accessibilityLabel("Import GPX file")
            .accessibilityIdentifier("import-gpx-button")
        }
        .font(.title3)
        .buttonStyle(.plain)
    }

    var hikesList: some View {
        List {
            ForEach(hikes) { hike in
                Button {
                    onOpen(hike)
                } label: {
                    HikeRow(
                        hike: hike,
                        isSelected: hike.id == selectedHikeID,
                        status: recordingStatus(for: hike)
                    )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    hike.id == selectedHikeID
                        ? hike.tintOpaque.opacity(Self.selectedHikeHighlightOpacity)
                        : Color.clear
                )
                .swipeActions(edge: .trailing) {
                    if !belongsToActiveRecording(hike) {
                        Button(role: .destructive) {
                            onDelete(hike, hikes)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "map")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No hikes yet")
                .font(.headline)
            Text("Tap \(importIcon) to import a GPX file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            #if os(iOS)
            Text("Or tap \(recordIcon) to record one as you walk.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            #endif
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // Interpolated into `emptyState`'s Text as a `Text` value (not a plain
    // string), so the icon keeps its own color inside the sentence.
    var importIcon: Text {
        Text(Image(systemName: "square.and.arrow.down")).foregroundStyle(.tint)
    }

    var recordIcon: Text {
        Text(Image(systemName: "record.circle")).foregroundStyle(.red)
    }
}

// MARK: - Search results

private extension MapSheetHikes {
    /// Autocomplete suggestions shown under the search field while typing.
    /// Matching hikes (imported or recorded) are listed first, ahead of
    /// MapKit's place suggestions.
    func suggestionsList(matchingHikes: [Hike]) -> some View {
        List {
            hikeSuggestionsSection(matchingHikes: matchingHikes)
            mapSuggestionsSection(matchingHikes: matchingHikes)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    func hikeSuggestionsSection(matchingHikes: [Hike]) -> some View {
        if !matchingHikes.isEmpty {
            Section("Your Hikes") {
                ForEach(matchingHikes) { hike in
                    Button { onSelectResult(hike) } label: {
                        HikeRow(
                            hike: hike,
                            isSelected: hike.id == selectedHikeID,
                            status: recordingStatus(for: hike)
                        )
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    func mapSuggestionsSection(matchingHikes: [Hike]) -> some View {
        if !completer.suggestions.isEmpty {
            Section {
                ForEach(completer.suggestions, id: \.self) { suggestion in
                    Button { onSelectCompletion(suggestion) } label: {
                        suggestionRow(for: suggestion)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                if !matchingHikes.isEmpty { Text("Maps") }
            }
        }
    }

    func suggestionRow(for suggestion: MKLocalSearchCompletion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title).foregroundStyle(.primary)
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
}

// MARK: - Recording state

private extension MapSheetHikes {
    func recordingStatus(for hike: Hike) -> HikeRow.Status? {
        guard belongsToActiveRecording(hike) else { return nil }
        guard hike.id == recorder.currentHike?.id else {
            return HikeRow.Status(title: "Recording", tint: .red)
        }
        return switch recorder.phase {
        case .idle: HikeRow.Status(title: "Recording", tint: .red)
        case .recovering: HikeRow.Status(title: "Recovering", tint: .orange)
        case .waitingForFix: HikeRow.Status(title: "Finding GPS", tint: .orange)
        case .recording: HikeRow.Status(title: "Recording", tint: .red)
        case .paused: HikeRow.Status(title: "Paused", tint: .secondary)
        case .saving: HikeRow.Status(title: "Saving", tint: .orange)
        case .reviewing: HikeRow.Status(title: "Review Route", tint: .orange)
        case .failed: HikeRow.Status(title: "Needs Attention", tint: .red)
        }
    }

    func belongsToActiveRecording(_ hike: Hike) -> Bool {
        hike.belongsToActiveRecording(currentHikeID: recorder.currentHike?.id)
    }
}
