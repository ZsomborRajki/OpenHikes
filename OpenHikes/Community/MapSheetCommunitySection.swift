//
//  MapSheetCommunitySection.swift
//  OpenHikes
//
//  The shared hikes, where the walker's own list already is.
//
//  Split out of `MapSheetHikes.swift` rather than living beside the rest of
//  the sheet, for the reason `OpenHikesView+Photos.swift` is split out of its
//  own view: this is a self-contained half of one screen, and the file it came
//  from is already the one place `@Query` lands. Nothing about the split is
//  behavioural — these are still members of ``MapSheetHikes``, inlined into
//  its body like any other computed property, and the render-isolation note in
//  that file's header covers them.
//
//  What is here is the section that replaced the *Nearby* chip. The chip was a
//  mode: tapping it swapped the hikes list for a list of published ones, so
//  one question — where shall I walk? — became two screens to choose between,
//  and the same records appeared under two different headings depending on how
//  they had been found. This is a section of the same list instead, offered by
//  a single row until somebody asks for it, so nothing about the feature
//  reaches the network for a walker who never does.
//

import SwiftUI

/// The opt-in row's glyph, sized to ``CommunityHikeRow``'s own so the row that
/// offers the section and the rows that fill it line up.
private enum CommunityRowMetrics {
    static let glyphFrameSize: CGFloat = 38
    static let glyphPointSize: CGFloat = 16
}

extension MapSheetHikes {
    /// Listing ids this walker has already imported.
    ///
    /// Derived from the query that is already loaded rather than fetched: the
    /// hikes are in memory either way, and a second `@Query` filtered on the
    /// column would be a second invalidation source for this body.
    var importedListingIDs: Set<String> {
        Set(hikes.compactMap(\.importedFromListingID))
    }

    /// Published hikes, as a section of the walker's own list.
    ///
    /// A section rather than the mode this used to be. The *Nearby* chip
    /// replaced the hikes list wholesale, which made one question — where
    /// shall I walk? — into two screens the walker had to choose between, and
    /// put the same records under two different headings depending on how
    /// they were found. Here the shared hikes sit under the walker's own,
    /// where a scroll reaches them.
    ///
    /// Absent entirely when this launch has no transport — a hosted suite or
    /// UI automation — rather than shown empty, for the same reason the share
    /// button is.
    @ViewBuilder var communitySection: some View {
        if community.hasTransport {
            Section {
                communitySectionContent
            } header: {
                communitySectionHeader
            } footer: {
                communitySectionFooter
            }
        }
    }

    /// What the section is currently able to show.
    @ViewBuilder var communitySectionContent: some View {
        if !community.isBrowsing {
            communityOptInRow
        } else if community.nearbyListings.isEmpty {
            communityEmptyRow
        } else {
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

    /// The heading, and the place it is about.
    ///
    /// Naming the area is the other half of taking the chip away. *Nearby*
    /// named the query and never the answer, so a walker who had panned — or
    /// who opened the app somewhere they were not yesterday — had no way to
    /// tell which "here" the rows were from. See ``CommunityAreaNaming``.
    var communitySectionHeader: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            if community.state == .loading || community.state == .refreshing {
                ProgressView()
                    .accessibilityLabel("Loading shared hikes")
            }
            Spacer(minLength: 0)
            if community.isBrowsing {
                // The off switch the chip used to be. Kept because turning
                // something on is only half a decision, and a walker who has
                // seen what is here should be able to put the section away —
                // it takes the map's pins with it.
                Button("Hide") { community.stopBrowsing() }
                    .font(.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    // A four-letter word is not a tap target. The audits
                    // measure every control the same way, whatever it is made
                    // of — see ``minimumTapTarget()``.
                    .minimumTapTarget()
                    .accessibilityLabel("Hide shared hikes")
                    .accessibilityIdentifier("community-hide-button")
            }
        }
        .textCase(nil)
    }

    /// "Shared Hikes", or "Shared Hikes · near Esztergom" once something has
    /// answered and MapKit has a name for where.
    ///
    /// One string rather than two `Text`s so it is one spoken phrase: a
    /// heading read as two elements is read as two headings.
    var headerTitle: String {
        guard community.isBrowsing, let areaName = community.areaName else {
            return String(localized: "Shared Hikes")
        }
        return String(localized: "Shared Hikes · near \(areaName)")
    }

    /// The one thing the section says before it has ever been asked anything.
    ///
    /// This is where the feature's energy bargain now lives, and it is the
    /// same bargain the chip made: until this row is tapped nothing about
    /// community hikes reaches the network — no query, no geocode, no pins.
    /// See ``CommunityQueryPolicy``'s third reason to refuse.
    var communityOptInRow: some View {
        Button {
            community.startBrowsing()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "figure.hiking")
                    .font(.system(size: CommunityRowMetrics.glyphPointSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(
                        width: CommunityRowMetrics.glyphFrameSize,
                        height: CommunityRowMetrics.glyphFrameSize
                    )
                    .background(.tint, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find shared hikes near here")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Trails other walkers have published")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("community-find-nearby")
        }
        .buttonStyle(.plain)
    }

    /// Says which of the three empty answers this is.
    ///
    /// A failure, a search that is still running and an area with nothing in
    /// it all draw no rows, and telling them apart is the difference between
    /// "there are none here" and "this did not work" — which is the one the
    /// walker can do something about.
    @ViewBuilder var communityEmptyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Before the state, deliberately. Zoomed out past the ceiling
            // nothing was asked, so *No shared hikes here* would be a claim
            // about an area nobody looked at — and a spinner, for a walker who
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
                Text("Looking for shared hikes…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .idle, .loaded:
                Text("No shared hikes here")
                    .font(.subheadline.weight(.medium))
                Text("Move the map and tap Search This Area to look somewhere else.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The one thing the map cannot offer as a button.
    ///
    /// Above ``CommunityQueryPolicy/maximumRadiusMeters`` a nearby result
    /// means "somewhere on this continent", so there is nothing worth asking
    /// and the *Search this area* pill stays down. Saying so here is what
    /// stops that reading as a feature that has quietly stopped working — the
    /// same distinction the empty state above draws.
    @ViewBuilder var communitySectionFooter: some View {
        if community.isBrowsing,
           community.areaPrompt == .zoomIn,
           !community.nearbyListings.isEmpty {
            Text("Zoom in to search somewhere else.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }

    /// Community matches in the search results, between the walker's own hikes
    /// and MapKit's places.
    ///
    /// Second of the three deliberately: a trail already in the library is the
    /// one the walker means when they half-type its name, and a place is a
    /// coarser answer than a hike.
    @ViewBuilder
    func communitySuggestionsSection(matchingHikes: [Hike]) -> some View {
        if !community.matchingListings.isEmpty {
            Section("Shared Hikes") {
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

    /// What the map found, kept visible underneath what the walker typed.
    ///
    /// Last, because it answers a different question from the one in the
    /// field and must never look like an answer to it. Shown at all because
    /// the alternative was worse: while the section above was a mode, typing
    /// hid the map's results outright, so a query that matched nothing left
    /// the walker looking at an empty list with eleven shared hikes on the
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
