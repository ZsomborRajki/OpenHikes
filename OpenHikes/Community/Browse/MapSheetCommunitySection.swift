//
//  MapSheetCommunitySection.swift
//  OpenHikes
//
//  The shared hikes, where the hiker's own list already is.
//
//  Split out of `MapSheetHikes.swift` rather than living beside the rest of
//  the sheet, for the reason `OpenHikesView+Photos.swift` is split out of its
//  own view: this is a self-contained half of one screen, and the file it came
//  from is already the one place `@Query` lands. Nothing about the split is
//  behavioural — these are still members of ``MapSheetHikes``, inlined into
//  its body like any other computed property, and the render-isolation note in
//  that file's header covers them.
//
//  What is here is the *Community* half of ``MapSheetList``: its picker, its
//  list, and the three things that list can say when it has no rows.
//
//  It has been all three shapes this feature has had, and the differences
//  matter. The *Nearby* chip was a mode with nothing to say for itself: it
//  swapped the hikes list for a list of published ones, and the same records
//  appeared under two different headings depending on how they had been found.
//  The section that replaced it put the shared hikes under the hiker's own in
//  one list, which fixed that and bought a new problem — the shared half sat
//  below a library that only ever gets longer, so the hiker scrolled past
//  everything they had already walked to reach the hikes they had not.
//
//  So: two lists, and a picker that says which one is showing. What keeps that
//  from being the chip again is that the picker is *labelled on both sides*
//  and the heading is not a control — nothing is a mode you can be in without
//  being told. The energy bargain is unchanged and is now carried by the tab
//  itself: until *Community* is selected nothing about this feature reaches
//  the network, and leaving the tab ends the session — see
//  ``CommunityBrowser/startBrowsing()`` and ``CommunityBrowser/stopBrowsing()``.
//

import OpenHikesData
import OpenHikesShared
import SwiftUI

/// Which of the sheet's two lists is showing.
///
/// Deliberately not a `@State` of its own. The *Community* tab and the browse
/// session are the same thing — selecting the tab is the opt-in, leaving it
/// ends the session — so a separate flag could only ever disagree with
/// ``CommunityBrowser/isBrowsing`` about which list the hiker is looking at.
/// It also means the map's *Search this area* pill can follow the tab without
/// anything in SwiftUI telling it to: the pill already observes the browser.
enum MapSheetList: Hashable {
    case community
    case mine
}

