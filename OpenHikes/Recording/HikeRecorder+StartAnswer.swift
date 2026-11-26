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
//  The phase is left saying so on purpose. The recording screen and the
//  watch show the Start as the recording it is about to be, which is what
//  keeps the watch from starting a second one beside it, and a Stop from
//  any surface ends it. Only a caller that confirms a start asks the
//  difference, and a Pause, which has nothing to pause until the session
//  exists: the session the Allow makes would run under it.
//

import Foundation

extension HikeRecorder {
    /// Whether a Start has yet to become a session: asked for, with none
    /// made. On an install that never asked, that is the location prompt and
    /// then the activation its Allow begins from the authorization callback:
    /// the precision sheet, when the answer was approximate, and the journal.
    /// A Start already allowed makes its session, or fails, inside `start()`.
    var isAwaitingStartAnswer: Bool {
        startRequested && sessionID == nil
    }

    /// Returns once a Start waiting on the hiker's answer has one: a session
    /// was made, the start failed, or it was let go of. At once when none is
    /// waiting, and when the caller's task is cancelled, with the Start still
    /// waiting: what to do with it is the caller's to decide.
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
