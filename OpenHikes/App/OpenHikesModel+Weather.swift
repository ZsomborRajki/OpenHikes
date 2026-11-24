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
//  The loop used to be about the hiker's position, waking on every accepted
//  fix and rounding it onto a grid to decide whether that position was news.
//  It is now about ``WeatherFocus/subject`` — see ``WeatherSubject`` for why —
//  and wakes on four things:
//
//  - the subject changed, because a recording started, a hike was selected or
//    a search resolved;
//  - the hiker moved appreciably, via significant-change delivery, and the
//    subject is one that follows them;
//  - the reading for the current subject came due, which is one sleep to an
//    exact deadline re-armed after each pass rather than a tick;
//  - a walk or a recording started or ended, which asks for nothing and only
//    re-reads the badge for a severe-weather alert that has just become the
//    hiker's — see ``WeatherAlertSession``.
//
//  Which of the first three it was is carried into ``WeatherRequestState`` as
//  a ``WeatherRequestReason``, because they do not deserve the same answer: a
//  search the user just typed is owed a request now, and a cell handoff is
//  not.
//
//  **A request runs beside the loop, not in it.** Awaited in place, a
//  forecast that stalled for one trail held the loop there: opening another
//  trail could not move the badge, not even to a reading already cached for
//  it, and when the first answer finally landed it went on the badge over
//  the trail the hiker was looking at. So each request is a task of its
//  own, one per subject, whose answer comes back to the loop as a fifth
//  wake to be counted against that subject's freshness or backoff — and
//  ``WeatherManager/update(for:inFront:)`` shows it only if its subject is
//  still the one in front.
//
//  The requests are children of a task group around the loop, rather than
//  tasks of their own, so that cancelling the poll cancels them at once. The
//  loop can be held in a notification prompt — see
//  ``WeatherManager/announceStandingAlerts(during:asOf:)`` — and a request
//  left running until the hiker answered it would still move the badge for
//  a poll that is gone.
//

import AsyncAlgorithms
import CoreLocation
import Foundation

/// Why the loop woke. Mapped onto ``WeatherRequestReason`` below; kept
/// separate because "the hiker moved" also has to be *applied* to the focus
/// before anything is asked about it.
private enum WeatherWake: Sendable {
    /// A request the loop sent came back — see this file's header.
    case answered(WeatherAnswer)
    case expiry
    case focus
    case movement
    case session
}

/// What one request came back with, for the loop to record against its
/// subject.
private struct WeatherAnswer: Sendable {
    let key: String
    let succeeded: Bool
    let at: Date
}

extension OpenHikesModel {
    /// Whether the hiker is out in the weather, and on what — the gate on the
    /// severe-weather banner.
    ///
    /// A recording first, because the two never run together and the
    /// recorder is the one that pins the badge.
    var weatherAlertSession: WeatherAlertSession {
        if hikeRecorder.isActive { return .recording }
        if let hikeID = walkSession.walkedHikeID { return .walking(hikeID: hikeID) }
        return .browsing
    }

