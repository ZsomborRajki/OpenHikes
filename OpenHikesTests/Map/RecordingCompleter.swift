//
//  RecordingCompleter.swift
//  OpenHikesTests
//
//  The `MKLocalSearchCompleter` that ``SearchCompleter`` is handed in the
//  suites that drive it: it keeps the fragments and regions it is given and
//  never passes them on, so nothing reaches Apple. Shared by
//  ``SearchCompleterFragmentTests`` and ``SearchCompleterRegionTests``.
//

import MapKit

/// Keeps what it is told instead of asking MapKit. `nonisolated` because
/// the members it overrides are, and this target defaults to the main actor.
nonisolated final class RecordingCompleter: MKLocalSearchCompleter {
    private(set) var fragmentsAsked: [String] = []
    private(set) var regionsAssigned = 0
    private var storedFragment = ""
    private var storedRegion = MKCoordinateRegion()
    /// What a delegate callback reads, set by the test that fakes one.
    var cannedResults: [MKLocalSearchCompletion] = []

    override var queryFragment: String {
        get { storedFragment }
        set {
            storedFragment = newValue
            if !newValue.isEmpty { fragmentsAsked.append(newValue) }
        }
    }

    override var region: MKCoordinateRegion {
        get { storedRegion }
        set {
            storedRegion = newValue
            regionsAssigned += 1
        }
    }

    override var results: [MKLocalSearchCompletion] { cannedResults }

    override func cancel() {
        // Nothing was ever sent, so there is nothing to stop.
    }
}
