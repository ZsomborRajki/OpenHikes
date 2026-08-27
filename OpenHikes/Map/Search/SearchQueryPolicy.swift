//
//  SearchQueryPolicy.swift
//  OpenHikes
//
//  Decides what the search field's latest contents should do to the
//  completer, separately from doing it.
//
//  It is its own type for the same reason `TileNetworkPolicy` is: the
//  interesting behaviour is the requests that must *not* be made — the echo
//  of a suggestion the user just tapped, and a fragment they have since
//  erased — and neither of those is visible in the result. `suggestions` is
//  empty in both cases, and empty is also what a request that simply hasn't
//  answered yet looks like. `MKLocalSearchCompleter` has no public way to
//  stub, and `MKLocalSearchCompletion` has no public initializer, so the
//  decision is the only part of this that can be held to anything.
//

import Foundation

/// What to do with the latest text in the search field.
enum SearchQueryAction: Equatable {
    /// Stop the completer and show nothing. The field is empty, so any answer
    /// still in flight is for a question that has been withdrawn.
    case cancel
    /// Do nothing at all. This is the echo of a suggestion the user tapped,
    /// which was already answered and already stopped.
    case ignore
    /// Ask for suggestions for this fragment.
    case request(String)
}

/// The little state machine behind ``SearchCompleter``: one remembered query,
/// and the trimming that decides whether the next one is the same question.
struct SearchQueryPolicy {
    /// The query the user committed to by tapping a suggestion, until
    /// something else is typed.
    private(set) var committedQuery: String?

    mutating func action(for query: String) -> SearchQueryAction {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            committedQuery = nil
            return .cancel
        }
        // Setting the search field to a tapped suggestion's title fires the
        // field's `onChange` one more time, and the completer would answer a
        // question the user has already stopped asking — a wasted round-trip
        // on the radio in the one screen whose brief is not spending power.
        guard trimmed != committedQuery else { return .ignore }
        committedQuery = nil
        return .request(trimmed)
    }

    /// Records `query` as already answered, so the echo of it arriving through
    /// ``action(for:)`` is not re-requested.
    mutating func commit(query: String) {
        committedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func reset() {
        committedQuery = nil
    }
}
