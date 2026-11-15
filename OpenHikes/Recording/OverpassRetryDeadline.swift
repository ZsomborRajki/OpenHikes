//
//  OverpassRetryDeadline.swift
//  OpenHikes
//
//  How long Overpass has asked the trail graph to leave it alone.
//
//  A launch has two trail graph providers — one that asks the pre-built
//  squares first, and the trail maker's, which routes over roads no square
//  holds (see `OpenHikesModel.makeTrailGraphProviders()`) — and Overpass sees
//  one address behind both. A `429` either of them earns has to stop the
//  other too, or a hike selected while the maker is refused asks again at
//  once, doubling the requests against a volunteer-run API. So the deadline
//  is not the provider's own: it is one of these, which the launch hands
//  both.
//

import Foundation
import Synchronization

/// The moment until which Overpass asked not to be asked, shared by the
/// providers that ask it for the trail graph.
///
/// A `final class` behind a `Mutex` rather than an actor, because it is read
/// and written from inside the providers' own actors, where a hop would be a
/// suspension for four lines.
nonisolated final class OverpassRetryDeadline: Sendable {
    private let until = Mutex<Date?>(nil)

    /// How long is left to wait at `now`, or `nil` when Overpass may be
    /// asked.
    func delay(at now: Date) -> TimeInterval? {
        until.withLock { until in
            guard let until, until > now else { return nil }
            return until.timeIntervalSince(now)
        }
    }

    /// Overpass asked for `delay` seconds from `now`: kept unless an earlier
    /// refusal asked for longer.
    func refuse(for delay: TimeInterval, at now: Date) {
        until.withLock { until in
            until = max(until ?? .distantPast, now.addingTimeInterval(delay))
        }
    }
}
