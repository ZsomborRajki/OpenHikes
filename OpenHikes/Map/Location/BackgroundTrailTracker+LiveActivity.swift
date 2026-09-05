//
//  BackgroundTrailTracker+LiveActivity.swift
//  OpenHikes
//
//  The Lock Screen half of following a trail.
//
//  Split out of `BackgroundTrailTracker.swift` because that file is already at
//  its length limit, and because these two methods answer a different question
//  from the rest of it: the tracker decides *where the walker is*, and this
//  decides *whether that is worth putting in front of them*. The policy behind
//  both — precedence against a recording, the update throttle, the stale date —
//  lives in `HikeLiveActivityController`; nothing here talks to ActivityKit.
//

import Foundation
import OpenHikesShared

extension BackgroundTrailTracker {
    // MARK: Live Activity

    /// Puts the same payload the widget just received on the Lock Screen.
    ///
    /// Hooked here rather than in ``publishLiveFix(hike:profile:match:)``
    /// deliberately: this is the one funnel both feeds pass through, so a
    /// walker who locks the phone and keeps walking on significant-change
    /// updates alone keeps an activity that is still telling the truth.
    ///
    /// It also inherits the widget's 45-second throttle by construction, which
    /// is the right rate for a follow — a matched position moves about fifty
    /// metres in that time, and re-deriving one costs a whole route profile.
    ///
    /// A snapshot with no live fix updates a running activity but never starts
    /// one. The difference matters: "off the trail" is worth saying to a
    /// walker who is following it, and is not a reason to put an activity in
    /// front of someone who merely opened a trail to look at it.
    ///
    /// Neither does a fix along a trail whose walk has just been ended. That
    /// end left its closing figures on the Lock Screen for
    /// ``HikeLiveActivityController/finishedDismissAfter``, and every fix
    /// after it — the walker still standing on the route, or a background
    /// match that was already in flight when End landed — carries no walk and
    /// so reads as an ordinary follow. Starting one would put a second panel
    /// beside a result that was deliberately left up, or replace it outright.
    /// Only the *start* is refused: the widget going back to plain following
    /// is the right thing for it to do, and a running activity keeps taking
    /// its updates, which is what lets an already-published fix land in front
    /// of the end that is queued behind it.
    func publishFollowActivity(_ snapshot: SharedTrailSnapshot) {
        guard let liveActivityController else { return }
        let subject = HikeActivityAttributes.Subject.following(hikeID: snapshot.hikeID)
        let isRunning = liveActivityController.activeSubject == subject
        guard isRunning || snapshot.liveFix != nil else { return }
        guard isRunning || walkSession?.hasEndedWalk(hikeID: snapshot.hikeID) != true else { return }
        liveActivityController.update(
            HikeActivityRequest(
                attributes: .following(from: snapshot, startedAt: clock()),
                state: .init(following: snapshot)
            )
        )
    }

    /// Takes a followed trail off the Lock Screen.
    ///
    /// No final panel and no lingering by default: a follow that merely
    /// stopped has no result to leave behind, and a walker who has switched
    /// trails or turned following off has already said what they want to
    /// see. A walk that *ended* is the exception, and passes its closing
    /// figures with a dismiss delay, the way a finished recording does; an
    /// abandoned one still passes `nil`.
    func endFollowActivity(
        hikeID: UUID?,
        finalState: HikeActivityAttributes.ContentState? = nil,
        dismissAfter: TimeInterval? = nil
    ) {
        guard let liveActivityController,
              let active = liveActivityController.activeSubject,
              !active.isRecording,
              hikeID == nil || active.hikeID == hikeID
        else { return }
        liveActivityController.end(
            subject: active,
            finalState: finalState,
            dismissAfter: dismissAfter
        )
    }
}
