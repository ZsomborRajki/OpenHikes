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

    /// Listing ids this hiker has already imported.
    ///
    /// Derived from the query that is already loaded rather than fetched: the
    /// hikes are in memory either way, and a second `@Query` filtered on the
    /// column would be a second invalidation source for this body.
    var importedListingIDs: Set<String> {
        Set(hikes.compactMap(\.importedFromListingID))
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
            Section {
                communitySectionContent
            } header: {
                communitySectionHeader
            } footer: {
                communitySectionFooter
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
        if !review.pending.isEmpty {
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
            } header: {
                // On the header rather than the `Section`, and that is not a
                // detail: an identifier on a `Section` is inherited by every
                // element inside it, which silently replaced the rows' own
                // `community-hike-row` and made them unfindable as hikes.
                Text("Pending Review (\(review.pending.count))")
                    .accessibilityIdentifier("community-review-section")
            }
        }
    }

    /// What the list is currently able to show.
    ///
    /// No opt-in row among them any more: reaching this list at all means the
    /// tab was selected, and that selection is the opt-in.
    @ViewBuilder var communitySectionContent: some View {
        if community.nearbyListings.isEmpty {
            communityEmptyRow
        } else {
            // A failure over rows that are still on screen. The empty state
            // below is the only place a failure used to be reported, so a
            // refresh that failed on top of a good list said nothing at all —
            // and since the rows are deliberately kept, the section looked
            // like it had simply answered. It has not: these are the previous
            // area's hikes, and the header says so.
            if case .failed(let failure) = community.state {
                communityRefreshFailureRow(failure)
            }
            ForEach(community.nearbyListings) { listing in
                Button {
                    onSelectListing(listing)
                } label: {
                    CommunityHikeRow(
                        listing: listing,
                        isImported: importedListingIDs.contains(listing.id)
                    )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

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
                .buttonStyle(.bordered)
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
                Text("A whole country is too wide to search.")
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
                    .buttonStyle(.bordered)
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
            Section("Community Hikes") {
                ForEach(community.matchingListings) { listing in
                    Button { onSelectListing(listing) } label: {
                        CommunityHikeRow(
                            listing: listing,
                            isImported: importedListingIDs.contains(listing.id)
                        )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
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
            Section("Near Here") {
                ForEach(community.nearbyListings) { listing in
                    Button { onSelectListing(listing) } label: {
                        CommunityHikeRow(
                            listing: listing,
                            isImported: importedListingIDs.contains(listing.id)
                        )
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
