//
//  MovementReminderController.swift
//  OpenHikes
//
//  The one place that decides a reminder is owed, for both things a hiker
//  can have running.
//
//  One instance handed to the recorder and to the walk session rather than one
//  each, for the reason ``HikeLiveActivityController`` is one instance: the
//  precedence between them is only expressible by something that can see both.
//  **A recording outranks a followed trail** here exactly as it does on the
//  widget and the Lock Screen — a hiker recording their own track along an
//  imported route is one walk to them, and two banners about it, one asking
//  them to resume the recording and one asking them to resume the walk, would
//  be the app arguing with itself in a pocket.
//
//  What it owns is the state a pause needs and nothing else:
//
//  * **Where and when the pause began**, per subject. The recording's anchor
//    is a coordinate and the walk's is a distance along the route, which is
//    what lets the walk be watched with no sensor of its own — a paused walk
//    still receives matched fixes from the feeds that were already running,
//    and the distance those carry *is* the measurement. The moment is kept
//    beside it for both, because a fix taken before the pause is evidence
//    about the walk that led to it and not about the pause.
//  * **The watches**, which hold the thresholds, the repeat allowance and the
//    quiet period. See ``MovementReminderPolicy``.
//  * **The hiker's switch**, read on every decision rather than captured, so
//    turning reminders off mid-hike stops the next one instead of the one
//    after the next launch.
//
//  It owns no opinion about *whether the app can watch at all*. A paused
//  recording is watched only if the recorder keeps a feed alive for it, which
//  is what ``recordingDidPause(at:on:)`` answers, and a paused walk is watched
//  only for as long as fixes keep arriving from somewhere else. Both are
//  best-effort by construction: a reminder that never arrives is a hiker who
//  is no worse off than before this existed, which is the only failure mode
//  this feature is allowed to have.
//
//  The one thing it does own in that direction is giving a watch *back*. A
//  hiker who has refused notification permission cannot be sent anything, so
//  a recording paused under that refusal is spending a location feed on a
//  question with no audience — see
//  ``reconcileWithAuthorization(prompting:)``.
//

