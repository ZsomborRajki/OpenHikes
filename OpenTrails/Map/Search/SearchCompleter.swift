//
//  SearchCompleter.swift
//  OpenTrails
//
//  A thin wrapper around MapKit's MKLocalSearchCompleter that streams
//  autocomplete suggestions for the search bar as the query changes.
//

import MapKit
import Observation

@Observable
final class SearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
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

    // MapKit calls these on the main thread.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { suggestions = completer.results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { suggestions = [] }
    }
}
