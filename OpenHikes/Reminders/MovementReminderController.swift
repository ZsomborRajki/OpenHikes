//
//  MovementReminderController.swift
//  OpenHikes
//
//  The one place that decides a reminder is owed, for both things a walker
//  can have running.
//
//  One instance handed to the recorder and to the walk session rather than one
//  each, for the reason ``HikeLiveActivityController`` is one instance: the
//  precedence between them is only expressible by something that can see both.
//  **A recording outranks a followed trail** here exactly as it does on the
//  widget and the Lock Screen — a walker recording their own track along an
//  imported route is one walk to them, and two banners about it, one asking
//  them to resume the recording and one asking them to resume the walk, would
//  be the app arguing with itself in a pocket.
//
//  What it owns is the state a pause needs and nothing else:
//
//  * **Where the pause began**, per subject. The recording's anchor is a
//    coordinate and the walk's is a distance along the route, which is what
//    lets the walk be watched with no sensor of its own — a paused walk still
//    receives matched fixes from the feeds that were already running, and the
//    distance those carry *is* the measurement.
//  * **The watches**, which hold the thresholds, the repeat allowance and the
//    quiet period. See ``MovementReminderPolicy``.
//  * **The walker's switch**, read on every decision rather than captured, so
//    turning reminders off mid-hike stops the next one instead of the one
//    after the next launch.
//
//  It owns no opinion about *whether the app can watch at all*. A paused
//  recording is watched only if the recorder keeps a feed alive for it, which
//  is what ``recordingDidPause(at:on:)`` answers, and a paused walk is watched
//  only for as long as fixes keep arriving from somewhere else. Both are
//  best-effort by construction: a reminder that never arrives is a walker who
//  is no worse off than before this existed, which is the only failure mode
//  this feature is allowed to have.
//

import CoreLocation
import Foundation

@MainActor
final class MovementReminderController {
    /// A paused recording, and how far it has moved since.
    private struct PausedRecording {
        let anchor: CLLocationCoordinate2D
        let pausedAt: Date
        var watch = MovementWatch()
    }

    /// A paused walk. The anchor is a distance along the trail rather than a
    /// coordinate: the walk's own feeds speak in those, and a walker who
    /// covers half a kilometre of the route with the walk paused is the case
    /// this exists for whether they went up it or back down it — which is why
    /// the displacement below is taken as an absolute value.
    private struct PausedWalk {
        let trailTitle: String
        let anchorDistance: Double
        var watch = MovementWatch()
    }

    private let notifier: any MovementReminderNotifying
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    /// Whether a recording exists at all, asked rather than remembered. A
    /// closure for the reason ``TrailWalkSession`` takes one for the same
    /// question: the recorder is the single authority on it, and a second copy
    /// kept here could only ever disagree.
    ///
    /// Assigned rather than injected, because the recorder is handed *this*
    /// object and the two cannot each be built first. The composition root
    /// sets it as soon as the recorder exists; until it does the answer is
    /// "no recording", which is the safe direction — a walk reminder is
    /// suppressed by a recording, never caused by one.
    var hasActiveRecording: @MainActor () -> Bool = { false }

    private var pausedRecording: PausedRecording?
    private var pausedWalk: PausedWalk?
    private var stillness = StillnessWatch()

    /// Chains the notification-centre calls so a post and the withdrawal that
    /// follows it cannot land in the other order — the same reasoning, and the
    /// same shape, as `HikeLiveActivityController.pendingWork`.
    private var pendingWork: Task<Void, Never>?

    init(
        notifier: any MovementReminderNotifying,
        defaults: UserDefaults = .standard,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.notifier = notifier
        self.defaults = defaults
        self.clock = clock
    }

    /// The walker's own switch, read fresh every time.
    var isEnabled: Bool {
        defaults.object(forKey: SettingsKey.movementRemindersEnabled) as? Bool
            ?? SettingsDefault.movementRemindersEnabled
    }
}

// MARK: - A paused recording

extension MovementReminderController {
    /// Arms the resume reminder for a recording that has just been paused.
    ///
    /// - Parameter coordinate: where the walker was when they paused, which is
    ///   the recorder's last accepted point. `nil` when the recording had not
    ///   accepted one yet — a pause taken while still waiting for a first fix
    ///   — and there is nothing to measure a departure from.
    /// - Returns: whether the recorder should keep watching for movement.
    ///   `false` is the answer that leaves a pause exactly as expensive as it
    ///   was before this feature existed: no anchor or no switch means no
    ///   reminder can ever be sent, and a watch nobody will read is battery
    ///   spent for nothing.
    @discardableResult func recordingDidPause(
        at coordinate: CLLocationCoordinate2D?,
        on date: Date
    ) -> Bool {
        stillness = StillnessWatch()
        withdraw(.pauseRecording)
        guard isEnabled, let coordinate, CLLocationCoordinate2DIsValid(coordinate) else {
            pausedRecording = nil
            return false
        }
        pausedRecording = PausedRecording(anchor: coordinate, pausedAt: date)
        // Asked here rather than at launch: the walker is holding the phone,
        // they have just tapped Pause, and the prompt is about that.
        requestAuthorization()
        return true
    }

