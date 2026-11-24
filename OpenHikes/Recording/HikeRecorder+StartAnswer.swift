//
//  HikeRecorder+StartAnswer.swift
//  OpenHikes
//
//  A Start that is still a question. On an install that has never asked for
//  location, ``HikeRecorder/start()`` puts up the system's prompt and returns
//  in `.waitingForFix`, with no session behind it: the recording begins when
//  the hiker allows it, from the authorization callback, or never. A caller
//  that reports what happened — Siri, Control Center — has to wait for that
//  answer rather than read the phase it left, which already says the walk is
//  under way.
//

import Foundation

extension HikeRecorder {
    /// Whether a Start is waiting on the hiker's answer to a location prompt:
    /// asked for, with no session made yet. The precision sheet's wait is
    /// inside `start()` itself and is over by the time it returns.
    var isAwaitingStartAnswer: Bool {
        startRequested && sessionID == nil
    }

    /// Returns once a Start waiting on the hiker's answer has one: a session
    /// was made, the start failed, or it was let go of. At once when none is
    /// waiting, and when the caller's task is cancelled.
    func settleStart() async {
        while isAwaitingStartAnswer, !Task.isCancelled {
            await withTaskCancellationHandler {
                await withCheckedContinuation { startWaiters.append($0) }
            } onCancel: {
                Task { @MainActor [weak self] in self?.releaseStartWaiters() }
            }
        }
    }

    /// Wakes every ``settleStart()`` to look again. Called whenever the Start
    /// or the session changes, which is every way its answer can arrive.
    func releaseStartWaiters() {
        guard !startWaiters.isEmpty else { return }
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