import CoreLocation
import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class MovementReminderController {
    /// A paused recording, and how far it has moved since.
    private struct PausedRecording {
        /// Tells this pause apart from any later one. The answer to a
        /// permission prompt arrives whenever the hiker gets round to
        /// reading it, and by then this may not be the pause that asked —
        /// see ``reconcileWithAuthorization(prompting:)``.
        let id = UUID()
        let anchor: CLLocationCoordinate2D
        let pausedAt: Date
        var watch = MovementWatch()
    }

    /// A paused walk. The anchor is a distance along the trail rather than a
    /// coordinate: the walk's own feeds speak in those, and a hiker who
    /// covers half a kilometre of the route with the walk paused is the case
    /// this exists for whether they went up it or back down it — which is why
    /// the displacement below is taken as an absolute value.
    private struct PausedWalk {
        let trailTitle: String
        let anchorDistance: Double
        /// When the walk was paused, which is the far side of the boundary a
        /// fix has to fall on to say anything about it — the walk's half of
        /// ``isMeasurable(_:since:)``.
        let pausedAt: Date
        var watch = MovementWatch()
    }

    private let notifier: any MovementReminderNotifying
    private let defaults: UserDefaults

    /// Where `UIApplication.DidBecomeActiveMessage` is observed. A seam and
    /// nothing more: the app never passes anything but `.default`, and it
    /// covers only the *lifecycle* observation, because
    /// `UserDefaults.didChangeNotification` is posted by the system on
    /// `NotificationCenter.default` and a controller listening for it anywhere
    /// else would simply never hear it. A private centre is what lets a suite
    /// drive the registration itself rather than the reconciliation behind it,
    /// without posting a process-wide notification into a running test host.
    private let lifecycleCenter: NotificationCenter

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

    /// What to do when a pause stops being watched for a reason the recorder
    /// has not heard about — today, the hiker turning the switch off with a
    /// pause already under way.
    ///
    /// Assigned by the recorder that holds this controller, for the reason
    /// ``hasActiveRecording`` is assigned rather than injected: the recorder
    /// is handed this object, so the two cannot each be built first. Until it
    /// is set the answer is "nothing to tear down", which is right for a
    /// controller no recorder is using.
    var watchingDidEnd: @MainActor () -> Void = { /* no recorder to tell */ }

    /// Chains the notification-centre calls so a post and the withdrawal that
    /// follows it cannot land in the other order — the same reasoning, and the
    /// same shape, as `HikeLiveActivityController.pendingWork`.
    private var pendingWork: Task<Void, Never>?

    /// The typed lifecycle observation, held for exactly as long as the
    /// controller is — which is the whole of its deregistration. An
    /// `ObservationToken` ends its observation when it goes out of scope, so
    /// releasing this array is what takes the observer off the centre, and
    /// dropping the token at the end of `observePreferences` would take the
    /// registration down before the hiker ever left the app.
    /// `LifecycleObservationTokenTests` pins both halves.
    private var lifecycleObservers: [NotificationCenter.ObservationToken] = []

    /// The untyped one, which has no such lifetime: a block-based observer is
    /// retained by the notification centre until it is removed by token. That
    /// is the entire job of the `isolated deinit` below — SE-0371 hops it back
    /// to the main actor before it runs, which is what lets it read main-actor
    /// storage and what removed the `nonisolated` box this used to need, the
    /// same choice `HikeLiveActivityController` and ``PowerStateMonitor``
    /// make.
    private var defaultsObservers: [any NSObjectProtocol] = []

    isolated deinit {
        for token in defaultsObservers { NotificationCenter.default.removeObserver(token) }
    }

    init(
        notifier: any MovementReminderNotifying,
        defaults: UserDefaults = .standard,
        lifecycleCenter: NotificationCenter = .default
    ) {
        self.notifier = notifier
        self.defaults = defaults
        self.lifecycleCenter = lifecycleCenter
        observePreferences()
    }

    /// The hiker's own switch, read fresh every time.
    var isEnabled: Bool {
        defaults.object(forKey: SettingsKey.movementRemindersEnabled) as? Bool
            ?? SettingsDefault.movementRemindersEnabled
    }

    /// Whether a paused recording is still worth a location feed, read at the
    /// moment the recorder actually parks its sensors.
    ///
    /// ``recordingDidPause(at:on:)`` answers the same question earlier, and
    /// the recorder cannot act on that answer until the pause is durably
    /// written on its journal queue. Everything that can overtake it happens
    /// in those milliseconds — a hiker refusing the permission prompt, most
    /// of all — so the answer that decides the sensors is taken here instead
    /// of carried across the wait.
    var isWatchingPausedRecording: Bool { pausedRecording != nil }
}

// MARK: - A paused recording

