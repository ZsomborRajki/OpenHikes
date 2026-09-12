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

struct MapSheetHikes: View, Equatable {
    private static let selectedHikeHighlightOpacity: Double = 0.15
    private static let actionGlyphSize: CGFloat = 40
    /// Under the 8pt gap between the two action circles, so they stay separate
    /// targets at rest and their glass still blends at the edges.
    private static let actionGlassSpacing: CGFloat = 6

    @Query(sort: \Hike.date, order: .reverse)
    private var hikes: [Hike]
    /// Keeps the matching-hike ranking across body passes — see ``HikeSearch``.
    @State private var hikeSearch = HikeSearch()

    let searchText: String
    let isSearchFocused: Bool
    var searchSession: MapSearchSession
    /// True at the smallest detent, where only the search field shows.
    let isCompact: Bool
    var completer: SearchCompleter
    var recorder: HikeRecorder
    /// Read for the one thing about a row a walk changes: its `Active` /
    /// `Paused` badge, in the recording badge's shape. Only the coarse
    /// properties are read — the ones that change on a tap — so a fix that
    /// extends coverage never reaches this body.
    var walkSession: TrailWalkSession
    /// Published hikes and whether the walker has asked for them. Only the
    /// coarse properties are read here — the two result lists, the state and
    /// the selected area — so a pan that does not produce a request never
    /// reaches this body. The map's results and the typed query's are separate
    /// lists on purpose; see ``CommunityBrowser``.
    var community: CommunityBrowser
    let selectedHikeID: UUID?
    let onOpen: (Hike) -> Void
    /// A hike tapped in the search results: the caller drops focus before opening
    /// it, preserving the query and results for back navigation.
    let onSelectResult: (Hike) -> Void
    let onSelectCompletion: (MKLocalSearchCompletion) -> Void
    let onFindCommunity: (MKLocalSearchCompletion) -> Void
    let onFindCommunityQuery: () -> Void
    /// A published hike tapped in the results: the caller pushes its preview.
    let onSelectListing: (CommunityListing) -> Void
    /// The surviving hikes are handed over with the doomed one because freeing
    /// its tiles means asking which of them are still claimed elsewhere.
    let onDelete: (Hike, [Hike]) -> Void
    let onRecord: () -> Void
    let onImport: () -> Void

