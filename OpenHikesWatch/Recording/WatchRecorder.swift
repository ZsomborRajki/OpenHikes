//
//  WatchRecorder.swift
//  OpenHikesWatch
//
//  Recording a hike on the watch, with no phone involved.
//
//  ## The workout session is not about Health
//
//  It is about staying alive. watchOS suspends an ordinary app within seconds
//  of the wrist dropping, and a recording that stopped there would be a
//  recording of the first minute of every walk. An `HKWorkoutSession` with
//  `workout-processing` in `WKBackgroundModes` is the only thing that keeps
//  this process running and its location updates arriving for six hours, so
//  the session is started before the first fix is asked for and ended after
//  the last one is kept.
//
//  What it is emphatically *not* is a second writer of workouts.
//  `HealthKitWorkoutWriter` in the app already saves a finished hike to Health
//  when the hiker has turned that on, and a watch that finished its own
//  builder would put a second workout in Health for the same walk — one from
//  each device, neither wrong, both there. So the builder is **discarded**
//  rather than finished, on every path out of a recording. The walk becomes a
//  workout when it becomes a hike, once, on the phone.
//
//  The one thing the session *is* read for is the hiker's heart rate, which is
//  the figure a watch can show and a phone cannot, and which comes off the
//  live builder while the session runs.
//
//  ## Whose recording this is
//
//  The watch's, from the first fix to the last. See ``WatchRecordedWalk``'s
//  header for why there is no live payload and no shared phase: two recorders
//  that can each be authoritative is a synchronisation problem rather than a
//  port, and this app does not create one. The phone's `HikeRecorder` is never
//  told a watch recording is happening.
//

import CoreLocation
import Foundation
import HealthKit
import Observation
import OpenHikesShared
import os

@MainActor
@Observable
final class WatchRecorder: NSObject {
    nonisolated private static let logger = Logger(subsystem: "OpenHikesWatch", category: "Recorder")

