//
//  PhotoMatchAvailability.swift
//  OpenHikes
//
//  Whether the photo section's caption can promise a library scan, kept from
//  one body pass to the next.
//
//  ``Hike/canMatchLibraryPhotos`` reads like a field and is not one. On a
//  route with no clock it walks every point looking for a timestamp, and on a
//  hike with walks it hashes every point for the route's revision as well —
//  six milliseconds a read on a 20,000-point trail. ``HikePhotoSection`` asks
//  it on every pass, and its passes are exactly the ones that change nothing it
//  depends on: taking or importing a photo writes `hike.photos`, which is the
//  write that section exists to absorb.
//
//  So the answer is kept with what it was worked out from — the route and the
//  finished walks — and worked out again only when one of those differs. The
//  comparison is the cost of a read: `Array`'s `==` stops at shared storage,
//  and a route written back unchanged still compares equal, which matters
//  because a `@Model` filters no same-value write. Synchronous rather than
//  prepared in a `.task`, so the pass that has the line already says the
//  right thing: the one pass that pays is the one whose inputs moved, which is
//  what it cost on every pass before.
//
//  The route is the one the hike's screen read off the main actor
//  (``ShownLine``), handed in, rather than the hike's own column: after any
//  save to the store, reading that column on the main actor decoded all of it
//  again (#1252).
//
//  The revision guard is untouched. A route edit changes the route the inputs
//  hold, so a walk along the old line is dropped by the same
//  ``Hike/walkPhotoTimelines`` rule it always was — this only stops asking
//  that rule the same question twice.
//

import Foundation
import OpenHikesData

/// The last answer to ``Hike/canMatchLibraryPhotos``, and what it was the
/// answer for. Held in the section's `@State` and never observed: nothing
/// draws from it except the body that asks, which already depends on the
/// route and the walks it reads to ask.
final class PhotoMatchAvailability {
    /// Everything the answer is derived from, by value.
    nonisolated struct Inputs: Equatable, Sendable {
        /// What a walk contributes: the line it names, its window, and what it
        /// covered — each of which decides whether it yields a timeline.
        nonisolated struct Walk: Equatable, Sendable {
            let id: UUID
            let routeRevision: String?
            let startedAt: Date
            let endedAt: Date
            let coveredIntervals: [Double]
            let furthestDistanceMeters: Double
        }

        let hikeID: UUID
        let route: [RouteCoordinate]
        let walks: [Walk]

        @MainActor
        init(_ hike: Hike, along route: [RouteCoordinate]) {
            hikeID = hike.id
            self.route = route
            walks = (hike.walks ?? []).map { walk in
                Walk(
                    id: walk.id,
                    routeRevision: walk.routeRevision,
                    startedAt: walk.startedAt,
                    endedAt: walk.endedAt,
                    coveredIntervals: walk.coveredIntervals,
                    furthestDistanceMeters: walk.furthestDistanceMeters
                )
            }
        }
    }

    private var prepared: (inputs: Inputs, canMatch: Bool)?
    /// The real question unless a suite counts how often it is asked.
    private let evaluate: (Hike, [RouteCoordinate]) -> Bool

    init(evaluate: @escaping (Hike, [RouteCoordinate]) -> Bool = { $0.canMatchLibraryPhotos(along: $1) }) {
        self.evaluate = evaluate
    }

    /// ``Hike/canMatchLibraryPhotos(along:)``, worked out again only when the
    /// route or the finished walks differ from the last time it was.
    func canMatchLibraryPhotos(_ hike: Hike, along route: [RouteCoordinate]) -> Bool {
        let inputs = Inputs(hike, along: route)
        if let prepared, prepared.inputs == inputs { return prepared.canMatch }
        let canMatch = evaluate(hike, route)
        prepared = (inputs, canMatch)
        return canMatch
    }
}
