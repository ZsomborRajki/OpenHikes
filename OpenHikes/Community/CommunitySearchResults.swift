import SwiftUI

/// Both search states have a visible outcome, including failures with no rows.
struct CommunitySearchResults: View {
    let browser: CommunityBrowser
    let query: String
    let usesArea: Bool
    let importedIDs: Set<String>
    let onSelect: (CommunityListing) -> Void

    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var listings: [CommunityListing] { hasQuery ? browser.matchingListings : browser.nearbyListings }
    private var state: CommunityBrowseState { hasQuery ? browser.matchingState : browser.state }

    var body: some View {
        RenderSignpost.mark("CommunitySearchResultsBody")
        return Section(usesArea ? "Community" : "Community · Anywhere") {
            if usesArea, browser.needsZoom {
                Text("Zoom in or choose a place to search for community hikes.")
                    .accessibilityIdentifier("community-zoom-message")
            } else if usesArea, browser.areaChoice == .anywhere, !hasQuery {
                Text("Enter a hike name to search anywhere, or choose an area to browse.")
            } else {
                requestStatus
                ForEach(listings) { listing in
                    Button { onSelect(listing) } label: {
                        CommunityHikeRow(listing: listing, isImported: importedIDs.contains(listing.id))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var requestStatus: some View {
        switch state {
        case .loading, .refreshing:
            ProgressView("Searching community hikes…")
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.localizedDescription)
                    .accessibilityIdentifier("community-search-failure")
                if let suggestion = failure.recoverySuggestion { Text(suggestion).font(.subheadline) }
                Button("Try Again") {
                    if hasQuery { browser.retryTitleSearch() } else { browser.retry() }
                }
                .buttonStyle(.bordered)
            }
        case .loaded:
            if listings.isEmpty {
                Text(hasQuery ? "No community hikes match this search." : "No community hikes in this area.")
                    .accessibilityIdentifier("community-search-empty")
                if usesArea { Text("Try another area or a different hike name.").font(.subheadline) }
            }
        case .idle:
            if listings.isEmpty { Text("Choose an area to browse community hikes.") }
        }
    }
}
