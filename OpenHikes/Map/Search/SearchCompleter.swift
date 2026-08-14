//
//  SearchCompleter.swift
//  OpenHikes
//
//  A thin wrapper around MapKit's MKLocalSearchCompleter that streams
//  autocomplete suggestions for the search bar as the query changes.
//

import MapKit
import Observation

@Observable
final class SearchCompleter: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    /// Live autocomplete suggestions for the current query fragment.
    var suggestions: [MKLocalSearchCompletion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Feeds the latest query to the completer, or clears results when empty.
    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            return
        }
        completer.queryFragment = trimmed
    }

    func clear() {
        suggestions = []
    }

    // MapKit calls these on the main thread, which is what the `@preconcurrency`
    // conformance above asserts: the requirements are declared `nonisolated`,
    // so satisfying them with main-actor methods installs a runtime check
    // instead of the hand-written `MainActor.assumeIsolated` this used to
    // carry. That matters beyond tidiness — sending a non-`Sendable`
    // `MKLocalSearchCompleter` (and its results) across the closure boundary
    // was itself a data-race diagnostic under strict concurrency.
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
    }
}