extension MapSheetHikes {
    /// The picker, bound to the browse session rather than to state of its own.
    ///
    /// Selecting *Community* is the one request nobody confirms twice, and
    /// selecting *My Hikes* takes the results, the pins and the route lines
    /// with it: a list that is not on screen has no business holding the map's
    /// answer to a question the hiker has moved on from.
    var listPicker: some View {
        Picker("Hikes to show", selection: selectedListBinding) {
            Text("My Hikes").tag(MapSheetList.mine)
            Text("Community").tag(MapSheetList.community)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("hike-list-picker")
    }

    var selectedListBinding: Binding<MapSheetList> {
        Binding(
            get: { community.isBrowsing ? .community : .mine },
            set: { selection in
                switch selection {
                case .community:
                    community.startBrowsing()
                    // The same opt-in covers both lists, because it is the
                    // same tap: selecting *Community* is what the repository's
                    // rule about reaching the network is about, and the queue
                    // asks at most once a launch behind it. See
                    // ``CommunityReviewQueue``.
                    review.startBrowsing()
                case .mine:
                    community.stopBrowsing()
                    review.stopBrowsing()
                }
            }
        )
    }

    /// The hiker's own copies of published hikes, keyed by the listing each
    /// one came from.
    ///
    /// Derived from the query that is already loaded rather than fetched: the
    /// hikes are in memory either way, and a second `@Query` filtered on the
    /// column would be a second invalidation source for this body.
    ///
    /// One dictionary rather than a set of ids, because a row asks two
    /// questions and they have to agree: whether it says *Saved*, and which
    /// screen tapping it opens. See ``openListing(_:)``.
    var importedHikes: [String: Hike] {
        CommunityImport.importedByListing(in: hikes)
    }

    /// The hand-ordered places of community rows, by listing id.
    ///
    /// In memory, and deliberately: these are *results*, not a library. They
    /// are re-asked whenever the map moves, so an order kept on disk would
    /// outlive the answer it described and start arranging a different set of
    /// hikes. Within a session the ids are stable, so a hiker who put three
    /// rows in the order they mean to walk them keeps that while they browse.
    ///
    /// A listing nobody has moved has no entry and keeps the place the search
    /// gave it, after everything that was placed by hand.
    func arrangedCommunity(_ listings: [CommunityListing]) -> [CommunityListing] {
        guard !community.handOrder.isEmpty else { return listings }
        let ordered = listings.enumerated().sorted { first, second in
            let left = community.handOrder[first.element.id] ?? Int.max
            let right = community.handOrder[second.element.id] ?? Int.max
            if left != right { return left < right }
            return first.offset < second.offset
        }
        return ordered.map(\.element)
    }

    /// Applies a drag within one section, and numbers that section's rows.
    ///
    /// Per section rather than across both: the two are different kinds of
    /// answer, and a row dragged out of one and into the other would be
    /// claiming to be something it is not.
    func moveCommunity(
        _ displayed: [CommunityListing],
        from offsets: IndexSet,
        to destination: Int
    ) {
        // On the drop rather than through the drag: a row follows the finger
        // the whole way, so the one moment worth marking is it being let go
        // somewhere new.
        HapticMoment.rowMoved.play()
        var moved = displayed
        moved.move(fromOffsets: offsets, toOffset: destination)
        for (index, listing) in moved.enumerated() {
            community.handOrder[listing.id] = index
        }
    }

    /// Where a tapped listing goes.
    ///
    /// A hike the hiker has already imported opens as *their* hike, not as
    /// the preview of somebody else's. The preview asks whether to keep a
    /// stranger's trail, and a row badged *Saved* has already answered it —
    /// what stood there was a page whose one control read *Open in My Hikes*,
    /// which is a second tap for the thing the first tap asked for.
    ///
    /// The decision itself is ``SheetPresentation/open(_:importedAs:selectedHike:)``,
    /// because the map's shared-hike pins are a second door to the same two
    /// screens and the two must not disagree.
    func openListing(_ listing: CommunityListing) {
        onSelectListing(listing, importedHikes[listing.id])
    }

    /// Published hikes: the *Community* tab's whole list.
    ///
    /// Its own `List` rather than a section of the hiker's own, and it draws
    /// only while browsing — which is the same thing as the tab being
    /// selected. Unreachable entirely when this launch has no transport,
    /// since ``listPicker`` is absent then and nothing can select it: a hosted
    /// suite or UI automation gets the hikes list and no second tab at all,
    /// for the same reason the share button is absent rather than disabled.
    var communityList: some View {
        List {
            reviewSection
            if community.nearbyListings.isEmpty {
                Section {
                    communityEmptyRow
                } header: {
                    communitySectionHeader
                } footer: {
                    communitySectionFooter
                }
            } else {
                sharedSection
                curatedSection
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, communityEditMode)
    }

    /// The way out of the community list's reorder mode, and the only one.
    ///
    /// The hiker's own list puts its *Done* in the sort bar, and that bar is
    /// hidden while the community half is showing — so without this, tapping
    /// *Reorder List* was a one-way door: edit mode makes a row's tap belong
    /// to the `List` rather than to the listing under it, and
    /// ``CommunityBrowser/isReordering`` outlives the sheet and the tab, so
    /// nothing short of relaunching cleared it.
    @ViewBuilder var communityReorderBar: some View {
        if community.isReordering {
            HStack(spacing: 8) {
                Button {
                    withAnimation { community.isReordering = false }
                } label: {
                    Label("Done Reordering", systemImage: "checkmark")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityIdentifier("community-order-done-button")
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
        }
    }

    /// The browser's reorder flag, as the environment wants it.
    ///
    /// A derived binding rather than a second piece of state: `EditMode` is
    /// what `List` reads, `isReordering` is what the browse session holds, and
    /// two stored values would be one too many to keep in agreement.
    var communityEditMode: Binding<EditMode> {
        Binding(
            get: { community.isReordering ? .active : .inactive },
            set: { community.isReordering = $0 == .active }
        )
    }

    /// Hikes people published, above the ones a database knows about.
    ///
    /// Two sections rather than one ranked list, because the two are not the
    /// same kind of answer and a hiker reading a row needs to know which they
    /// are looking at: one is somebody's walk, with their photographs and
    /// their description on it, and the other is a way marked on
    /// OpenStreetMap that nobody here has been down. Ranking them together
    /// buried the first kind under the second wherever a mapped area is
    /// dense, which is most places worth walking.
    ///
    /// Empty sections are absent rather than empty: a heading over nothing is
    /// a claim that there is a kind of answer here when there is not.
    @ViewBuilder var sharedSection: some View {
        let listings = arrangedCommunity(sharedListings)
        if !listings.isEmpty {
            Section {
                // A failure over rows that are still on screen. The empty
                // state is the only place a failure used to be reported, so a
                // refresh that failed on top of a good list said nothing at
                // all — and since the rows are deliberately kept, the section
                // looked like it had simply answered. It has not: these are
                // the previous area's hikes, and the header says so.
                if case .failed(let failure) = community.state {
                    communityRefreshFailureRow(failure)
                }
                ForEach(listings) { listing in
                    communityRow(listing)
                }
                .onMove { offsets, destination in
                    moveCommunity(listings, from: offsets, to: destination)
                }
            } header: {
                communitySectionHeader
            } footer: {
                communitySectionFooter
            }
        }
    }

    /// The ways OpenStreetMap knows about, under the walks people shared.
    @ViewBuilder var curatedSection: some View {
        let listings = arrangedCommunity(curatedListings)
        if !listings.isEmpty {
            Section {
                ForEach(listings) { listing in
                    communityRow(listing)
                }
                .onMove { offsets, destination in
                    moveCommunity(listings, from: offsets, to: destination)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("From OpenStreetMap")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                }
                .textCase(nil)
            }
        }
    }

    /// Walks people published here.
    var sharedListings: [CommunityListing] {
        community.nearbyListings.filter { !$0.isCurated }
    }

    /// Ways OpenStreetMap has, which nobody here has walked.
    var curatedListings: [CommunityListing] {
        community.nearbyListings.filter(\.isCurated)
    }

    /// One listing, as a row that opens it.
    ///
    /// The leaf all four places that list a community hike go through — the
    /// two browse sections and the two suggestion sections — because a row
    /// that opened its listing on a tap in three of them and not the fourth
    /// would be a list where some rows work.
    func communityRowButton(_ listing: CommunityListing) -> some View {
        Button {
            openListing(listing)
        } label: {
            CommunityHikeRow(
                listing: listing,
                isImported: importedHikes[listing.id] != nil
            )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The same row, in the lists a hiker is allowed to reorder.
    func communityRow(_ listing: CommunityListing) -> some View {
        communityRowButton(listing)
            // The same offer the hiker's own rows make, for the same reason: a
            // long press is where a hiker looks for "let me move this", and a
            // gesture of our own would fire the button under it instead.
            .contextMenu {
                Button {
                    withAnimation { community.isReordering = true }
                } label: {
                    Label("Reorder List", systemImage: "arrow.up.arrow.down")
                }
            }
    }

    /// Submissions waiting for a person, above the published ones.
    ///
    /// Absent for everybody whose queue is empty, which is everybody who is
    /// not a reviewer — the server decides that, not this view, and there is
    /// no flag anywhere saying which one the hiker is. See
    /// ``CommunityReviewQueue`` for why that is the whole access control and
    /// why a failed load draws nothing rather than a row.
    ///
    /// Above the browse list rather than behind a third segment of
    /// ``listPicker``, because that picker is bound to
    /// ``CommunityBrowser/isBrowsing`` and a third case would need state of
    /// its own — which could then disagree with the browse session about which
    /// list is showing. A section is also the truthful shape: this is work
    /// waiting on the reviewer, and it belongs above the thing they would
    /// otherwise be doing rather than somewhere they have to go and look.
    @ViewBuilder var reviewSection: some View {
        if review.hasWork {
            Section {
                ForEach(review.pending) { pending in
                    Button {
                        onSelectPending(pending)
                    } label: {
                        // The row a published listing gets, drawn from what
                        // publishing would write — so the reviewer sees the
                        // row before deciding whether it should exist.
                        CommunityHikeRow(
                            listing: pending.prospectiveListing,
                            isImported: false
                        )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(review.pendingPhotos) { pending in
                    Button {
                        onSelectPendingPhotos(pending)
                    } label: {
                        pendingPhotosRow(pending)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                // On the header rather than the `Section`, and that is not a
                // detail: an identifier on a `Section` is inherited by every
                // element inside it, which silently replaced the rows' own
                // `community-hike-row` and made them unfindable as hikes.
                Text("Pending Review (\(review.workCount))")
                    .accessibilityIdentifier("community-review-section")
            }
        }
    }

    /// One queued contribution, which is deliberately **not** a
    /// ``CommunityHikeRow``.
    ///
    /// That row draws a hike: a title, a distance, a date and a photo count.
    /// A contribution has one of those four — and borrowing the row would mean
    /// inventing the other three, which is exactly the shape
    /// ``CommunityPendingPhotos/prospectiveListing`` warns against being read
    /// as a listing. So this row says the true short thing: somebody's photos,
    /// for a trail, from a walk on a day.
    func pendingPhotosRow(_ pending: CommunityPendingPhotos) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.badge.plus")
                .foregroundStyle(.secondary)
                // Decoration: the label below says which kind of row this is.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    pending.authorName.isEmpty
                        ? String(localized: "Photos for a trail")
                        : String(localized: "Photos from \(pending.authorName)")
                )
                .font(.body)
                Text(
                    pending.isCurated
                        ? String(
                            localized: """
                            For an OpenStreetMap trail · \
                            \(pending.takenOn.formatted(date: .abbreviated, time: .omitted))
                            """
                        )
                        : String(
                            localized: """
                            For a shared hike · \
                            \(pending.takenOn.formatted(date: .abbreviated, time: .omitted))
                            """
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("community-review-photos-row")
    }

    /// What the list is currently able to show.
    ///
    /// No opt-in row among them any more: reaching this list at all means the
    /// tab was selected, and that selection is the opt-in.
    /// The place the rows are about, and whether more are coming.
    ///
    /// Naming the area is the other half of taking the chip away. *Nearby*
    /// named the query and never the answer, so a hiker who had panned — or
    /// who opened the app somewhere they were not yesterday — had no way to
    /// tell which "here" the rows were from. See ``CommunityAreaNaming``.
    ///
    /// No *Hide* button in it any more: the off switch is the other segment of
    /// ``listPicker``, which is on screen at all times and says what it does.
    var communitySectionHeader: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            if community.state == .loading || community.state == .refreshing {
                ProgressView()
                    .accessibilityLabel("Loading community hikes")
            }
            Spacer(minLength: 0)
        }
        .textCase(nil)
    }

    /// "Community Hikes", or "Near Esztergom" once something has answered and
    /// MapKit has a name for where.
    ///
    /// Just the place, because the picker above it has already said
    /// *Community* — the heading's whole job here is the *where*. One string
    /// rather than two `Text`s so it is one spoken phrase: a heading read as
    /// two elements is read as two headings.
    var headerTitle: String {
        guard let areaName = community.areaName else {
            return String(localized: "Community Hikes")
        }
        return String(localized: "Near \(areaName)")
    }

    /// What a failed refresh says when there are still rows underneath it.
    ///
    /// Deliberately not the empty state's wording. Nothing here is missing —
    /// the hikes below are real and were true when they arrived — so this
    /// says what did not happen rather than what is not there, and the rows
    /// keep their meaning by being described rather than disowned.
    @ViewBuilder
    func communityRefreshFailureRow(_ failure: CommunityFailure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(failure.localizedDescription)
                    .font(.subheadline.weight(.medium))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("These are the hikes from the last search that worked.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try Again") { community.retry() }
                .glassButtonStyle()
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("community-refresh-failure")
    }

    /// Says which of the three empty answers this is.
    ///
    /// A failure, a search that is still running and an area with nothing in
    /// it all draw no rows, and telling them apart is the difference between
    /// "there are none here" and "this did not work" — which is the one the
    /// hiker can do something about.
    @ViewBuilder var communityEmptyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Before the state, deliberately. Zoomed out past the ceiling
            // nothing was asked, so *No community hikes here* would be a claim
            // about an area nobody looked at — and a spinner, for a hiker who
            // opted in while looking at a country, would be a promise of an
            // answer that is never coming.
            if community.areaPrompt == .zoomIn {
                Text("Zoom in to look here")
                    .font(.subheadline.weight(.medium))
                // Not *a whole country* any more, and deliberately not a
                // figure either. The old sentence described the old 150 km
                // ceiling; this one is OpenStreetMap's 40 km — see
                // ``CommunityQueryPolicy/maximumRadiusMeters`` — which a
                // regional view reaches long before a country does. Spelling
                // the distance instead would put a number in a string beside
                // a constant that owns it, and would owe the hiker their own
                // units on top.
                Text("This is wider than a search reaches.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                communityStateRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("community-nearby-empty")
    }

    @ViewBuilder var communityStateRow: some View {
        Group {
            switch community.state {
            case .failed(let failure):
                Text(failure.localizedDescription)
                    .font(.subheadline.weight(.medium))
                if let suggestion = failure.recoverySuggestion {
                    Text(suggestion)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("Try Again") { community.retry() }
                    .glassButtonStyle()
                    .padding(.top, 2)
            case .loading, .refreshing:
                Text("Looking for community hikes…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .idle, .loaded:
                Text("No community hikes here")
                    .font(.subheadline.weight(.medium))
                Text("Move the map and tap Search This Area to look somewhere else.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Why the pill above the map has gone quiet.
    ///
    /// Above ``CommunityQueryPolicy/maximumRadiusMeters`` a nearby result
    /// means "somewhere on this continent", so there is nothing worth asking
    /// and the *Search this area* pill is disabled. The pill itself stays on
    /// screen for the whole of this tab now, so this footer is what says
    /// *why* it cannot be tapped rather than merely standing in for a control
    /// that is missing — the same distinction the empty state above draws.
    @ViewBuilder var communitySectionFooter: some View {
        if community.areaPrompt == .zoomIn,
           !community.nearbyListings.isEmpty {
            Text("Zoom in to search somewhere else.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
        curatedCredit(for: community.nearbyListings)
    }

    /// The ODbL credit, drawn only when `listings` actually holds a curated
    /// route.
    ///
    /// Conditional is what makes it a credit rather than boilerplate: a list
    /// of hikes people published owes OpenStreetMap nothing. The *linked* form
    /// of the obligation is on the screen a row opens — see
    /// ``CommunityHikeView/curatedAttribution`` and ``TileAttribution``, which
    /// owns the argument for the whole app — because a footer under a
    /// scrolling list is not somewhere a link can be relied on to be seen, and
    /// the credit has to be reachable from the content it is about.
    ///
    /// Taken as a parameter rather than read off ``nearbyListings``, because
    /// the Community tab is not the only place a curated row appears: typing a
    /// name puts one in ``matchingListings``, and the credit is owed wherever
    /// the data is drawn rather than wherever the feature was introduced.
    @ViewBuilder
    func curatedCredit(for listings: [CommunityListing]) -> some View {
        if listings.contains(where: \.isCurated) {
            Text("Trail routes from OpenStreetMap contributors.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textCase(nil)
                .accessibilityIdentifier("community-osm-credit")
        }
    }

    /// Community matches in the search results, between the hiker's own hikes
    /// and MapKit's places.
    ///
    /// Second of the three deliberately: a trail already in the library is the
    /// one the hiker means when they half-type its name, and a place is a
    /// coarser answer than a hike.
    @ViewBuilder
    func communitySuggestionsSection() -> some View {
        if !community.matchingListings.isEmpty {
            Section {
                ForEach(community.matchingListings) { listing in
                    communityRowButton(listing)
                }
            } header: {
                Text("Community Hikes")
            } footer: {
                curatedCredit(for: community.matchingListings)
            }
        }
    }

    /// What the map found, kept visible underneath what the hiker typed.
    ///
    /// Last, because it answers a different question from the one in the
    /// field and must never look like an answer to it. Shown at all because
    /// the alternative was worse: while the section above was a mode, typing
    /// hid the map's results outright, so a query that matched nothing left
    /// the hiker looking at an empty list with eleven shared hikes on the
    /// map behind it.
    @ViewBuilder var nearbySuggestionsSection: some View {
        if community.isBrowsing, !community.nearbyListings.isEmpty {
            Section {
                ForEach(community.nearbyListings) { listing in
                    communityRowButton(listing)
                }
            } header: {
                Text("Near Here")
            } footer: {
                curatedCredit(for: community.nearbyListings)
            }
        }
    }
}