extension MovementReminderController {
    /// Arms the resume reminder for a recording that has just been paused.
    ///
    /// - Parameter coordinate: where the hiker was when they paused, which is
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
        // Asked here rather than at launch: the hiker is holding the phone,
        // they have just tapped Pause, and the prompt is about that. `true`
        // is the answer for a pause nobody has refused *yet* — a refusal
        // arrives after this returns, and takes the watch back down itself.
        reconcileWithAuthorization(prompting: true)
        return true
    }

    /// A fix that arrived while the recording was paused.
    ///
    /// - Parameter date: now, which is what the banner's "paused for" is
    ///   measured against. The *watch* is fed `location.timestamp` instead —
    ///   see ``isMeasurable(_:since:)`` for why the two cannot be the same
    ///   value here.
    func recordingObserved(_ location: CLLocation, at date: Date) {
        guard isEnabled, var paused = pausedRecording else { return }
        guard Self.isMeasurable(location, since: paused.pausedAt) else { return }
        let moved = RouteGeometry.distanceMeters(
            from: paused.anchor,
            to: location.coordinate
        )
        let shouldRemind = paused.watch.observe(
            awayMeters: moved,
            at: location.timestamp
        )
        pausedRecording = paused
        guard shouldRemind else { return }
        post(
            MovementReminderWording.resumeRecording(
                movedMeters: moved,
                pausedFor: date.timeIntervalSince(paused.pausedAt)
            )
        )
    }

    /// The running recording's own answer to whether the hiker is moving.
    func recordingObserved(isStationary: Bool, at date: Date) {
        guard isEnabled else { return }
        guard stillness.observe(isStationary: isStationary, at: date) else {
            // Moving again takes the suggestion back down: it asked a question
            // the hiker has now answered with their feet.
            if !isStationary { withdraw(.pauseRecording) }
            return
        }
        post(MovementReminderWording.pauseRecording(stillFor: MovementReminderPolicy.stillFor))
    }

    /// The recording is running again — by the hiker's hand, by the button on
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

    /// Whether a fix is evidence about *this* pause at all.
    ///
    /// Two rules, and the second is the one a pause makes necessary.
    ///
    /// A significant-location-change delivery can be hundreds of metres wide,
    /// and a displacement computed between two of those says nothing about
    /// whether the hiker moved. Dropped rather than softened: the next fix
    /// costs nothing to wait for, and the walk is not harmed by a reminder
    /// arriving one delivery later.
    ///
    /// And a fix taken *before* the pause began is not evidence of anything
    /// the hiker did since. Core Location says as much about
    /// `startMonitoringSignificantLocationChanges()`: the first event is
    /// commonly a cached one, and its timestamp is the only thing that says
    /// so. Without this a hiker who paused at a hut they had walked to
    /// half an hour earlier was told, one second later, that they had moved
    /// eight hundred metres — the cached fix from where they set off.
    private static func isMeasurable(_ location: CLLocation, since pausedAt: Date) -> Bool {
        location.horizontalAccuracy > 0
            && location.horizontalAccuracy <= MovementReminderPolicy.maximumFixAccuracy
            && CLLocationCoordinate2DIsValid(location.coordinate)
            && location.timestamp >= pausedAt
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
    /// so this costs no sensor and no battery, and it is silent for a hiker
    /// whose phone is in a pocket with background tracking off. That is the
    /// honest trade: the alternative is a second location feed for a walk that
    /// is deliberately the cheap half of this app.
    ///
    /// - Parameter date: when the walk was paused, taken from the record
    ///   rather than from the clock so a pause restored at launch is measured
    ///   from the moment the hiker tapped it.
    func walkDidPause(trailTitle: String, atDistance distance: Double, on date: Date) {
        guard isEnabled, distance.isFinite else {
            pausedWalk = nil
            return
        }
        pausedWalk = PausedWalk(
            trailTitle: trailTitle,
            anchorDistance: distance,
            pausedAt: date
        )
        reconcileWithAuthorization(prompting: true)
    }

    /// A fix that matched the trail while the walk was paused.
    ///
    /// - Parameter date: when the fix was *taken*. The feeds hand their own
    ///   timestamps through ``TrailWalkSession``, and both the boundary below
    ///   and ``MovementWatch``'s window need them to: a fix delivered after
    ///   the pause it was taken before is what the walk's whole first sample
    ///   used to be, and there is no earlier reading for the watch to reject
    ///   it against.
    func walkObserved(distanceAlongRoute distance: Double, at date: Date) {
        guard isEnabled, distance.isFinite, var paused = pausedWalk else { return }
        // The recording's rule, in the units a walk is watched in. Ground
        // covered before the hiker stopped is the walk that ended at the
        // pause, and offering it back to them as a reason to resume is the
        // app telling them they are moving while they stand at the hut.
        guard date >= paused.pausedAt else { return }
        // The recording wins outright. It is the walk that would be *lost* —
        // a follow is re-derived from the trail and the next fix — and it is
        // the one whose reminder the hiker can act on.
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
    /// Turning the switch off stops the reminders *and* whatever is being
    /// spent to produce them.
    ///
    /// Reading the switch at each decision is not enough on its own, and this
    /// is the half that was missing: a pause has already told the recorder to
    /// keep a feed alive, and with When In Use authorization that feed is a
    /// continuous one holding a background activity session and the location
    /// indicator. Left running it would spend the rest of the pause producing
    /// fixes that no longer decide anything — the worst version of this
    /// feature, since the hiker has just said they do not want it.
    ///
    /// Idempotent and cheap on purpose, exactly as
    /// `HikeLiveActivityController.reconcileWithPreferences()` is:
    /// `UserDefaults.didChangeNotification` fires for every key in the suite
    /// and for same-value rewrites, so this runs far more often than the
    /// switch moves, and when the feature is on it is one boolean read.
    ///
    /// The reverse is deliberately not symmetric. Turning reminders back on
    /// mid-pause does not start a watch: there is no anchor — the pause it
    /// would be measured from happened while the app was not looking — and a
    /// watch armed at the hiker's *current* position would quietly measure
    /// the wrong thing. The next pause is watched normally.
    func reconcileWithPreferences() {
        guard !isEnabled else { return }
        let wasWatching = pausedRecording != nil
        pausedRecording = nil
        pausedWalk = nil
        stillness = StillnessWatch()
        for kind in MovementReminderKind.allCases { withdraw(kind) }
        if wasWatching { watchingDidEnd() }
    }

    /// Watches both things that can silence a reminder, each by the only
    /// means that reports it: the hiker's switch through the defaults
    /// notification — scoped to this controller's own suite rather than the
    /// process-wide one, which is how `SettingsView`'s `@AppStorage` write
    /// arrives here — and iOS's permission on the way back into the
    /// foreground.
    private func observePreferences() {
        #if canImport(UIKit)
        // The system's permission is not a default, and changing it means
        // leaving for iOS Settings, so coming back is the only moment the app
        // can re-ask. `UIApplication`'s lifecycle message rather than
        // `scenePhase` keeps this off SwiftUI's render path — the same seam,
        // watched the same way, that `HikeLiveActivityController` uses for the
        // system's Live Activity switch. A `MainActorMessage` handler is
        // synchronously main-actor isolated, so there is no hop to make.
        lifecycleObservers.append(
            lifecycleCenter.addObserver(
                for: UIApplication.DidBecomeActiveMessage.self
            ) { [weak self] _ in
                self?.reconcileWithAuthorization(prompting: false)
            }
        )
        #endif
        // No typed message for this one, and it arrives on whichever thread
        // wrote the key, so the hop stays explicit.
        defaultsObservers.append(
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: defaults,
                queue: nil
            ) { [weak self] _ in
                onMainActor { self?.reconcileWithPreferences() }
            }
        )
    }

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

    /// Asks iOS whether a reminder can be delivered at all, and gives the
    /// watch back if it cannot.
    ///
    /// This is the half the hiker's switch cannot see. ``isEnabled`` is read
    /// on every decision, but iOS's own answer is not a default and cannot be
    /// read without asking: a hiker who refuses the prompt — or who refused
    /// it months ago, so no prompt even appears — leaves a pause armed for a
    /// banner that can never arrive. For the recording that is not merely
    /// pointless, it is expensive: with When In Use authorization the feed a
    /// pause keeps alive holds a background activity session and the location
    /// indicator for as long as the pause lasts. A refusal is the hiker
    /// saying no as plainly as the switch does, and it has to cost them the
    /// same nothing.
    ///
    /// Only the recording's watch is given back. A paused walk spends no
    /// sensor of its own — it reads fixes the app was producing anyway — so
    /// there is nothing to reclaim, and dropping its anchor would only lose a
    /// reminder the hiker could still enable permission for from Settings.
    ///
    /// - Parameter prompting: whether the hiker may be asked. True at a
    ///   pause, which is a question about something they are doing right now;
    ///   false on the way back into the foreground, where the only new
    ///   information is a permission revoked in iOS Settings and a prompt
    ///   would be the app asking again about a pause taken half an hour ago.
    ///   The foreground observer in ``observePreferences()`` is what passes
    ///   `false`; a suite drives both halves — this call for the policy, and
    ///   a post on the controller's own `lifecycleCenter` for the observer
    ///   that reaches it. The same choice `OrphanedActivityTests` makes, and
    ///   for the same reason.
    ///
    /// Enqueued rather than awaited, for the reason every other call to the
    /// notifier is: a pause has a journal write and a Live Activity update to
    /// get on with. The recorder reads ``isWatchingPausedRecording`` when it
    /// parks its sensors rather than waiting on this.
    ///
    /// Which is why the pause's identity is captured and checked again on the
    /// other side. The notification centre takes as long as the hiker does
    /// to read a prompt, and a denial that lands after they have resumed —
    /// or resumed, walked on and paused again — would otherwise park the
    /// sensors of a recording that is running, or take a watch from a pause
    /// nobody refused.
    func reconcileWithAuthorization(prompting: Bool) {
        let watched = pausedRecording?.id
        guard prompting || watched != nil else { return }
        enqueue { [weak self] in
            guard let self else { return }
            let mayPost = prompting
                ? await notifier.authorize()
                : await notifier.canPost()
            guard !mayPost, let watched, pausedRecording?.id == watched else { return }
            pausedRecording = nil
            watchingDidEnd()
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