    /// Lets `.equatable()` skip this subtree when nothing it draws has changed.
    ///
    /// Without it, every re-evaluation of `MapSheet` rebuilds the whole list:
    /// the six action closures are new values on each pass, so SwiftUI's own
    /// structural comparison can never conclude that two of these are the same
    /// view. That is a body pass, a `@Query` read and a `HikeRow` per hike for
    /// things the list has no part in — a photo opened three screens deep was
    /// paying for two of them.
    ///
    /// The closures are excluded on purpose rather than by necessity. They are
    /// methods on the sheet, and everything they write to — the selection and
    /// path bindings, the search field's state, the completer — is reached
    /// through a property wrapper whose storage outlives any one copy of that
    /// struct, so an older closure and a newer one do the same thing. The
    /// controllers are compared by identity for the reason ``MapView`` compares
    /// its own: the parent hands down the same instance every time, and their
    /// contents changing is something this body observes directly.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.searchText == rhs.searchText
            && lhs.isSearchFocused == rhs.isSearchFocused
            && lhs.isCompact == rhs.isCompact
            && lhs.selectedHikeID == rhs.selectedHikeID
            && lhs.completer === rhs.completer
            && lhs.recorder === rhs.recorder
            && lhs.walkSession === rhs.walkSession
            && lhs.community === rhs.community
            && lhs.searchSession === rhs.searchSession
    }

    var body: some View {
        RenderSignpost.mark("MapSheetHikesBody", "\(hikes.count) hikes searching=\(isSearchFocused)")
        let hasQuery = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isSearching = hasQuery && searchSession.showsResults
        let matchingHikes = isSearching && searchSession.scope.includesHikes
            ? hikeSearch.rankedHikes(matching: searchText, in: hikes) : []

        return Group {
            if isCompact {
                Spacer()
            } else if isSearching || searchSession.scope == .community {
                suggestionsList(matchingHikes: matchingHikes)
            } else if searchSession.scope == .places {
                ContentUnavailableView("Search for a place", systemImage: "magnifyingglass")
            } else {
                hikesSection.padding(.top, 12)
            }
        }
        .onChange(of: hasQuery) { _, hasQuery in
            if !hasQuery { hikeSearch.clear() }
        }
        .onChange(of: searchSession.scope) { _, scope in
            if !scope.includesHikes { hikeSearch.clear() }
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
                    .accessibilityAddTraits(.isHeader)
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

    /// Recording and GPX import actions, shown whether or not there are hikes.
    ///
    /// The glass circles are drawn at 40pt but reach 44, which is the smallest
    /// target a finger can be expected to hit — the sizes are separate so the
    /// row keeps its proportions.
    var hikeActions: some View {
        GlassStack(spacing: Self.actionGlassSpacing) {
            HStack(spacing: 8) {
                #if os(iOS)
                recordButton
                #endif
                importButton
            }
        }
        .font(.title3)
        .buttonStyle(.plain)
    }

    #if os(iOS)
    var recordButton: some View {
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
                .frame(width: Self.actionGlyphSize, height: Self.actionGlyphSize)
                // Tinted while a recording is live, so the control carries the
                // same red the map and the row badge use rather than leaving
                // only its glyph to say so.
                .glassSurface(
                    recorder.isActive
                        ? .regular.tint(.red).interactive()
                        : .regular.interactive(),
                    in: .circle
                )
                .minimumTapTarget()
        }
        .accessibilityLabel(
            recorder.isActive
                ? "Open hike recording"
                : "Record a hike"
        )
        .accessibilityIdentifier("record-hike-button")
    }
    #endif

    var importButton: some View {
        Button {
            onImport()
        } label: {
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(.tint)
                .frame(width: Self.actionGlyphSize, height: Self.actionGlyphSize)
                .glassSurface(.regular.interactive(), in: .circle)
                .minimumTapTarget()
        }
        .accessibilityLabel("Import GPX file")
        .accessibilityIdentifier("import-gpx-button")
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
                        status: status(for: hike)
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
                // The glyph is interpolated as an image and contributes
                // nothing spoken, so the sentence has to name the button it
                // is pointing at.
                .accessibilityLabel("Tap the Import GPX file button to import a GPX file.")
            #if os(iOS)
            Text("Or tap \(recordIcon) to record one as you walk.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Or tap the Record a hike button to record one as you walk.")
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
            if searchSession.scope.includesHikes {
                hikeSuggestionsSection(matchingHikes: matchingHikes)
                if matchingHikes.isEmpty {
                    Section("Your Hikes") { Text("No saved hikes match this search.") }
                }
            }
            if searchSession.scope.includesCommunity, community.hasTransport {
                CommunitySearchResults(
                    browser: community,
                    query: searchText,
                    usesArea: searchSession.scope == .community,
                    importedIDs: importedListingIDs,
                    onSelect: onSelectListing
                )
            }
            if searchSession.scope.includesPlaces || searchSession.scope == .community {
                mapSuggestionsSection(matchingHikes: matchingHikes)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    func hikeSuggestionsSection(matchingHikes: [Hike]) -> some View {
        if !matchingHikes.isEmpty {
            Section {
                ForEach(matchingHikes) { hike in
                    Button { onSelectResult(hike) } label: {
                        HikeRow(
                            hike: hike,
                            isSelected: hike.id == selectedHikeID,
                            status: status(for: hike)
                        )
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Your Hikes").accessibilityIdentifier("saved-hike-search-heading")
            }
        }
    }

    @ViewBuilder
    func mapSuggestionsSection(matchingHikes: [Hike]) -> some View {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Section("Places") {
                ForEach(completer.suggestions, id: \.self) { suggestion in
                    if searchSession.scope.includesPlaces {
                        Button { onSelectCompletion(suggestion) } label: {
                            suggestionRow(for: suggestion)
                        }
                        .buttonStyle(.plain)
                    }
                    if community.hasTransport, searchSession.scope != .places {
                        Button { onFindCommunity(suggestion) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Find community hikes around \(suggestion.title)", systemImage: "figure.hiking")
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("community-around-place")
                    }
                }
                if completer.suggestions.isEmpty {
                    if searchSession.scope == .community || searchSession.scope == .all && community.hasTransport {
                        Button("Find community hikes around \(searchText)", action: onFindCommunityQuery)
                            .accessibilityIdentifier("community-around-query")
                    } else if searchSession.scope == .places {
                        Text("No place suggestions. Press Search to look up this place.")
                    } else {
                        // Return no longer geocodes outside Places — see
                        // `performSearch` — so the only scope that can honour
                        // "press Search" is the only one told to.
                        Text("No place suggestions. Switch to Places to look this up on the map.")
                    }
                }
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
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Recording and walk state

private extension MapSheetHikes {
    /// A recording's badge outranks a walk's, as it does on every surface —
    /// though a hike can only carry one of the two, since a recording's own
    /// draft never gets a walk.
    func status(for hike: Hike) -> HikeRow.Status? {
        recordingStatus(for: hike) ?? walkStatus(for: hike)
    }

    /// `Active` / `Paused`, exactly as a recording's row carries
    /// `Recording` / `Paused`: the one thing about the row that changes, so a
    /// walk left running by mistake is visible from the list and one tap from
    /// the controls that end it.
    func walkStatus(for hike: Hike) -> HikeRow.Status? {
        guard walkSession.walkedHikeID == hike.id, let phase = walkSession.phase else { return nil }
        return switch phase {
        case .following: HikeRow.Status(title: "Active", tint: hike.tintOpaque)
        case .paused: HikeRow.Status(title: "Paused", tint: .secondary)
        }
    }

    func recordingStatus(for hike: Hike) -> HikeRow.Status? {
        guard belongsToActiveRecording(hike) else { return nil }
        guard hike.id == recorder.currentHike?.id else { return HikeRow.Status(title: "Recording", tint: .red) }
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

// MARK: - Community

private extension MapSheetHikes {
    /// Listing ids this walker has already imported.
    ///
    /// Derived from the query that is already loaded rather than fetched: the
    /// hikes are in memory either way, and a second `@Query` filtered on the
    /// column would be a second invalidation source for this body.
    var importedListingIDs: Set<String> {
        Set(hikes.compactMap(\.importedFromListingID))
    }

}
