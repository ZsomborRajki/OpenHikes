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
    /// Every hike this hiker has, newest first.
    ///
    /// Internal rather than private so the community section can read it from
    /// its own file — `private` is file-scoped in Swift, and that section is
    /// long enough to have pushed this one past its length limit. See
    /// `MapSheetCommunitySection.swift`, which needs it for one thing: which
    /// published hikes are already in the library.
    @Query(sort: \Hike.date, order: .reverse)
    var hikes: [Hike]
    /// Keeps the matching-hike ranking across body passes — see ``HikeSearch``.
    @State private var hikeSearch = HikeSearch()
    /// The hike a swipe has asked to delete, while the dialog is up.
    ///
    /// Held here rather than as a `Bool` per row: one dialog on the list, not
    /// one per `ForEach` element, and the pending hike is what the wording is
    /// built from. Cleared by the dialog's own dismissal, so *Cancel*, a tap
    /// outside and the swipe sliding shut all land in the same place.
    @State private var pendingDeletion: Hike?

    let searchText: String
    let isSearchFocused: Bool
    /// True at the smallest detent, where only the search field shows.
    let isCompact: Bool
    var completer: SearchCompleter
    var recorder: HikeRecorder
    /// Read for the one thing about a row a walk changes: its `Active` /
    /// `Paused` badge, in the recording badge's shape. Only the coarse
    /// properties are read — the ones that change on a tap — so a fix that
    /// extends coverage never reaches this body.
    var walkSession: TrailWalkSession
    /// Published hikes and whether the hiker has asked for them. Only the
    /// coarse properties are read here — the two result lists, the state, the
    /// area's name and whether the map is offering to look somewhere else —
    /// so a pan that raises no offer never reaches this body, and one that
    /// does reaches it once. The map's results and the typed query's are
    /// separate lists on purpose; see ``CommunityBrowser``.
    var community: CommunityBrowser
    let selectedHikeID: UUID?
    let onOpen: (Hike) -> Void
    /// A hike tapped in the search results: the caller clears the field and
    /// drops focus before opening it.
    let onSelectResult: (Hike) -> Void
    let onSelectCompletion: (MKLocalSearchCompletion) -> Void
    /// Runs the typed query against MapKit, exactly as Return does.
    ///
    /// Here because a search that matched nothing anywhere now says so in a
    /// row rather than by silently putting the hikes list back, and the one
    /// useful thing to offer in that row is the search the hiker has already
    /// typed — see ``mapSearchFallback(matchingHikes:)``.
    let onSubmitQuery: () -> Void
    /// A published hike tapped in the results: the caller pushes its preview.
    let onSelectListing: (CommunityListing) -> Void
    /// The surviving hikes are handed over with the doomed one because freeing
    /// its tiles means asking which of them are still claimed elsewhere.
    let onDelete: (Hike, [Hike]) -> Void
    /// Opens the takedown-request form for a hike that has been shared.
    ///
    /// Offered from the delete dialog because that is the moment the request's
    /// only inputs are about to go: `communitySubmissionID` and
    /// `communityListingID` live on the `Hike` row and nowhere else, so after
    /// the deletion "enough detail to identify it" is a title and a date typed
    /// from memory. See ``CommunityWithdrawal``.
    var onWithdraw: (Hike) -> Void = { _ in /* no-op default */ }
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
    }

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
        // A focused field with nothing typed in it is not a search — but a
        // focused field with something typed in it is one whether or not
        // anything has matched yet. That distinction used to be missing:
        // `isSearching` also required a non-empty result somewhere, so the
        // sheet flipped back to the hikes list between keystrokes and a query
        // that matched nothing at all put the hiker back where they started
        // with no explanation. The empty case is now a row — see
        // ``mapSearchFallback(matchingHikes:)``.
        let hasQuery = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isSearching = isSearchFocused && hasQuery
        // Built from the pending hike rather than from a captured copy, so the
        // wording names the row that was actually swiped. `nil` whenever no
        // dialog is up, which is every pass but one.
        let prompt = pendingDeletion.map(HikeDeletionPrompt.init(hike:))

        return Group {
            if isCompact {
                Spacer()
            } else if isSearching {
                suggestionsList(matchingHikes: matchingHikes)
                    .padding(.top, 12)
            } else {
                hikesSection
                    .padding(.top, 12)
            }
        }
        .onChange(of: isSearchFocused) { _, focused in
            // Nothing ranks while the field is unfocused, so there is no
            // cached ranking worth keeping — and holding one would keep every
            // matched hike alive behind a search nobody is running.
            if !focused { hikeSearch.clear() }
        }
        // One dialog for the whole list rather than one per `ForEach` row, and
        // out here rather than inside `hikesSection` so a detent change or a
        // search focus arriving mid-swipe cannot take it off screen with the
        // list. `presenting:` so the buttons act on the hike the dialog was
        // built for and never on a leftover from the previous swipe.
        .confirmationDialog(
            prompt?.title ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { hike in
            Button(prompt?.confirmTitle ?? "", role: .destructive) {
                onDelete(hike, hikes)
            }
            // Only for a hike that has actually been sent, and above Cancel
            // rather than below the delete: it is the way out of this dialog
            // that keeps the record names, and a hiker who wanted the shared
            // copy gone has not yet been given what they came for.
            if hike.communitySubmissionID != nil {
                Button("Ask for Removal First") { onWithdraw(hike) }
            }
            Button("Cancel", role: .cancel) { /* intentionally empty */ }
        } message: { _ in
            Text(prompt?.message ?? "")
        }
    }
}

