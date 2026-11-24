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
//  same selection and the same sheet. They are merged here instead, as the
//  weather loop merges its wakes (`OpenHikesModel+Weather.swift`).
//
//  Nothing about delivery changes. Each feed's stream is asked for before
//  any is read, as the arguments of ``read(hikeLinks:makerRequests:placeRequests:endings:handle:)``,
//  so a message sent while the others are set up still reaches this reader;
//  each keeps every message it is sent, in order, until it is read; and
//  cancelling the reading task ends every stream, which takes each reader
//  out of its feed.
//

import AsyncAlgorithms
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
    /// Reads the four feeds' streams in one loop, handing each request to
    /// `handle` as it comes, until the reading task is cancelled.
    static func read(
        hikeLinks: AsyncStream<URL>,
        makerRequests: AsyncStream<Void>,
        placeRequests: AsyncStream<Void>,
        endings: AsyncStream<ActivityEnding>,
        handle: (Self) -> Void
    ) async {
        // Nested because `merge` takes at most three.
        let requests = merge(
            hikeLinks.map { Self.hike($0) },
            merge(
                makerRequests.map { _ in Self.maker },
                placeRequests.map { _ in Self.place }
            ),
            endings.map { Self.ending($0) }
        )
        for await request in requests {
            handle(request)
        }
    }
}
