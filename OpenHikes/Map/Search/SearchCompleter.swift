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
    /// The last query the user committed to, by tapping a suggestion. See
    /// ``commit(query:)``.
    @ObservationIgnored private var committedQuery: String?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Feeds the latest query to the completer, or clears results when empty.
    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            committedQuery = nil
            suggestions = []
            return
        }
        // Setting the search field to a tapped suggestion's title fires the
        // field's `onChange` one more time, and the completer would answer a
        // question the user has already stopped asking — a wasted round-trip
        // on the radio in the one screen whose brief is not spending power.
        guard trimmed != committedQuery else { return }
        committedQuery = nil
        completer.queryFragment = trimmed
    }

    func clear() {
        committedQuery = nil
        completer.cancel()
        suggestions = []
    }

    /// Clears the suggestions and records `query` as already answered, so the
    /// echo of it arriving through ``update(query:)`` is not re-requested.
    func commit(query: String) {
        completer.cancel()
        committedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
