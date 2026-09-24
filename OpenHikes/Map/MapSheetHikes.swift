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
import OpenHikesShared
import SwiftData
import SwiftUI

struct MapSheetHikes: View, Equatable {
    /// How much of the drawn route's colour the row carries.
    ///
    /// Raised with the surface it is now laid over — see `hikeRow(_:)`. It is
    /// a tint on a card rather than a wash over a map, so it can be stronger
    /// without swallowing the title on top of it.
    private static let selectedHikeHighlightOpacity: Double = 0.28
    private static let actionGlyphSize: CGFloat = 40
    /// Every hike this hiker has, newest first.
    ///
    /// Internal rather than private so the community section can read it from
    /// its own file — `private` is file-scoped in Swift, and that section is
    /// long enough to have pushed this one past its length limit. See
    /// `MapSheetCommunitySection.swift`, which needs it for one thing: which
    /// published hikes are already in the library.
    @Query(sort: \Hike.date, order: .reverse)
    var hikes: [Hike]
    /// Only ever used to reach the container a background sweep opens its own
    /// context on — see ``HikeListMetrics``. Nothing here writes through it.
    @Environment(\.modelContext)
    private var modelContext
    /// Keeps the matching-hike ranking across body passes — see ``HikeSearch``.
    @State private var hikeSearch = HikeSearch()
    /// The hike a swipe has asked to delete, while the dialog is up.
    ///
    /// Held here rather than as a `Bool` per row: one dialog on the list, not
    /// one per `ForEach` element, and the pending hike is what the wording is
    /// built from. Cleared by the dialog's own dismissal, so *Cancel*, a tap
    /// outside and the swipe sliding shut all land in the same place.
    @State private var pendingDeletion: Hike?
    /// Whether the list is in reorder mode.
    ///
    /// Entered by a long press on a row rather than by a button, which is the
    /// gesture a hiker reaches for — but the dragging itself is `List`'s own,
    /// and `List` only offers it in edit mode. A long press with no edit mode
    /// behind it does nothing at all: `HikeOrderUITests` asserted exactly that
    /// before this existed, and the row came back to where it started.
    @State private var editMode: EditMode = .inactive
    /// Bumped by a drag, and read by ``hikesList`` for nothing but that.
    ///
    /// The hand-ordered positions are device-local — see
    /// ``HikeLocalState/listOrder`` — and SwiftData's observation does not
    /// reach across stores, so a move writes rows this view would never be
    /// told about. This is the telling.
    @State private var orderRevision = 0
    /// Which order the list is in, unless the hiker has dragged a row — see
    /// ``HikeListOrder``. A preference about this screen rather than a fact
    /// about the library, so it lives in settings and not on a hike.
    @AppStorage(SettingsKey.hikeListSort)
    private var sortID: String = HikeListSort.newest.rawValue

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
    /// Submissions waiting for a person, which is an empty list for everybody
    /// who is not a reviewer — so for almost every launch this draws nothing
    /// and costs one comparison. See ``CommunityReviewQueue``.
    var review: CommunityReviewQueue
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
    /// A published hike tapped in the results, with the hiker's own copy of it
    /// when they have one: the caller opens that copy, and pushes the preview
    /// when there is none. See ``openListing(_:)``.
    let onSelectListing: (CommunityListing, Hike?) -> Void
    /// A queued submission tapped: the caller pushes the review screen.
    var onSelectPending: (CommunityPendingSubmission) -> Void = { _ in /* no-op default */ }
    /// A queued set of contributed photographs tapped: the caller pushes the
    /// other review screen. A second closure rather than one taking a sum
    /// type, because the two destinations are different screens and the sum
    /// would be unwrapped at the only place it was ever built.
    var onSelectPendingPhotos: (CommunityPendingPhotos) -> Void = { _ in /* no-op default */ }
    /// *Totals* tapped: the caller pushes ``LibraryTotalsView``.
    var onOpenTotals: () -> Void = { /* no-op default */ }
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
            && lhs.review === rhs.review
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
            isPresented: $pendingDeletion.isPresent(),
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

            // Under the heading rather than beside it. The circle up there is
            // something a hiker *does* — import a file — and an order is a way
            // of looking at what is already there. It also gave the segmented
            // control back the width it was competing for.
            if community.isBrowsing {
                // The community half has no orders to choose between, only a
                // hand-made one — so the bar is just the way back out of it.
                communityReorderBar
            } else {
                sortBar
            }

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

    /// GPX import, shown whether or not there are hikes. Recording and making
    /// a trail are the map's, under its leading edge — see
    /// ``MapTrailDraftControlsView`` for why they moved there.
    ///
    /// The glass circle is drawn at 40pt but reaches 44, which is the smallest
    /// target a finger can be expected to hit — the sizes are separate so the
    /// row keeps its proportions.
    var hikeActions: some View {
        importButton
            .font(.title3)
            .buttonStyle(.plain)
    }

