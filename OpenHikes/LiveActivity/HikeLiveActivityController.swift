//
//  HikeLiveActivityController.swift
//  OpenHikes
//
//  Decides when a Live Activity starts, when it is worth an update, and when
//  it ends — for both things a walker can have running.
//
//  Every one of those is a *policy* question rather than an ActivityKit one,
//  which is why they are here and not in `SystemHikeActivityPresenter`. The
//  framework half cannot be exercised by a hosted unit test — ActivityKit
//  refuses outright under `xcodebuild test` — so the seam is what makes the
//  interesting behaviour reachable at all.
//
//  Three rules, each of which has a counterpart elsewhere in this project:
//
//  - **A recording outranks a followed trail.** They can genuinely overlap —
//    a walker records their own track along an imported route — and the system
//    shows one activity. The recording wins because it is the thing that would
//    be *lost*: a follow can be re-derived from the trail and a fix, and a
//    recording cannot. This is the same precedence `TrailWidgetEntry` already
//    applies to the home screen widget, and it is applied here so the two
//    surfaces cannot disagree about which walk is happening.
//
//  - **Updates are throttled, and status changes bypass the throttle.** Same
//    shape as `BackgroundTrailTracker`'s foreground feed, and for the same
//    reason: a per-fix update would spend the system's budget on distance
//    changes too small to see, while pausing or losing the trail changes what
//    the activity *says* and has to arrive at once. The bypass has a floor of
//    its own, because a walker flapping on and off the route with ordinary GPS
//    noise would otherwise take it on every fix.
//
//  - **The elapsed clock is never a reason to update.** It ticks by itself —
//    see `HikeActivityAttributes.ContentState.timerStart`.
//

import Foundation
import Observation
import OpenHikesShared

/// One walk's activity, prepared by whichever subsystem owns it: the recorder
/// for a recording, the trail tracker for a follow.
///
/// A pair rather than two arguments so the controller cannot be handed a state
/// belonging to different attributes than the ones beside it.
struct HikeActivityRequest {
    let attributes: HikeActivityAttributes
    let state: HikeActivityAttributes.ContentState
}

@MainActor
@Observable
final class HikeLiveActivityController {
    /// The floor under an ordinary update.
    ///
    /// A walker at a normal pace covers the 25 m distance threshold in about
    /// twenty seconds, so in practice the two agree rather than one dominating
    /// — which is the point. Shorter and the app spends the system's budget on
    /// a Lock Screen nobody is looking at; longer and a walker who *does* look
    /// sees a figure from the last village.
    static let minimumUpdateInterval: TimeInterval = 20

    /// The floor under the status-change bypass. The first flip is immediate;
    /// a second one waits. Directly modelled on
    /// `BackgroundTrailTracker.statusFlipInterval`, which exists because GPS
    /// noise around the follow threshold otherwise flips on every fix.
    static let minimumFlipInterval: TimeInterval = 10

    /// When the system should start telling the walker this is old news.
    ///
    /// Shorter for a recording: it updates once a fix, so ten minutes of
    /// silence means the fixes have stopped. A follow is throttled to
    /// three-quarters of a minute in the foreground and to
    /// significant-location-change events in the background, so half an hour
    /// without one is an ordinary walk in a valley rather than a fault.
    static let recordingStaleAfter: TimeInterval = 10 * 60
    static let followingStaleAfter: TimeInterval = 30 * 60

    /// How long a finished walk's final figures stay on the Lock Screen.
    ///
    /// Long enough to be read once the phone comes out of a pocket, short
    /// enough not to become furniture. A *discarded* recording gets `nil`
    /// instead — there is no result to show, and leaving one up would claim a
    /// hike was saved.
    static let finishedDismissAfter: TimeInterval = 5 * 60

    @ObservationIgnored private let presenter: any HikeActivityPresenting
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: @Sendable () -> Date

    /// What this process believes is on screen. Not authoritative on its own —
    /// an activity outlives the process that started it — which is why
    /// ``SystemHikeActivityPresenter`` adopts a running activity rather than
    /// requesting a second one.
    @ObservationIgnored private var current: HikeActivityRequest?
    @ObservationIgnored private var lastUpdateAt: Date?
    @ObservationIgnored private var lastFlipAt: Date?