    /// Where a recording is.
    ///
    /// `.failed` carries what to say rather than an error to inspect: every
    /// way this can fail ends with a hiker reading one line on a small screen,
    /// and there is nothing here for a caller to branch on.
    enum Phase: Equatable {
        case idle
        /// Asking for location and Health permission, which can take as long
        /// as the hiker takes to answer.
        case preparing
        case recording
        case paused
        /// Stopped, and the walk is on disk waiting for the phone.
        case saved(WatchRecordedWalk)
        /// Stopped, and the walk could not be written. This is the only copy
        /// of it, so nothing starts over it until ``retrySave()`` writes it or
        /// ``discardUnsaved()`` throws it away — see ``WatchStoppedWalk``.
        case unsaved(WatchRecordedWalk)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .recording, .paused: true
            case .idle, .preparing, .saved, .unsaved, .failed: false
            }
        }

        /// Whether Start may begin a recording from here.
        var canStart: Bool {
            switch self {
            case .idle, .saved, .failed: true
            // `.preparing` is the half that is easy to miss: it suspends on a
            // permission prompt the hiker can take as long as they like over,
            // and two taps before it resolves would otherwise start a second
            // `HKWorkoutSession`, leak the first unended and reset the
            // accumulator under a recording that was already running.
            // `.unsaved` would reset it under a walk nothing else holds.
            case .preparing, .recording, .paused, .unsaved: false
            }
        }
    }

    private(set) var phase: Phase = .idle

    /// Whether the hiker has refused this watch location outright.
    ///
    /// Starting a *recording* on a refusal already fails out loud — see
    /// ``requestPermissions()``, which is where the same complaint was
    /// answered for the button that starts a walk. Following a trail had no
    /// such moment: ``startFollowingFeed()`` asked for updates that were never
    /// going to arrive, and the map simply never drew the hiker. The route was
    /// still worth looking at, so the screen keeps drawing it and says this
    /// underneath instead.
    private(set) var isLocationRefused = false
    /// The live figures. A stable object the root never reads — see
    /// ``WatchRecordingStats``.
    let stats = WatchRecordingStats()

    /// Called once per accepted fix, so a trail being followed can be advanced
    /// from the same feed rather than by a second `CLLocationManager`.
    ///
    /// One receiver for two jobs, which is the same reason the app hands one
    /// `HikeLiveActivityController` to both its recorder and its tracker: two
    /// location managers on a watch is twice the radio for one hiker.
    var onFix: (@MainActor (CLLocation) -> Void)?

    /// Called once whenever a recording ends with a walk on the disk queue.
    ///
    /// A callback rather than the return of ``stop()`` alone, because ``stop()``
    /// is not always the hiker's: a workout session that fails takes the
    /// recording down with it, and the walk it leaves behind has to be offered
    /// to the phone by the same path a hiker's own Stop uses.
    var onWalkQueued: (@MainActor (WatchRecordedWalk) -> Void)?

    @ObservationIgnored private let store: WatchStore
    /// The complication's copy of this recording — see ``WatchGlance``.
    @ObservationIgnored private let glances = WatchGlancePublisher()
    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private let locations = CLLocationManager()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var accumulator = WatchWalkAccumulator()
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var startedAt = Date.now
    @ObservationIgnored private var trailHikeID: UUID?
    @ObservationIgnored private var trailTitle: String?
    /// The start that is waiting for the hiker to answer the location prompt.
    /// Resumed by ``locationManagerDidChangeAuthorization(_:)`` and by nothing
    /// else; `nil` whenever no start is waiting.
    @ObservationIgnored private var authorizationWaiter: CheckedContinuation<CLAuthorizationStatus, Never>?

    init(store: WatchStore) {
        self.store = store
        super.init()
        // On the main actor, which is what makes every delivery below take
        // `onMainActor`'s synchronous path — see WatchMainActorDelivery.swift.
        locations.delegate = self
        locations.desiredAccuracy = kCLLocationAccuracyBest
        locations.distanceFilter = WatchFixPolicy.minimumDisplacement
        locations.allowsBackgroundLocationUpdates = true
        // Nothing survives a relaunch — a recording lives in this process and
        // no other — so a complication still showing one is showing a walk
        // that ended with the last process. Said now, rather than left to
        // tick for the six hours ``WatchGlanceDisplay/staleAfter`` allows.
        publishGlance()
    }

    /// Starts a recording, optionally naming the trail being walked.
    func start(trailHikeID: UUID? = nil, title: String? = nil) async {
        guard phase.canStart else { return }
        phase = .preparing
        self.trailHikeID = trailHikeID
        trailTitle = title
        sessionID = UUID()
        startedAt = .now
        accumulator = WatchWalkAccumulator()
        stats.reset()

        guard await requestPermissions() else { return }
        guard startWorkoutSession() else { return }
        locations.startUpdatingLocation()
        phase = .recording
        publishGlance()
    }

    func pause() {
        guard phase == .recording else { return }
        accumulator.pause()
        session?.pause()
        // The feed is left running rather than stopped. On a phone a pause can
        // afford to drop to significant-location-change monitoring, because
        // the process survives; here the workout session is what keeps this
        // app alive at all, and a paused session that also stopped its
        // location updates would be a recording the system is free to suspend
        // and never resume.
        phase = .paused
        publishGlance()
    }

    func resume() {
        guard phase == .paused else { return }
        session?.resume()
        phase = .recording
        publishGlance()
    }

    /// Stops, writes the walk to disk and hands it back for sending.
    ///
    /// Returns `nil` for a recording with nothing in it, which is a hiker who
    /// started and stopped before their watch had a second fix — told so on
    /// the watch, where they can do something about it, rather than sent to
    /// become a row they have to find and delete. Also `nil` for a walk the
    /// disk refused, which stays in hand as ``Phase/unsaved(_:)`` for
    /// ``retrySave()``.
    @discardableResult func stop() -> WatchRecordedWalk? {
        guard phase.isActive else { return nil }
        locations.stopUpdatingLocation()
        endWorkoutSession()
        // Whatever happens to the walk below, nothing is being recorded now.
        glances.publish(.idle(at: .now))

        let walk = accumulator.recordedWalk(
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: .now,
            trailHikeID: trailHikeID,
            title: trailTitle
        )
        return settle(WatchStoppedWalk.settle(walk, writing: store.enqueue))
    }

    /// Writes an unsaved walk again, and offers it to the phone once it is on
    /// disk. The same walk under the same session ID, so however often this
    /// is pressed the phone is sent one walk.
    @discardableResult func retrySave() -> WatchRecordedWalk? {
        guard case .unsaved(let walk) = phase else { return nil }
        return settle(WatchStoppedWalk.unsaved(walk).retried(writing: store.enqueue))
    }

    /// Throws away a walk that could not be written, which only the hiker
    /// decides.
    func discardUnsaved() {
        guard case .unsaved = phase else { return }
        phase = .idle
    }

    /// The phase a stopped walk leaves behind.
    ///
    /// On disk before anything is told it exists — the ordering ``WatchStore``
    /// exists for — so ``onWalkQueued`` is called for a saved walk and never
    /// for an unsaved one.
    private func settle(_ stopped: WatchStoppedWalk) -> WatchRecordedWalk? {
        switch stopped {
        case .tooShort:
            phase = .failed("That walk was too short to keep.")
            return nil
        case .unsaved(let walk):
            phase = .unsaved(walk)
            return nil
        case .saved(let walk):
            phase = .saved(walk)
            onWalkQueued?(walk)
            return walk
        }
    }

    /// Clears a finished or failed recording once the hiker has seen it.
    ///
    /// Never an unsaved one: dismissing that is ``discardUnsaved()``, a
    /// decision rather than an acknowledgement.
    func acknowledge() {
        switch phase {
        case .saved, .failed: phase = .idle
        case .idle, .preparing, .recording, .paused, .unsaved: break
        }
    }

    // MARK: Permissions

    private func requestPermissions() async -> Bool {
        switch await locationAuthorization() {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        case .denied, .restricted, .notDetermined:
            // Said out loud rather than started anyway. Without this the
            // recording ran: a workout session holding the app awake, a
            // location feed nothing was ever delivered to, "Finding your
            // position…" for as long as the hiker left it, and "that walk was
            // too short to keep" at the end of it.
            phase = .failed("OpenHikes needs location access to record a hike.")
            return false
        @unknown default:
            break
        }

        guard HKHealthStore.isHealthDataAvailable() else {
            phase = .failed("This watch can't start a workout, so a recording couldn't stay running.")
            return false
        }
        do {
            // Share is what a session needs; heart rate is the one thing read.
            // Nothing is written at the end — see this file's header.
            try await healthStore.requestAuthorization(
                toShare: [HKQuantityType.workoutType()],
                read: [HKQuantityType(.heartRate)]
            )
            return true
        } catch {
            Self.logger.error("Health authorization failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed("OpenHikes needs permission to start a workout, which is what keeps a recording running.")
            return false
        }
    }

    /// The hiker's answer to the location prompt, asked for if it has not
    /// been asked for yet.
    ///
    /// `requestWhenInUseAuthorization()` returns the instant it is called and
    /// says nothing about what was chosen, so a start that merely called it
    /// and carried on would be a start that proceeds on a denial. The answer
    /// arrives at the delegate, and this is what waits for it — the same
    /// shape the app's own recorder takes, which also holds a start open
    /// until the grant lands.
    private func locationAuthorization() async -> CLAuthorizationStatus {
        let status = locations.authorizationStatus
        guard status == .notDetermined else { return status }
        locations.requestWhenInUseAuthorization()
        return await withCheckedContinuation { continuation in
            // Nothing can have interleaved between the request above and this
            // closure — both run without suspending on this actor — but the
            // re-read costs nothing and makes that an assumption the code
            // does not depend on.
            let settled = locations.authorizationStatus
            if settled == .notDetermined {
                authorizationWaiter = continuation
            } else {
                continuation.resume(returning: settled)
            }
        }
    }

    /// Lets a waiting start go, once there is something to tell it.
    private func authorizationSettled(as status: CLAuthorizationStatus) {
        // Ahead of the waiter, and outside its guard: a grant answered with no
        // start waiting on it is exactly the case the caption is for — the
        // hiker following a trail who went to Settings about it.
        isLocationRefused = Self.isRefused(status)
        guard status != .notDetermined, let waiter = authorizationWaiter else { return }
        authorizationWaiter = nil
        waiter.resume(returning: status)
    }

    // MARK: The workout session

    private func startWorkoutSession() -> Bool {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .hiking
        configuration.locationType = .outdoor
        do {
            let started = try HKWorkoutSession(
                healthStore: healthStore,
                configuration: configuration
            )
            let collector = started.associatedWorkoutBuilder()
            collector.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            collector.delegate = self
            started.delegate = self
            let startDate = Date.now
            started.startActivity(with: startDate)
            collector.beginCollection(withStart: startDate) { _, error in
                if let error {
                    Self.logger.error(
                        "Workout collection did not begin: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            session = started
            builder = collector
            return true
        } catch {
            Self.logger.error("Workout session failed to start: \(error.localizedDescription, privacy: .public)")
            phase = .failed("A workout couldn't be started, so a recording wouldn't survive the screen going dark.")
            return false
        }
    }

    #if DEBUG
    /// Puts a recording on the screen without starting one.
    ///
    /// For `Scripts/watch-screenshots.sh`, which needs a walk that is already
    /// four kilometres in. A real recording cannot be asked for one: an
    /// `HKWorkoutSession` started now reads zero, and the only way to a
    /// non-zero figure is to walk a simulator for an hour. So the phase and
    /// the figures are set and neither the session nor the location feed is
    /// touched — which also means **nothing here can be stopped**, because
    /// there is nothing running to stop. ``stop()`` on a seeded phase would
    /// write a walk with no fixes in it; the frames never press it.
    ///
    /// Compiled out of a shipping build with everything else behind
    /// ``WatchLaunchEnvironment``.
    func applySeededRecording(_ phase: Phase, stats snapshot: WatchWalkAccumulatorSnapshot) {
        self.phase = phase
        stats.update(from: snapshot)
    }
    #endif

    /// Ends the session and throws the builder's workout away.
    ///
    /// `discardWorkout` rather than `finishWorkout`, deliberately and on every
    /// path. See this file's header: the phone is the one writer of workouts,
    /// and a watch that finished this builder would put a second one in Health
    /// for the same walk.
    private func endWorkoutSession() {
        session?.end()
        builder?.discardWorkout()
        session = nil
        builder = nil
    }

    // MARK: Fixes

    private func received(_ location: CLLocation) {
        guard phase == .recording else { return }
        let elevation = location.verticalAccuracy > 0 ? location.altitude : nil
        let kept = accumulator.accept(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            timestamp: location.timestamp,
            horizontalAccuracy: location.horizontalAccuracy,
            elevationMeters: elevation
        )
        guard kept else { return }
        stats.update(
            from: WatchWalkAccumulatorSnapshot(
                distanceMeters: accumulator.distanceMeters,
                activeSeconds: accumulator.activeSeconds,
                elevationGainMeters: accumulator.elevationGainMeters,
                averageSpeedMetersPerSecond: accumulator.averageSpeedMetersPerSecond,
                fixCount: accumulator.fixes.count
            )
        )
        publishGlance(asOf: location.timestamp)
        onFix?(location)
    }

    /// What the complication is told: the phase and the figures as they
    /// stand. Asked on every fix and every phase change; the publisher's
    /// policy decides which of those are worth a write and a redraw.
    ///
    /// `asOf` is the moment the accumulator's clock was read at: a fix's own
    /// timestamp, since ``WatchWalkAccumulator/activeSeconds`` runs to the
    /// last kept fix and a batch can be delivered late.
    private func publishGlance(asOf date: Date = .now) {
        let state: WatchGlance.State = switch phase {
        case .recording: .recording
        case .paused: .paused
        case .idle, .preparing, .saved, .unsaved, .failed: .idle
        }
        glances.publish(
            WatchGlance(
                state: state,
                distanceMeters: accumulator.distanceMeters,
                activeSeconds: accumulator.activeSeconds,
                updatedAt: date
            )
        )
    }

    /// Fixes arriving while nothing is being recorded, so a trail can still be
    /// followed without a recording — which is half of what this app is for.
    private func receivedWhileIdle(_ location: CLLocation) {
        guard !phase.isActive else { return }
        onFix?(location)
    }

    /// Starts the location feed without a recording, for following a trail.
    ///
    /// No workout session, and so no background survival: a hiker following a
    /// trail without recording it gets a live position while the app is on
    /// screen and nothing behind it. That is the honest cost of not starting a
    /// workout somebody did not ask for, and the recording button is right
    /// there.
    func startFollowingFeed() {
        guard !phase.isActive else { return }
        let status = locations.authorizationStatus
        isLocationRefused = Self.isRefused(status)
        if status == .notDetermined {
            locations.requestWhenInUseAuthorization()
        }
        // Started even on a refusal, deliberately. It delivers nothing, costs
        // nothing, and is the one call that makes the feed live the instant a
        // grant arrives — without it a hiker who fixed this in Settings would
        // come back to a map that stayed blank until they left the screen and
        // returned to it.
        locations.startUpdatingLocation()
    }

    /// `.restricted` counts with `.denied`: from here they are the same, and
    /// the only place either can change is the watch's own Settings.
    private static func isRefused(_ status: CLAuthorizationStatus) -> Bool {
        status == .denied || status == .restricted
    }

    func stopFollowingFeed() {
        guard !phase.isActive else { return }
        locations.stopUpdatingLocation()
    }
}

/// `nonisolated` on the extension, which is the spelling the repository
/// instructions require under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated extension WatchRecorder: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations fixes: [CLLocation]) {
        // Sorted here rather than trusted: Core Location batches, and a batch
        // out of order meets the accumulator's `interval > 0` guard and loses
        // the older fix silently.
        let sorted = fixes.sorted { $0.timestamp < $1.timestamp }
        onMainActor { [weak self] in
            guard let self else { return }
            for location in sorted {
                if phase == .recording {
                    received(location)
                } else {
                    receivedWhileIdle(location)
                }
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        onMainActor { [weak self] in self?.authorizationSettled(as: status) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Logged and not surfaced. Core Location reports a transient
        // `kCLErrorLocationUnknown` under trees and in gullies, on a walk
        // where it will resolve itself, and a banner for each one would be a
        // banner most of the way up a mountain.
        Self.logger.debug("Location failed: \(error.localizedDescription, privacy: .public)")
    }
}

nonisolated extension WatchRecorder: HKWorkoutSessionDelegate {
    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        // Read rather than obeyed. The hiker's buttons are the authority on
        // whether a recording is running — the same rule the app's recorder
        // keeps — and this is the system telling us what it did with the
        // session we asked for.
        Self.logger.debug("Workout session moved to state \(toState.rawValue, privacy: .public)")
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Self.logger.error("Workout session failed: \(error.localizedDescription, privacy: .public)")
        onMainActor { [weak self] in
            guard let self, phase.isActive else { return }
            // The session is what keeps this app running, so losing it is not
            // a detail — but the walk so far is on the accumulator and stop()
            // will keep it. Stopping is therefore better than carrying on
            // into a suspension nobody would be told about.
            stop()
        }
    }
}

nonisolated extension WatchRecorder: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Nothing here reads workout events. The walk's own pauses are the
        // accumulator's, and its distance is measured from the fixes rather
        // than from what HealthKit made of them.
    }

    func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard collectedTypes.contains(HKQuantityType(.heartRate)),
              let statistics = workoutBuilder.statistics(for: HKQuantityType(.heartRate))
        else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let beats = statistics.mostRecentQuantity()?.doubleValue(for: unit)
        onMainActor { [weak self] in self?.stats.update(heartRateBPM: beats) }
    }
}