    func pollWeather(policy: WeatherPollingPolicy = .standard) async {
        var state = WeatherRequestState()
        let (dueDates, dueDatesContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let (answers, answersContinuation) = AsyncStream<WeatherAnswer>.makeStream()
        var dueTask: Task<Void, Never>?
        // The subjects whose request is out: one each, so a subject the hiker
        // comes back to while its forecast is on its way is not asked twice.
        var asking: Set<String> = []
        defer {
            dueTask?.cancel()
            dueDatesContinuation.finish()
            answersContinuation.finish()
        }

        // Nested because `merge` takes at most three. The session is
        // de-duplicated because `isActive` reads the recorder's phase, and a
        // pause or a resume is not a session starting.
        let wakes = merge(
            weatherFocus.subjects.map { _ in WeatherWake.focus },
            merge(
                significantLocations.movements.map { _ in WeatherWake.movement },
                answers.map { WeatherWake.answered($0) }
            ),
            merge(
                dueDates.map { _ in WeatherWake.expiry },
                observedValues { self.weatherAlertSession }
                    .removeDuplicates()
                    .map { _ in WeatherWake.session }
            )
        )

        // The requests are the group's — see this file's header. Cancelled,
        // a request's answer reaches nothing: see
        // ``WeatherManager/update(for:inFront:)``.
        await withDiscardingTaskGroup { requests in
            for await wake in wakes {
                if case .answered(let answer) = wake {
                    asking.remove(answer.key)
                    record(answer, in: &state, policy: policy)
                    // A fresh reading for the subject on the badge is as much
                    // news to a hiker out in the weather as a focus is.
                    await weatherManager.announceStandingAlerts(during: weatherAlertSession)
                    rearm(&dueTask, for: state, policy: policy, unlessAsking: asking, onDue: dueDatesContinuation)
                    continue
                }
                // A session starting or ending changes whose weather the
                // badge is, not whether it is current — nothing to fetch.
                guard let reason = wake.requestReason else {
                    await weatherManager.announceStandingAlerts(during: weatherAlertSession)
                    continue
                }

                // Applied before the subject is read, so a movement wake asks
                // about where the hiker is now rather than where they were.
                // Ignore movements that leave a searched place or distant
                // trail unchanged; those readings still wait for their
                // freshness deadline.
                if case .movement = wake, !subjectFollowedTheHiker() { continue }

                guard let subject = weatherFocus.subject else {
                    weatherManager.focus(on: nil, willRequest: false)
                    dueTask?.cancel()
                    continue
                }
                let key = subject.key
                let isAsking = asking.contains(key)
                let willRequest = state.shouldRequest(key: key, reason: reason, at: .now, policy: policy) && !isAsking
                // Every pass, not only the ones that fetch: this is what
                // carries a changed subject — a new city, or `me` with a new
                // coordinate — to the badge, and what decides between a
                // spinner and a plain "unavailable" when the backoff has ruled
                // a request out. One already out is a forecast on its way, as
                // much as one sent now.
                weatherManager.focus(on: subject, willRequest: willRequest || isAsking)

                if willRequest {
                    asking.insert(key)
                    requests.addTask(operation: request(for: subject, answeringTo: answersContinuation))
                }
                // Every pass too: a focus that lands on a cached reading is as
                // much news to a hiker who just started recording as a fresh
                // one.
                await weatherManager.announceStandingAlerts(during: weatherAlertSession)
                rearm(&dueTask, for: state, policy: policy, unlessAsking: asking, onDue: dueDatesContinuation)
            }
            // Ended rather than cancelled, the loop still has no use for an
            // answer, and the group would otherwise wait for every one.
            requests.cancelAll()
        }
    }

    /// Whether a movement moved the subject: the hiker went far enough, and
    /// the subject is one that follows them — see
    /// ``WeatherFocus/hikerMoved(to:)``.
    private func subjectFollowedTheHiker() -> Bool {
        guard let coordinate = significantLocations.coordinate else { return false }
        return weatherFocus.hikerMoved(to: coordinate)
    }

    /// A request about `subject`, for the loop to run beside it rather than
    /// in it, that hands its answer back to the loop — see this file's
    /// header.
    private func request(
        for subject: WeatherSubject,
        answeringTo answers: AsyncStream<WeatherAnswer>.Continuation
    ) -> @MainActor @Sendable () async -> Void {
        { [weatherManager, weatherFocus] in
            let succeeded = await weatherManager.update(for: subject, inFront: weatherFocus.subject)
            answers.yield(WeatherAnswer(key: subject.key, succeeded: succeeded, at: .now))
        }
    }

    /// Counts `answer` against its subject's freshness or backoff, keeping
    /// the subject in front the most recently used: the deadline
    /// ``rearm(_:for:policy:unlessAsking:onDue:)`` arms next is that one's.
    ///
    /// And settles the badge, when the hiker has come back to that subject
    /// since: a focus that landed while the request was still out drew a
    /// spinner for an answer that may already have been kept without
    /// showing. Asked with no request to come, the badge draws what is
    /// cached, or that there is none.
    private func record(
        _ answer: WeatherAnswer,
        in state: inout WeatherRequestState,
        policy: WeatherPollingPolicy
    ) {
        let inFront = weatherFocus.subject
        if answer.succeeded {
            state.recordSuccess(key: answer.key, at: answer.at, keeping: inFront?.key)
        } else {
            state.recordFailure(key: answer.key, at: answer.at, policy: policy, keeping: inFront?.key)
        }
        guard let subject = inFront, subject.key == answer.key else { return }
        weatherManager.focus(on: subject, willRequest: false)
    }

    /// Wakes the loop when the subject on the badge comes due, and not for
    /// any other.
    ///
    /// Re-armed against whatever the subject is *now*, which after an await
    /// may not be the one the pass started with. Cancelling first is what
    /// stops a subject the user has moved on from waking the loop on its own
    /// deadline. Not while that subject's request is out: its answer re-arms
    /// it, and a deadline already past would wake the loop for nothing until
    /// then.
    private func rearm(
        _ dueTask: inout Task<Void, Never>?,
        for state: WeatherRequestState,
        policy: WeatherPollingPolicy,
        unlessAsking asking: Set<String>,
        onDue continuation: AsyncStream<Void>.Continuation
    ) {
        dueTask?.cancel()
        guard let key = weatherFocus.subject?.key, !asking.contains(key),
              let due = state.nextEligibleDate(key: key, policy: policy) else { return }
        dueTask = Task {
            try? await Task.sleep(until: .now + .seconds(max(0, due.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            continuation.yield(())
        }
    }
}

private extension WeatherWake {
    /// `nil` for a wake that is not a reason to ask WeatherKit anything.
    var requestReason: WeatherRequestReason? {
        switch self {
        case .expiry: .expiry
        case .focus: .focus
        case .movement: .movement
        case .answered, .session: nil
        }
    }
}