    /// Chains the framework calls so they land in the order they were asked
    /// for. ActivityKit's `update` and `end` are `async`, and two of them
    /// started independently would resume in either order — which is how an
    /// activity ends up showing the older of two states, or outliving the
    /// `end` that was supposed to remove it. The same reasoning, and the same
    /// shape, as `BackgroundTrailTracker`'s `fixPublishTask` chain.
    @ObservationIgnored private var pendingWork: Task<Void, Never>?
    @ObservationIgnored private var workSequence: UInt64 = 0

    init(
        presenter: any HikeActivityPresenting,
        defaults: UserDefaults = .standard,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.presenter = presenter
        self.defaults = defaults
        self.clock = clock
    }

    /// Whether the walker wants these at all. Two switches, and both have to
    /// say yes: the app's own, and the system's per-app one, which the walker
    /// owns and the app can only read.
    var isEnabled: Bool {
        preferenceEnabled && presenter.areActivitiesEnabled
    }

    /// The app's own switch, read on every call rather than captured, so
    /// turning it off in Settings takes effect on the next fix.
    var preferenceEnabled: Bool {
        defaults.object(forKey: SettingsKey.liveActivitiesEnabled) as? Bool
            ?? SettingsDefault.liveActivitiesEnabled
    }

    /// The walk this controller currently has on screen, if any. A test seam
    /// and the answer to "is a follow allowed to start", which is the same
    /// question.
    var activeSubject: HikeActivityAttributes.Subject? {
        current?.attributes.subject
    }

    // MARK: Updates

    /// Starts, updates, or ignores — whichever the request and the current
    /// state call for.
    ///
    /// Safe to call at fix rate: the throttle below is what makes it so, and
    /// callers are deliberately not expected to do that arithmetic themselves.
    func update(_ request: HikeActivityRequest) {
        guard isEnabled else {
            // The app switch can be turned off mid-walk, and an activity
            // already on screen has to come down with it rather than freeze.
            if current != nil { endAll() }
            return
        }
        guard accepts(request.attributes.subject) else { return }
        guard let current, current.attributes.describesSameWalk(as: request.attributes) else {
            start(request)
            return
        }
        let now = clock()
        guard let reason = updateReason(
            to: request.state,
            from: current.state,
            now: now
        ) else { return }
        RenderSignpost.mark("LiveActivityUpdate", reason.signpostDetail)
        if reason == .statusChanged { lastFlipAt = now }
        lastUpdateAt = now
        // The attributes are carried across too: a trail renamed mid-walk
        // keeps its running activity — ActivityKit cannot deliver new
        // attributes — but this process should stop believing the old name.
        self.current = request
        enqueue { [presenter] in
            await presenter.update(
                request.state,
                staleAfter: Self.staleAfter(for: request.attributes.subject)
            )
        }
    }

    /// Ends the activity for `subject`, if that is the one running.
    ///
    /// Guarded rather than unconditional because both callers can fire for a
    /// walk that already lost the screen to a higher-ranked one — a follow
    /// ending while a recording is up must not take the recording down with
    /// it.
    ///
    /// - Parameter finalState: what to leave on screen. `nil` means *nothing*
    ///   rather than "reuse the last one": a discarded recording has no result
    ///   to show, and a caller that wants the closing figures knows them
    ///   better than this does — its last update is up to a throttle interval
    ///   old.
    func end(
        subject: HikeActivityAttributes.Subject,
        finalState: HikeActivityAttributes.ContentState? = nil,
        dismissAfter: TimeInterval? = nil
    ) {
        guard let current, current.attributes.subject == subject else { return }
        finish(finalState: finalState, dismissAfter: dismissAfter)
    }

    /// Ends whatever is running, whatever it is. For leaving the feature
    /// entirely: the switch turned off, or a store that can no longer say what
    /// the walker is doing.
    func endAll(dismissAfter: TimeInterval? = nil) {
        guard current != nil else { return }
        finish(finalState: nil, dismissAfter: dismissAfter)
    }

    // MARK: Policy

