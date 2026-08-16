//
//  SearchFailure.swift
//  OpenHikes
//
//  What the user is told when a place search comes back with an error rather
//  than a region. Previously they were told nothing at all, which reads as a
//  search field that has quietly stopped working.
//

import Foundation
import MapKit

/// A failed `MKLocalSearch`, in the terms the user needs rather than MapKit's.
///
/// A pure value built from the `Error` at the call site, so the mapping from
/// MapKit's codes to copy is testable without a network, a rate limit or a
/// SwiftUI hierarchy — which is what the search path lacked.
nonisolated struct SearchFailure: LocalizedError, Equatable, Sendable {
    /// The distinctions worth telling apart. MapKit reports far more codes
    /// than these; anything else is ``unavailable``, because "try again" is
    /// the only honest advice for a failure the app cannot name.
    enum Reason: Equatable, Sendable {
        /// The search worked and there is nothing there.
        case noResults
        /// The request never left the device usefully — no route to a server.
        case offline
        /// The server asked us to slow down.
        case throttled
        /// Anything else, including errors MapKit does not document.
        case unavailable
    }

    let reason: Reason

    init(reason: Reason) {
        self.reason = reason
    }

    init(underlying error: Error) {
        self.init(reason: Self.reason(for: error))
    }

    /// Classifies MapKit's error, falling back to `URLError` for the transport
    /// failures `MKError` folds into `.unknown`.
    private static func reason(for error: Error) -> Reason {
        if let mapKitError = error as? MKError {
            switch mapKitError.code {
            case .placemarkNotFound: return .noResults
            case .serverFailure, .loadingThrottled: return .throttled
            default: break
            }
        }
        guard let urlError = error as? URLError else { return .unavailable }
        return Self.offlineURLErrorCodes.contains(urlError.code)
            ? .offline
            : .unavailable
    }

    /// The transport failures that mean "there is no usable connection", as
    /// opposed to a server that answered with something unhelpful.
    private static let offlineURLErrorCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .networkConnectionLost,
        .cannotConnectToHost,
        .cannotFindHost,
        .dataNotAllowed,
        .timedOut,
    ]

    var errorDescription: String? {
        switch reason {
        case .noResults:
            String(localized: "No places matched that search.")
        case .offline:
            String(localized: "Couldn't search for places.")
        case .throttled:
            String(localized: "Couldn't search for places.")
        case .unavailable:
            String(localized: "Couldn't search for places.")
        }
    }

    var recoverySuggestion: String? {
        switch reason {
        case .noResults:
            String(localized: "Try a different name, or a nearby town.")
        case .offline:
            String(localized: "You appear to be offline. Saved hikes and downloaded maps still work.")
        case .throttled:
            String(localized: "The map search service is busy. Try again in a moment.")
        case .unavailable:
            String(localized: "Try again in a moment.")
        }
    }
}