// MARK: - Hikes list

private extension MapSheetHikes {
    var hikesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                listHeading
                hikeActions
            }
            .padding(.horizontal)

            selectedList
        }
    }

    /// The switch between the two lists — or the old title, on a launch that
    /// has no second list to switch to.
    ///
    /// A segmented control rather than a heading because there are now two
    /// answers to *where shall I walk?* and they are the same length: the
    /// hiker's own hikes and the published ones. The picker names whichever is
    /// showing, which is why neither list carries a title of its own any more.
    @ViewBuilder var listHeading: some View {
        if community.hasTransport {
            listPicker
        } else {
            // Absent rather than disabled, for the reason the share button is:
            // this launch is never going to reach the community — see
            // ``CommunityBrowser/hasTransport``.
            Text("Hikes")
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
    }

    /// Whichever of the two the picker has selected.
    ///
    /// Two `List`s rather than two sections of one, which is the whole of this
    /// change. As sections, the shared hikes sat under however many of the
    /// hiker's own there were — reachable only by scrolling past a library
    /// that grows — and a scroll position meant something different depending
    /// on which half you were reading. Each list now starts at the top.
    @ViewBuilder var selectedList: some View {
        if community.isBrowsing {
            communityList
        } else {
            hikesList
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

    /// The hiker's own hikes, and nothing else.
    ///
    /// The published ones are ``communityList``, behind the other segment of
    /// ``listPicker``. They shared this list for a while — a *Community Hikes*
    /// section under the hiker's own — which fixed the thing the old *Nearby*
    /// chip got wrong (the same records under two headings depending on how
    /// they were found) at the cost of burying the shared half under a library
    /// that only ever gets longer. The two are a tab apart again, but a tab is
    /// not the chip: the picker says which list is showing and the community
    /// half still costs nothing until it is selected.
    var hikesList: some View {
        List {
            if hikes.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(hikes) { hike in
                    hikeRow(hike)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    func hikeRow(_ hike: Hike) -> some View {
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
                // Asks first. A hike's photographs are the one thing in this
                // app with no second copy anywhere — see ``HikeDeletionPrompt``
                // for what a single swipe used to take, and from how many
                // devices.
                Button(role: .destructive) {
                    pendingDeletion = hike
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
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
            hikeSuggestionsSection(matchingHikes: matchingHikes)
            communitySuggestionsSection()
            mapSuggestionsSection(matchingHikes: matchingHikes)
            mapSearchFallback(matchingHikes: matchingHikes)
            nearbySuggestionsSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// What the list says when the query has matched nothing yet.
    ///
    /// Deliberately an offer rather than a verdict. MapKit's completions
    /// arrive a moment after the keystroke that asks for them, so "no results"
    /// would be wrong as often as it was right — and *search for what I typed*
    /// is useful either way, since it is what Return does and there is
    /// otherwise nothing on screen that says so.
    ///
    /// Conditioned on the three sources that answer the query. The *Near Here*
    /// section below answers a different one and must not stand in for a
    /// match.
    @ViewBuilder
    func mapSearchFallback(matchingHikes: [Hike]) -> some View {
        if matchingHikes.isEmpty,
           completer.suggestions.isEmpty,
           community.matchingListings.isEmpty {
            Section {
                Button {
                    onSubmitQuery()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Search Maps for “\(searchText)”")
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("map-search-fallback")
                }
                .buttonStyle(.plain)
            }
        }
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
                            status: status(for: hike)
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
                if !matchingHikes.isEmpty || !community.matchingListings.isEmpty { Text("Maps") }
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
