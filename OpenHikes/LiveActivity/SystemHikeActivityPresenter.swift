//
//  SystemHikeActivityPresenter.swift
//  OpenHikes
//
//  The real ActivityKit implementation of ``HikeActivityPresenting``.
//
//  Everything here is a call into the framework and a handle to hold onto;
//  every decision about *whether* to make one of these calls is in
//  `HikeLiveActivityController`. That split is what makes the policy testable,
//  because this half cannot be exercised by a hosted unit test at all — see
//  the header on the protocol.
//

import ActivityKit
import Foundation
import OpenHikesShared
import os

@MainActor
final class SystemHikeActivityPresenter: HikeActivityPresenting {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "LiveActivity"
    )

    private var activity: Activity<HikeActivityAttributes>?

    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var activeSubject: HikeActivityAttributes.Subject? {
        if let activity, Self.isLive(activity) { return activity.attributes.subject }
        // Nothing held, which is not the same as nothing on screen: a Live
        // Activity outlives its process, and after a relaunch the system's own
        // list is the only place the truth is. Recordings first, so a process
        // that somehow finds both is answered with the higher-ranked one and
        // this property cannot disagree with the precedence rule.
        let running = Activity<HikeActivityAttributes>.activities.filter { candidate in
            Self.isLive(candidate)
        }
        let preferred = running.first(where: \.attributes.subject.isRecording)
        return (preferred ?? running.first)?.attributes.subject
    }

    func start(
        _ attributes: HikeActivityAttributes,
        state: HikeActivityAttributes.ContentState,
        staleAfter: TimeInterval
    ) async {
        // Adopting rather than requesting a second one. A Live Activity
        // outlives the process that started it, so a relaunch — including the
        // background significant-location-change relaunch this app already
        // depends on — finds its own activity still running. Requesting again
        // would leave two on the Lock Screen, one of them frozen and unowned.
        if let existing = Activity<HikeActivityAttributes>.activities.first(
            where: { candidate in
                candidate.attributes.describesSameWalk(as: attributes)
                    && Self.isLive(candidate)
            }
        ) {
            activity = existing
            await update(state, staleAfter: staleAfter)
            return
        }
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: Self.content(state, staleAfter: staleAfter),
                pushType: nil
            )
        } catch {
            // Refused for a reason the walker owns — the Settings switch, or
            // the system's per-app limit. Logged, not surfaced: there is
            // nothing to do about it mid-hike, and the recording itself is
            // entirely unaffected.
            Self.logger.notice(
                "Live Activity refused: \(error.localizedDescription, privacy: .public)"
            )
            activity = nil
        }
    }

    func update(
        _ state: HikeActivityAttributes.ContentState,
        staleAfter: TimeInterval
    ) async {
        guard let activity, Self.isLive(activity) else { return }
        await Self.apply(
            Self.content(state, staleAfter: staleAfter),
            to: Handle(activity)
        )
    }

    func end(
        finalState: HikeActivityAttributes.ContentState?,
        dismissAfter: TimeInterval?
    ) async {
        guard let activity else { return }
        self.activity = nil
        let content = finalState.map { state in
            Self.content(state, staleAfter: nil)
        }
        let policy: ActivityUIDismissalPolicy = dismissAfter.map { delay in
            .after(.now.addingTimeInterval(delay))
        } ?? .immediate
        await Self.finish(Handle(activity), content: content, policy: policy)
    }

    /// Ends every live activity of `kind`, held or not.
    ///
    /// Plural because the system's list is what is being read, not a handle:
    /// two panels for one app is a state ActivityKit permits and this app has
    /// one way to reach — a relaunch that requests a follow while an
    /// unadopted recording is still up, since ``start`` adopts only a walk
    /// that matches. Ending one of two and leaving the other would be the
    /// worse half of the bug this method exists for.
    ///
    /// The held handle is dropped when it is one of them, so a later `update`
    /// does not address an activity that has just been ended — which the
    /// framework accepts silently and which looks exactly like a dead feed.
    func endUnowned(_ kind: HikeActivityKind) async {
        let doomed = Activity<HikeActivityAttributes>.activities.filter { candidate in
            Self.isLive(candidate) && kind.matches(candidate.attributes.subject)
        }
        guard !doomed.isEmpty else { return }
        if let activity, doomed.contains(where: { candidate in candidate.id == activity.id }) {
            self.activity = nil
        }
        for candidate in doomed {
            await Self.finish(Handle(candidate), content: nil, policy: .immediate)
        }
    }

    /// Carries an `Activity` across an isolation boundary.
    ///
    /// `Activity` is a handle to a system service — every call that changes
    /// anything is `async` and goes out to `liveactivitiesd` — but ActivityKit
    /// does not declare it `Sendable`. Under Swift 6's region isolation that
    /// makes `await activity.update(...)` from a `@MainActor` type a sending
    /// violation, because the handle belongs to the main actor's region and
    /// `update` is `nonisolated`.
    ///
    /// The unchecked conformance is the narrow claim that Apple's own handle
    /// is safe to call from more than one place, which is the only way its
    /// `async` surface can be used at all. It is confined to the two functions
    /// below so nothing else can quietly rely on it.
    nonisolated private struct Handle: @unchecked Sendable {
        let activity: Activity<HikeActivityAttributes>

        init(_ activity: Activity<HikeActivityAttributes>) {
            self.activity = activity
        }
    }

    nonisolated private static func apply(
        _ content: ActivityContent<HikeActivityAttributes.ContentState>,
        to handle: Handle
    ) async {
        await handle.activity.update(content)
    }

    nonisolated private static func finish(
        _ handle: Handle,
        content: ActivityContent<HikeActivityAttributes.ContentState>?,
        policy: ActivityUIDismissalPolicy
    ) async {
        await handle.activity.end(content, dismissalPolicy: policy)
    }

    /// Wraps a state with the moment it stops being trustworthy.
    ///
    /// The stale date is not cosmetic. A walk goes through tunnels, valleys
    /// and Low Power Mode, and a phone that has heard nothing for half an hour
    /// is showing a distance that is simply wrong. Handing the system a stale
    /// date lets it dim the activity and say so, which is the honest outcome —
    /// the alternative is a Lock Screen confidently reporting a figure from
    /// before the walker went into the woods.
    private static func content(
        _ state: HikeActivityAttributes.ContentState,
        staleAfter: TimeInterval?
    ) -> ActivityContent<HikeActivityAttributes.ContentState> {
        ActivityContent(
            state: state,
            staleDate: staleAfter.map { interval in
                state.updatedAt.addingTimeInterval(interval)
            }
        )
    }

    /// Whether an activity is still something the system will accept updates
    /// for. `.dismissed` and `.ended` handles linger, and updating one is a
    /// silent no-op that looks exactly like a broken feed.
    private static func isLive(_ activity: Activity<HikeActivityAttributes>) -> Bool {
        switch activity.activityState {
        // `.pending` counts as live: the system has accepted the activity and
        // is waiting to show it, so an update aimed at it is not lost — and
        // treating it as dead would have the app request a second one.
        case .pending, .active, .stale: true
        case .ended, .dismissed: false
        @unknown default: false
        }
    }
}
