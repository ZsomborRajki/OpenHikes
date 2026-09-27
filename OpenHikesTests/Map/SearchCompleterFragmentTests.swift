//
//  SearchCompleterFragmentTests.swift
//  OpenHikesTests
//
//  A finished search has to leave the completer with nothing to ask. MapKit
//  answers a set `queryFragment` again whenever `region` is assigned, and the
//  search a tapped suggestion or a typed Return starts moves the camera, so a
//  fragment left set after either was asked again at the settle — network
//  work for a search that had ended, and a stale list waiting for the field
//  to be focused again (#755).
//
//  `MKLocalSearchCompleter` is subclassed rather than wrapped: the subclass
//  records the fragments and regions it is given and never passes them on,
//  so nothing here reaches Apple, and ``SearchQueryPolicyTests`` keeps the
//  decisions this sits on top of.
//

import CoreLocation
import MapKit
@testable import OpenHikes
import Testing

/// Keeps what it is told instead of asking MapKit. `nonisolated` because
/// the members it overrides are, and this target defaults to the main actor.
nonisolated private final class RecordingCompleter: MKLocalSearchCompleter {
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

@MainActor
@Suite("Search completer fragment")
struct SearchCompleterFragmentTests {
    private let recorder = RecordingCompleter()
    private let completer: SearchCompleter

    init() {
        completer = SearchCompleter(completer: recorder)
    }

    private static func region(latitude: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: 12.86),
            span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
        )
    }

    @Test("a fragment the hiker is typing is handed to MapKit")
    func typingAsks() {
        completer.update(query: "Königs")

        #expect(recorder.fragmentsAsked == ["Königs"])
        #expect(recorder.queryFragment == "Königs")
    }

    /// The tapped-suggestion path: the field is set to the suggestion's
    /// title, which echoes back through `update(query:)`, and the camera then
    /// flies to the answer and settles.
    @Test("a chosen suggestion leaves nothing for the camera's settle to re-ask")
    func chosenSuggestionEndsTheFragment() {
        completer.update(query: "Königs")
        completer.commit(query: "Königssee")
        completer.update(query: "Königssee")
        completer.regionDidSettle(Self.region(latitude: 47.55))

        #expect(recorder.queryFragment.isEmpty, "a set fragment is asked again by the region assignment")
        #expect(recorder.fragmentsAsked == ["Königs"], "the committed title's echo is not a new question")
        #expect(recorder.regionsAssigned == 1, "the settle still biases the next search")
        #expect(completer.suggestions.isEmpty)
    }

    /// The Return path: the field keeps what was typed, and `MapSheet`
    /// commits it before its search moves the camera.
    @Test("a typed Return leaves nothing for the camera's settle to re-ask")
    func returnEndsTheFragment() {
        completer.update(query: "Watzmann")
        completer.commit(query: "Watzmann")
        completer.regionDidSettle(Self.region(latitude: 47.55))
        completer.regionDidSettle(Self.region(latitude: 47.56))

        #expect(recorder.queryFragment.isEmpty)
        #expect(recorder.fragmentsAsked == ["Watzmann"])
    }

    /// An answer MapKit had already queued when the search ended would
    /// otherwise land in the list and wait there for the field to refocus.
    @Test("an answer arriving after the search ended does not refill the list")
    func lateAnswerIsDropped() {
        recorder.cannedResults = [MKLocalSearchCompletion()]
        completer.update(query: "Watzmann")
        completer.completerDidUpdateResults(recorder)
        #expect(completer.suggestions.count == 1, "an answer to the live fragment is shown")

        completer.commit(query: "Watzmann")
        completer.completerDidUpdateResults(recorder)

        #expect(completer.suggestions.isEmpty)
    }

    /// Refocusing the field does not change its text, so nothing reaches
    /// `update(query:)` — but anything typed afterwards is a real question.
    @Test("a new query after a finished search is asked")
    func newQueryAfterwardsAsks() {
        completer.update(query: "Watzmann")
        completer.commit(query: "Watzmann")
        completer.update(query: "Watzmann Hocheck")

        #expect(recorder.fragmentsAsked == ["Watzmann", "Watzmann Hocheck"])
        #expect(recorder.queryFragment == "Watzmann Hocheck")
    }
}
