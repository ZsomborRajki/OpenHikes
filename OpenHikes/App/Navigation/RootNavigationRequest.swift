//
//  RootNavigationRequest.swift
//  OpenHikes
//
//  What asks the root view to navigate from outside the view tree, read in
//  one loop: an intent or the record button asking for a hike, the maker's
//  pill, the camera pill's *Add Place*, and the end of a recording or a walk.
//
//  Each comes from an ``EventFeed`` of its own, and each used to have a task
//  of its own on the root view, four tasks with one lifetime writing the
//  same selection and the same sheet. They are one stream here, read by one
//  loop.
//
//  ## In the order they were sent
//
//  The requests have to be handled in the order they were sent, across the
//  feeds: *Make a Trail* and then a saved route's tap must end on the route,
//  because opening the maker clears the selection and replaces the sheet.
//  Reading each feed's own stream cannot promise that, whether with a task
//  for each stream or with `AsyncAlgorithms.merge`, as the weather loop
//  merges its wakes: each stream's reader is woken as the executor gets to
//  it. With the maker's request and then a hike's link sent, `merge` opened
//  the hike first in nearly every run, and a main-actor task for each
//  stream took each feed's second request after the others' first. So every
//  feed yields to the one stream as it sends — see
//  ``EventFeed/events(into:as:)`` — and the stream's order is the order of
//  the sends.
//
//  Nothing else about delivery changes. Every feed is joined before the
//  stream is read, so a message sent while the others join still reaches
//  it; the stream keeps every message, in order, until it is read; and
//  cancelling the reading task ends the loop, which takes each feed's part
//  out again.
//

import Foundation

/// One thing the root view is asked to do.
nonisolated enum RootNavigationRequest: Equatable, Sendable {
    /// A recording or a walk ended — see ``ActivityEnding``.
    case ending(ActivityEnding)
    /// Open this link, as a widget's tap would — see ``HikeOpenRequests``.
    case hike(URL)
    /// Open the trail maker.
    case maker
    /// Open *Add Place* for the photograph being taken.
    case place
}

extension RootNavigationRequest {
    /// Reads every request the feeds `join` joins, in the order it was sent,
    /// handing each to `handle`, until the reading task is cancelled.
    ///
    /// `join` hands each feed the stream's continuation and returns what
    /// takes each out again — see ``EventFeed/events(into:as:)``.
    static func read(
        joining join: (AsyncStream<Self>.Continuation) -> [@Sendable () -> Void],
        handle: (Self) -> Void
    ) async {
        let (requests, continuation) = AsyncStream<Self>.makeStream()
        let leaves = join(continuation)
        defer {
            for leave in leaves {
                leave()
            }
        }
        for await request in requests {
            handle(request)
        }
    }
}