    /// A fix that arrived while the recording was paused.
    func recordingObserved(_ location: CLLocation, at date: Date) {
        guard isEnabled, var paused = pausedRecording else { return }
        guard Self.isMeasurable(location) else { return }
        let moved = RouteGeometry.distanceMeters(
            from: paused.anchor,
            to: location.coordinate
        )
        let shouldRemind = paused.watch.observe(awayMeters: moved, at: date)
        pausedRecording = paused
        guard shouldRemind else { return }
        post(
            MovementReminderWording.resumeRecording(
                movedMeters: moved,
                pausedFor: date.timeIntervalSince(paused.pausedAt)
            )
        )
    }

    /// The running recording's own answer to whether the walker is moving.
    func recordingObserved(isStationary: Bool, at date: Date) {
        guard isEnabled else { return }
        guard stillness.observe(isStationary: isStationary, at: date) else {
            // Moving again takes the suggestion back down: it asked a question
            // the walker has now answered with their feet.
            if !isStationary { withdraw(.pauseRecording) }
            return
        }
        post(MovementReminderWording.pauseRecording(stillFor: MovementReminderPolicy.stillFor))
    }

    /// The recording is running again — by the walker's hand, by the button on
    /// the reminder, or by an intent. Either way the question is answered.
    func recordingDidResume() {
        pausedRecording = nil
        withdraw(.resumeRecording)
    }

    /// The recording is over, has failed, or was discarded.
    func recordingDidEnd() {
        pausedRecording = nil
        stillness = StillnessWatch()
        withdraw(.resumeRecording)
        withdraw(.pauseRecording)
    }

    /// Whether a fix can be measured against an anchor at all.
    ///
    /// A significant-location-change delivery can be hundreds of metres wide,
    /// and a displacement computed between two of those says nothing about
    /// whether the walker moved. Dropped rather than softened: the next fix
    /// costs nothing to wait for, and the walk is not harmed by a reminder
    /// arriving one delivery later.
    private static func isMeasurable(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy > 0
            && location.horizontalAccuracy <= MovementReminderPolicy.maximumFixAccuracy
            && CLLocationCoordinate2DIsValid(location.coordinate)
    }
}

// MARK: - A paused walk

extension MovementReminderController {
    /// Arms the resume reminder for a walk along a followed trail.
    ///
    /// No return value, unlike the recording's: there is nothing for the
    /// caller to turn on. A paused walk is watched by the feeds that were
    /// already running — the detail screen's follow loop in the foreground and
    /// ``BackgroundTrailTracker``'s significant-change deliveries behind it —
    /// so this costs no sensor and no battery, and it is silent for a walker
    /// whose phone is in a pocket with background tracking off. That is the
    /// honest trade: the alternative is a second location feed for a walk that
    /// is deliberately the cheap half of this app.
    func walkDidPause(trailTitle: String, atDistance distance: Double) {
        guard isEnabled, distance.isFinite else {
            pausedWalk = nil
            return
        }
        pausedWalk = PausedWalk(trailTitle: trailTitle, anchorDistance: distance)
        requestAuthorization()
    }

    /// A fix that matched the trail while the walk was paused.
    func walkObserved(distanceAlongRoute distance: Double, at date: Date) {
        guard isEnabled, distance.isFinite, var paused = pausedWalk else { return }
        // The recording wins outright. It is the walk that would be *lost* —
        // a follow is re-derived from the trail and the next fix — and it is
        // the one whose reminder the walker can act on.
        guard !hasActiveRecording() else { return }
        let moved = abs(distance - paused.anchorDistance)
        let shouldRemind = paused.watch.observe(awayMeters: moved, at: date)
        pausedWalk = paused
        guard shouldRemind else { return }
        post(
            MovementReminderWording.resumeWalk(
                trailTitle: paused.trailTitle,
                movedMeters: moved
            )
        )
    }

    /// The walk is following again, or is over.
    func walkDidResumeOrEnd() {
        pausedWalk = nil
        withdraw(.resumeWalk)
    }
}

// MARK: - Talking to the notification centre

extension MovementReminderController {
    private func post(_ reminder: MovementReminder) {
        RenderSignpost.mark("MovementReminder", reminder.kind.rawValue)
        enqueue { [weak self] in
            guard let self, await notifier.authorize() else { return }
            await notifier.post(reminder)
        }
    }

    private func withdraw(_ kind: MovementReminderKind) {
        enqueue { [weak self] in self?.notifier.withdraw(kind) }
    }

    /// Puts the permission prompt up if it has not been answered yet.
    ///
    /// Enqueued rather than awaited: a pause has a journal write and a Live
    /// Activity update to get on with, and the answer is only needed by the
    /// post that may follow minutes later — which asks again anyway.
    private func requestAuthorization() {
        enqueue { [weak self] in
            guard let self else { return }
            _ = await notifier.authorize()
        }
    }

    /// Runs `work` after whatever was asked for before it.
    ///
    /// A `Task {}` on a `@MainActor` type is main-actor work, which is what
    /// this is: the notifier is main-actor isolated and every call it makes
    /// either suspends or is a cheap cross-process message. See the
    /// repository instructions on why that is not the bare-`Task` hazard.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = pendingWork
        pendingWork = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Waits for everything asked for so far, for a suite that has to read
    /// what the notifier was told.
    func settle() async {
        await pendingWork?.value
    }
}