    /// Whether `subject` may take the screen from whatever holds it.
    ///
    /// A recording always may. A follow may only if nothing else is running,
    /// or if the follow itself already is — see the precedence rule in the
    /// file header.
    private func accepts(_ subject: HikeActivityAttributes.Subject) -> Bool {
        guard let active = current?.attributes.subject else { return true }
        if subject.isRecording { return true }
        return !active.isRecording
    }

    /// Why this state is worth an update, or `nil` for "it isn't".
    ///
    /// An enum rather than a `Bool` because the two answers have different
    /// consequences: a status change resets the flip floor, an ordinary one
    /// does not.
    private enum UpdateReason: Equatable {
        case statusChanged
        case intervalElapsed

        /// What the Points of Interest track says about this update. The two
        /// cases arrive at very different rates, and a run where every mark
        /// reads `status` is a run where something is flapping.
        var signpostDetail: String {
            switch self {
            case .statusChanged: "status"
            case .intervalElapsed: "interval"
            }
        }
    }

    private func updateReason(
        to state: HikeActivityAttributes.ContentState,
        from previous: HikeActivityAttributes.ContentState,
        now: Date
    ) -> UpdateReason? {
        let statusChanged = state.runState != previous.runState
            || (state.offRouteMeters == nil) != (previous.offRouteMeters == nil)
        if statusChanged, elapsed(since: lastFlipAt, now: now, atLeast: Self.minimumFlipInterval) {
            return .statusChanged
        }
        guard elapsed(since: lastUpdateAt, now: now, atLeast: Self.minimumUpdateInterval),
              state.warrantsUpdate(comparedTo: previous)
        else { return nil }
        return .intervalElapsed
    }

    /// Whether `interval` has passed since `date`, treating "never" as "yes" —
    /// the first flip and the first update are both free.
    private func elapsed(
        since date: Date?,
        now: Date,
        atLeast interval: TimeInterval
    ) -> Bool {
        date.map { now.timeIntervalSince($0) >= interval } ?? true
    }

    private static func staleAfter(
        for subject: HikeActivityAttributes.Subject
    ) -> TimeInterval {
        subject.isRecording ? recordingStaleAfter : followingStaleAfter
    }

    // MARK: Transitions

    private func start(_ request: HikeActivityRequest) {
        RenderSignpost.mark(
            "LiveActivityStart",
            request.attributes.subject.isRecording ? "recording" : "following"
        )
        let replaced = current
        current = request
        let now = clock()
        lastUpdateAt = now
        lastFlipAt = nil
        enqueue { [presenter] in
            // Ended first and awaited, not fired alongside: two activities of
            // the same attributes type can be on screen at once, and a
            // recording that arrives while a follow is up must replace it
            // rather than join it.
            if replaced != nil {
                await presenter.end(finalState: nil, dismissAfter: nil)
            }
            await presenter.start(
                request.attributes,
                state: request.state,
                staleAfter: Self.staleAfter(for: request.attributes.subject)
            )
        }
    }

    private func finish(
        finalState: HikeActivityAttributes.ContentState?,
        dismissAfter: TimeInterval?
    ) {
        RenderSignpost.mark(
            "LiveActivityEnd",
            finalState == nil ? "immediate" : "lingering"
        )
        current = nil
        lastUpdateAt = nil
        lastFlipAt = nil
        enqueue { [presenter] in
            await presenter.end(
                finalState: finalState,
                dismissAfter: dismissAfter
            )
        }
    }

    // MARK: Ordering

    /// A bare `Task {}` on a `@MainActor` type, and deliberately: the work
    /// inside really is main-actor work — ``HikeActivityPresenting`` is
    /// main-actor isolated — so hopping off would only mean hopping straight
    /// back. See the concurrency notes in the repository instructions.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = pendingWork
        workSequence &+= 1
        let sequence = workSequence
        pendingWork = Task { [weak self] in
            await previous?.value
            await work()
            guard let self, workSequence == sequence else { return }
            pendingWork = nil
        }
    }

    /// Waits for everything queued so far. A test seam, and the reason the
    /// suites can assert on a stub without sleeping: ActivityKit's calls are
    /// `async`, so "the update landed" is only answerable by draining.
    func settle() async {
        await pendingWork?.value
    }
}
