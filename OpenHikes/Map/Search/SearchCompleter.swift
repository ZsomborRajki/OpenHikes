//
//  SearchCompleter.swift
//  OpenHikes
//
//  A thin wrapper around MapKit's MKLocalSearchCompleter that streams
//  autocomplete suggestions for the search bar as the query changes.
//

import MapKit
import Observation
import os

@Observable
final class SearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    @ObservationIgnored private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "Search"
    )

    /// Live autocomplete suggestions for the current query fragment.
    var suggestions: [MKLocalSearchCompletion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    /// Whether the next query is worth asking. See ``SearchQueryPolicy``.
    @ObservationIgnored private var policy = SearchQueryPolicy()

    /// Where the map came to rest, for the typed-Return search to bias itself
    /// to as well — see ``MapSheet/performSearch()``.
    ///
    /// `@ObservationIgnored`, and read only from a search that a tap or a
    /// Return started. Nothing observes it, for the same render-isolation
    /// reason ``CommunityBrowser`` keeps its own region off every SwiftUI
    /// body: it is written on every settle, which is as often as a hiker can
    /// stop panning.
    @ObservationIgnored private(set) var region: MKCoordinateRegion?

    override init() {
        super.init()
        completer.delegate = self
        // Physical features are the peaks, passes, lakes and valleys a hiker
        // actually types — "Watzmann", "Königssee" — and without them the
        // completer offers the hotel named after the mountain rather than the
        // mountain. `MapSheet.performSearch()` asks for the same three.
        completer.resultTypes = [.address, .pointOfInterest, .physicalFeature]
        // `.default` rather than `.required`: a hiker searching for a trail
        // they are about to drive to should still be able to reach it, so this
        // ranks the visible map up rather than fencing the answer inside it.
        completer.regionPriority = .default
    }

    /// The map came to rest. Called from `MapView.Coordinator`, never from a
    /// SwiftUI body — the same hand-over, from the same call site, that
    /// ``CommunityBrowser/regionDidSettle(_:)`` takes.
    ///
    /// Without it both halves of place search are answered globally, and a
    /// common name typed on a trail in Bavaria — "Blue Lake", "Bergsee",
    /// "Ridge Trail" — can fly the camera, and the weather badge with it, to
    /// the other side of the planet.
    func regionDidSettle(_ region: MKCoordinateRegion) {
        self.region = region
        // Assigning `region` while a query fragment is outstanding makes
        // MapKit answer it again, so a settle that did not move the map is
        // worth not forwarding. A pan during typing is rare; a redundant
        // settle is not.
        guard !Self.isEquivalent(completer.region, region) else { return }
        completer.region = region
    }

    /// Whether two regions are close enough that re-asking would return the
    /// same suggestions. Exact `==` is not available on `MKCoordinateRegion`,
    /// and floating-point drift in the last decimal places is not a move.
    private static func isEquivalent(
        _ lhs: MKCoordinateRegion,
        _ rhs: MKCoordinateRegion
    ) -> Bool {
        let tolerance = 1e-6
        return abs(lhs.center.latitude - rhs.center.latitude) < tolerance
            && abs(lhs.center.longitude - rhs.center.longitude) < tolerance
            && abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < tolerance
            && abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < tolerance
    }

    /// Feeds the latest query to the completer, or clears results when empty.
    func update(query: String) {
        switch policy.action(for: query) {
        case .cancel:
            // Cancelled rather than merely blanked: an answer already in
            // flight for the fragment the user has just erased would arrive
            // through `completerDidUpdateResults` and refill the list under an
            // empty field.
            completer.cancel()
            suggestions = []
        case .ignore:
            break
        case .request(let fragment):
            completer.queryFragment = fragment
        }
    }

    func clear() {
        policy.reset()
        completer.cancel()
        suggestions = []
    }

    /// Clears the suggestions and records `query` as already answered, so the
    /// echo of it arriving through ``update(query:)`` is not re-requested.
    func commit(query: String) {
        completer.cancel()
        policy.commit(query: query)
        suggestions = []
    }

    // MapKit calls these on the main thread, and as of the iOS 26 SDK it also
    // says so: `MKLocalSearchCompleterDelegate` is `@MainActor`, so a
    // main-actor method satisfies the requirement outright. This conformance
    // used to need `@preconcurrency` to bridge a `nonisolated` requirement,
    // which cost a runtime isolation check on every callback; before that it
    // was a hand-written `MainActor.assumeIsolated`. Both are now unnecessary
    // — the compiler proves statically what they asserted dynamically.
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Showing nothing is the right answer for the user — a suggestion list
        // is a convenience, and an error where a place name should be is
        // noise. Dropping the error entirely is not: a completer that starts
        // failing systematically (no network, a rate limit, a query MapKit
        // won't take) would otherwise leave no trace anywhere.
        Self.logger.debug(
            "Search completion failed: \(error.localizedDescription, privacy: .public)"
        )
        suggestions = []
    }
}