    /// The row that says how the list is ordered, and offers the others.
    ///
    /// Always there, unlike the control it replaces, which appeared only once
    /// the hiker had dragged something. An order a hiker cannot see is an order
    /// they cannot change on purpose — and *Most Climb* is not a thing anybody
    /// discovers by dragging a row.
    ///
    /// It states the current order rather than showing a bare glyph, because
    /// the first question a list like this raises is "why is that one at the
    /// top", and the answer belongs on screen next to it.
    @ViewBuilder var sortBar: some View {
        HStack(spacing: 8) {
            if editMode == .active {
                // The way out of reorder mode, and the only one: while it is
                // on, a row's tap belongs to the list rather than to the hike,
                // so a hiker who cannot leave cannot open anything either.
                Button {
                    withAnimation { editMode = .inactive }
                } label: {
                    Label("Done Reordering", systemImage: "checkmark")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("hike-order-done-button")
            } else {
                sortMenu
            }
            Spacer(minLength: 0)
            if editMode != .active {
                Button(action: onOpenTotals) {
                    Label("Totals", systemImage: "chart.bar.xaxis")
                        .font(.footnote.weight(.semibold))
                        .minimumTapTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("library-totals-button")
            }
        }
        .padding(.horizontal)
    }

    var sortMenu: some View {
        Menu {
            // The hand-made order is never offered here — a hiker makes it by
            // dragging, not by picking it out of a list of orders it is not
            // one of. While it is in force nothing is ticked at all, which is
            // what keeps every entry a change: see ``sortSelection``.
            Picker("Order", selection: sortSelection) {
                ForEach(HikeListSort.menuOrder) { option in
                    Label(option.title, systemImage: option.symbol)
                        .tag(HikeListSort?.some(option))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCustomOrder ? "hand.draw" : sort.symbol)
                Text(isCustomOrder ? "Your Order" : sort.title)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tint)
            .minimumTapTarget()
        }
        // On the `Menu` and deliberately *not* on the `Picker` inside it.
        // A menu's content closure is built into a platform menu and torn down
        // the instant a row is tapped, so a `sensoryFeedback` declared in
        // there has no view left to fire from by the time `sort` changes — the
        // one control whose choice is worth confirming would have been the one
        // that said nothing. The label out here reads `sort` already, so the
        // trigger costs nothing new.
        .sensoryFeedback(HapticMoment.choiceChanged.feedback, trigger: sort)
        .accessibilityLabel("Sort hikes")
        .accessibilityValue(isCustomOrder ? "Your order" : sort.title)
        .accessibilityIdentifier("hike-order-button")
    }

    /// Picking an order also gives up a hand-made one — see ``HikeListOrder``,
    /// whose header says why the two cannot both be in force.
    ///
    /// Optional, and `nil` while a hand-made order is in force, for two
    /// reasons that are really one. A tick beside *Newest First* on a list
    /// the hiker has dragged into their own order is a claim the list is
    /// contradicting; and it is the entry they would reach for to go *back*
    /// to it, which a picker asked to select the value it already holds is
    /// entitled to ignore. With nothing selected, every entry in the menu is
    /// a change, and the only way out of *Your Order* is not the one door
    /// that might be nailed shut.
    var sortSelection: Binding<HikeListSort?> {
        Binding(
            get: { isCustomOrder ? nil : sort },
            set: { chosen in
                guard let chosen else { return }
                if HikeListOrder.isCustom(hikes) { HikeListOrder.reset(hikes) }
                sortID = chosen.rawValue
                orderRevision += 1
            }
        )
    }

    var sort: HikeListSort { HikeListSort(rawValue: sortID) ?? .newest }

    var isCustomOrder: Bool { HikeListOrder.isCustom(hikes) }

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
        // Read once per pass and handed to both the pin and the rows: asking
        // `status(for:)` inside the `ForEach` would ask it per row per pass,
        // and the answer is a property of the list.
        let activeID = activeHikeID
        // `orderRevision` is read for its effect rather than its value. The
        // positions live in `HikeLocalState`, a store no `@Query` observes, so
        // a drag writes something nothing here would notice; bumping it is how
        // the list is told to arrange itself again. See ``HikeListOrder``.
        let arranged = orderRevision >= 0
            ? HikeListOrder.arrange(hikes, activeHikeID: activeID, sort: sort)
            : hikes

        return List {
            if hikes.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(arranged) { hike in
                    hikeRow(hike)
                        // The hike being walked right now is not a place in a
                        // library, it is the thing happening — so it is pinned
                        // above the list and cannot be dragged out of it.
                        .moveDisabled(hike.id == activeID)
                        // A context menu rather than a long-press gesture of
                        // our own, and the reason is what a bare
                        // `LongPressGesture` on these rows actually did: the
                        // row is a `Button`, so the press still fired it and
                        // the app pushed the hike instead of offering to move
                        // it. `HikeOrderUITests` caught that. The context menu
                        // is the platform's own long press, and it suppresses
                        // the button underneath it.
                        .contextMenu {
                            Button {
                                withAnimation { editMode = .active }
                            } label: {
                                Label("Reorder Hikes", systemImage: "arrow.up.arrow.down")
                            }
                        }
                }
                .onMove { offsets, destination in
                    // See ``MapSheetCommunitySection/moveCommunity(_:from:to:)``
                    // for why the drop and not the drag.
                    HapticMoment.rowMoved.play()
                    HikeListOrder.move(arranged, from: offsets, to: destination)
                    orderRevision += 1
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
        // Only ever for the hikes an elevation order needs and nothing has,
        // so an ordinary launch asks for nothing and a library measured once
        // stays measured. See `HikeListMetrics` for why this cannot be done
        // where the sorting is.
        .task(id: TaskKey(sort: sort, count: hikes.count)) {
            let missing = HikeListOrder.hikesMissingElevation(in: hikes, for: sort)
            guard !missing.isEmpty else { return }
            // Off this actor deliberately: the sweep opens its own context and
            // may walk every route in the library, which is the one thing that
            // must not happen where a list is drawn.
            let container = modelContext.container
            let filled = await Task.detached(priority: .utility) {
                HikeListMetrics.fillElevation(for: missing, in: container)
            }.value
            if filled { orderRevision += 1 }
        }
    }

    /// What a change of has to restart the elevation fill.
    ///
    /// The sort, because only two of them need figures; and the number of
    /// hikes, because an import or a finished walk adds one nothing has
    /// measured. Not the hikes themselves: a `Hike` changes on every tint
    /// slider drag, and re-running a library sweep for that is the thing the
    /// query isolation next door exists to prevent.
    private struct TaskKey: Equatable {
        let sort: HikeListSort
        let count: Int
    }

    /// The hike being recorded or walked right now, if there is one.
    ///
    /// Derived from the badge rather than from a second reading of the
    /// recorder and the walk session: a row that says *Recording* and a row
    /// that sorts to the top must be the same row, and there is one rule for
    /// that already.
    var activeHikeID: UUID? {
        hikes.first { status(for: $0) != nil }?.id
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
        // The drawn route's row is tinted, and the tint needs something to be
        // a percentage *of*. Fifteen percent of a colour laid straight over
        // the sheet's glass is fifteen percent of the map underneath —
        // which on one tile is a visible blue wash and on the next is nothing
        // at all, and "nothing at all" is what a hiker sees most of the time.
        // The surface makes it the same tint on every tile; it is also the
        // only layer here that is not transparent, so the selected row reads
        // as a card among clear ones. See ``Color/contentSurface``.
        .listRowBackground(
            Color.contentSurface
                .overlay(hike.tintOpaque.opacity(Self.selectedHikeHighlightOpacity))
                // One view rather than a `Color.clear` in the other branch of a
                // ternary, which would need erasing through `AnyView` for a row
                // that is rebuilt on every selection change.
                .opacity(hike.id == selectedHikeID ? 1 : 0)
        )
        .swipeActions(edge: .trailing) {
            if canDeleteFromLibrary(hike) {
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
            // The two on the map first: they are the two a first launch is
            // most likely to want, and the ones this sentence has to point
            // away from the sheet to find.
            #if os(iOS)
            Text("Tap \(recordIcon) on the map to record a walk, or \(makerIcon) to draw a trail.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // The glyphs are interpolated as images and contribute
                // nothing spoken, so the sentence has to name the buttons it
                // is pointing at.
                .accessibilityLabel(
                    "Tap the Record a hike button on the map to record a walk, "
                        + "or the Make a trail button to draw a trail."
                )
            #endif
            Text("Have a GPX file? Tap \(importIcon) to import it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Have a GPX file? Tap the Import GPX file button to import it.")
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

    #if os(iOS)
    var recordIcon: Text {
        Text(Image(systemName: MapTrailDraftControlsView.recordSymbolName)).foregroundStyle(.red)
    }

    var makerIcon: Text {
        // Primary, as the map's own button draws it, so the sentence shows the
        // glyph the hiker is looking for.
        Text(Image(systemName: MapTrailDraftControlsView.symbolName)).foregroundStyle(.primary)
    }
    #endif
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

    /// Whether this row gets a Delete swipe built for it.
    ///
    /// Deliberately not `!belongsToActiveRecording(_:)`. That spelling took
    /// the mirrored `isRecording` flag as proof a walk was under way, so a
    /// draft that arrived from CloudKit without this device's journal — after
    /// a reinstall, say — was left with no Delete action in the list, no
    /// sweep willing to touch it, and a recording screen that could only
    /// start a *new* hike. See ``Hike/canBeDeletedFromLibrary(currentHikeID:)``.
    func canDeleteFromLibrary(_ hike: Hike) -> Bool {
        hike.canBeDeletedFromLibrary(currentHikeID: recorder.currentHike?.id)
    }
}
