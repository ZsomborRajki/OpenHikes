//
//  SearchFailureTests.swift
//  OpenHikesTests
//
//  Place search used to fail silently: no network, a rate limit and a query
//  MapKit couldn't resolve all produced the same nothing, which reads as a
//  search field that has stopped working. What the user is told now is a pure
//  function of the error, so it can be tested without a network, a rate limit
//  or a SwiftUI hierarchy — which is exactly why it is a value type and not
//  a `switch` inside the `Task`.
//

import Foundation
import MapKit
@testable import OpenHikes
import Testing

@Suite("Search failure")
struct SearchFailureTests {
    /// The one case with its own copy: there is nothing wrong, the place just
    /// isn't there, and telling someone to "try again in a moment" would be
    /// advice that cannot work.
    @Test("a place that isn't there is reported as no results, not as a fault")
    func placemarkNotFoundIsNoResults() {
        let failure = SearchFailure(
            underlying: MKError(.placemarkNotFound)
        )

        #expect(failure.reason == .noResults)
        #expect(failure.recoverySuggestion?.contains("nearby town") == true)
    }

    @Test("a busy or failing server is reported as throttled")
    func serverErrorsAreThrottled() {
        #expect(SearchFailure(underlying: MKError(.loadingThrottled)).reason == .throttled)
        #expect(SearchFailure(underlying: MKError(.serverFailure)).reason == .throttled)
    }

    /// `MKError` folds transport failures into codes that say nothing about
    /// connectivity, so the `URLError` underneath is what distinguishes "you
    /// are offline" from "something went wrong".
    @Test(
        "a transport failure is reported as offline",
        arguments: [
            URLError.Code.notConnectedToInternet,
            .networkConnectionLost,
            .cannotConnectToHost,
            .cannotFindHost,
            .dataNotAllowed,
            .timedOut,
        ]
    )
    func transportFailuresAreOffline(code: URLError.Code) {
        let failure = SearchFailure(underlying: URLError(code))

        #expect(failure.reason == .offline)
        // The offline message has to say the app still works, because it does:
        // saved hikes and downloaded maps are the whole point.
        #expect(failure.recoverySuggestion?.contains("downloaded maps") == true)
    }

    /// A `URLError` that isn't about connectivity must not claim the user is
    /// offline — the advice would send them to check a connection that is
    /// fine.
    @Test("a non-transport URL error is not reported as offline")
    func otherURLErrorsAreUnavailable() {
        #expect(SearchFailure(underlying: URLError(.badURL)).reason == .unavailable)
    }

    @Test("an error from nowhere in particular is still reported")
    func unknownErrorsAreUnavailable() {
        struct Mystery: Error {}
        let failure = SearchFailure(underlying: Mystery())

        #expect(failure.reason == .unavailable)
        #expect(failure.errorDescription?.isEmpty == false)
    }

    /// Every reason has to carry both halves: `.alert(isPresented:error:)`
    /// draws `errorDescription` as the title and `recoverySuggestion` as the
    /// message, so a `nil` either side is a blank alert.
    @Test(
        "every reason has something to say",
        arguments: [
            SearchFailure.Reason.noResults,
            .offline,
            .throttled,
            .unavailable,
        ]
    )
    func everyReasonIsPresentable(reason: SearchFailure.Reason) {
        let failure = SearchFailure(reason: reason)

        #expect(failure.errorDescription?.isEmpty == false)
        #expect(failure.recoverySuggestion?.isEmpty == false)
    }
}
