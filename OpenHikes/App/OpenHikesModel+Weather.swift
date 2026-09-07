//
//  OpenHikesModel+Weather.swift
//  OpenHikes
//
//  Keeping ``WeatherManager`` current for whatever the badge is about.
//
//  Its own file rather than a method on the model because it is a loop with a
//  policy, not a piece of coordination: what it costs is decided by
//  ``WeatherRequestState`` and ``WeatherPollingPolicy``, both of which are
//  pure and asserted directly, and this is only what drives them.
//
//  The loop used to be about the walker's position, waking on every accepted
//  fix and rounding it onto a grid to decide whether that position was news.
//  It is now about ``WeatherFocus/subject`` — see ``WeatherSubject`` for why —
//  and wakes on three things:
//
//  - the subject changed, because a recording started, a hike was selected or
//    a search resolved;
//  - the walker moved appreciably, via significant-change delivery, and the
//    subject is one that follows them;
//  - the reading for the current subject came due, which is one sleep to an
//    exact deadline re-armed after each pass rather than a tick.
//
//  Which of the three it was is carried into ``WeatherRequestState`` as a
//  ``WeatherRequestReason``, because they do not deserve the same answer: a
//  search the user just typed is owed a request now, and a cell handoff is
//  not.
//

import AsyncAlgorithms
import CoreLocation
import Foundation

/// Why the loop woke. Mapped onto ``WeatherRequestReason`` below; kept
/// separate because "the walker moved" also has to be *applied* to the focus
/// before anything is asked about it.
private enum WeatherWake: Sendable {
    case expiry
    case focus
    case movement
}

extension OpenHikesModel {
    func pollWeather(policy: WeatherPollingPolicy = .standard) async {
        var state = WeatherRequestState()
        let (dueDates, dueDatesContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var dueTask: Task<Void, Never>?
        defer {
            dueTask?.cancel()
            dueDatesContinuation.finish()
        }

        let wakes = merge(
            weatherFocus.subjects.map { _ in WeatherWake.focus },
            significantLocations.movements.map { _ in WeatherWake.movement },
            dueDates.map { _ in WeatherWake.expiry }
        )

        for await wake in wakes {
            // Applied before the subject is read, so a movement wake asks
            // about where the walker is now rather than where they were.
            // `walkerMoved` is a no-op for a searched place, and
            // `defaultToWalker` only lands when nothing else has claimed the
            // subject — the precedence lives in `WeatherFocus`, not here.
            if wake == .movement, let coordinate = significantLocations.coordinate {
                weatherFocus.defaultToWalker(at: coordinate)
                weatherFocus.walkerMoved(to: coordinate)
            }

            guard let subject = weatherFocus.subject else { continue }
            let key = subject.key
            let willRequest = state.shouldRequest(
                key: key,
                reason: wake.requestReason,
                at: .now,
                policy: policy
            )
            // Every pass, not only the ones that fetch: this is what carries a
            // changed subject — a new city, or `me` with a new coordinate — to
            // the badge, and what decides between a spinner and a plain
            // "unavailable" when the backoff has ruled a request out.
            weatherManager.focus(on: subject, willRequest: willRequest)

            if willRequest {
                if await weatherManager.update(for: subject) {
                    state.recordSuccess(key: key, at: .now)
                } else {
                    state.recordFailure(key: key, at: .now, policy: policy)
                }
            }

            // Re-armed against whatever the subject is *now*, which after an
            // await may not be the one this pass started with. Cancelling
            // first is what stops a subject the user has moved on from
            // waking the loop on its own deadline.
            dueTask?.cancel()
            guard let currentKey = weatherFocus.subject?.key,
                  let due = state.nextEligibleDate(key: currentKey, policy: policy) else { continue }
            dueTask = Task {
                try? await Task.sleep(until: .now + .seconds(max(0, due.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                dueDatesContinuation.yield(())
            }
        }
    }
}

private extension WeatherWake {
    var requestReason: WeatherRequestReason {
        switch self {
        case .expiry: .expiry
        case .focus: .focus
        case .movement: .movement
        }
    }
}
