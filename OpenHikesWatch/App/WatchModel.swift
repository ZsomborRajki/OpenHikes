//
//  WatchModel.swift
//  OpenHikesWatch
//
//  The composition root, in the shape `OpenHikesApp` uses on the phone: one
//  object built at launch, injected through the environment, owning the
//  long-lived dependencies and nothing transient.
//
//  ## What it owns and what it does not
//
//  It owns the link, the store, the recorder and the trail being followed. It
//  does **not** own the figures that change per fix — those are on
//  ``WatchRecordingStats`` and ``WatchFollowState``, which views read directly
//  and this object never touches. That is the render-isolation rule from the
//  repository instructions, and it is what stops a GPS fix re-running the
//  whole hierarchy on a device whose battery has to outlast the walk.
//
//  ## The queue is drained from here
//
//  Because draining is the one thing that has to happen whether or not
//  anything is on screen: a hiker finishes a walk, the phone is out of range,
//  and the walk has to go the moment it is back. ``PhoneLink`` reports
//  reachability changes as deliveries for exactly this, and the drain is also
//  run at launch, which covers the watch having been rebooted in between.
//

import CoreLocation
import Foundation
import Observation
import OpenHikesShared
import os

@MainActor
@Observable
final class WatchModel {
    nonisolated private static let logger = Logger(subsystem: "OpenHikesWatch", category: "Model")

    /// The hiker's trails, newest first. Whatever the phone last sent.
    private(set) var library: WatchLibraryDigest
    /// The trail the watch holds, if any.
    private(set) var trail: WatchTrailPackage?
    /// How many finished walks are still waiting for the phone.
    private(set) var queuedWalkCount: Int
    /// What the *phone's* recorder is doing, as far as this watch knows.
    ///
    /// `nil` until a reading has arrived, which is a different thing from
    /// idle: one means "nothing is recording on your iPhone" and the other
    /// means "this watch has not been told". The screen says them differently.
    private(set) var phoneRecording: WatchPhoneRecording?
    /// The phone's last refusal, for the hiker to read once.
    private(set) var commandRefusal: String?
    /// Set while a button is waiting for the phone to answer, so the screen
    /// can disable it rather than let a hiker press Stop three times.
    private(set) var pendingCommand: WatchRecordingCommand.Action?

    let link = PhoneLink()
    let recorder: WatchRecorder
    /// Where the hiker is on ``trail``. A stable object; nothing above a leaf
    /// view reads a property on it.
    let follow = WatchFollowState()

    @ObservationIgnored private let store: WatchStore
    /// Rebuilt whenever ``trail`` changes, and `nil` when there is none.
    @ObservationIgnored private var tracker: WatchRouteTracker?
    /// Whether a trail screen is asking for live position right now.
    ///
    /// Remembered rather than answered on the spot, because the feed and the
    /// trail arrive in either order: the *first* trail a watch is ever sent
    /// is asked for by a screen that opened with nothing to match against, so
    /// a request refused for want of a trail has to be honoured when one
    /// lands. It is also what puts the feed back after a recording along a
    /// trail ends — ``WatchRecorder/stop()`` stops the receiver, and the
    /// screen that wanted it is still open.
    @ObservationIgnored private var isFollowing = false

    init(store: WatchStore = WatchStore()) {
        self.store = store
        recorder = WatchRecorder(store: store)
        library = store.loadLibrary()
        trail = store.loadTrail()
        queuedWalkCount = store.queuedWalks().count
        if let trail { tracker = WatchRouteTracker(trail) }
        recorder.onFix = { [weak self] location in self?.advanceFollow(with: location) }
        recorder.onWalkQueued = { [weak self] walk in self?.walkQueued(walk) }
    }

    #if DEBUG
    /// Puts this watch in the state a `--ui-test-*` launch asked for.
    ///
    /// Applied *instead of* ``start()``, not before it — see
    /// `OpenHikesWatchApp`. Activating the link on a simulator with no paired
    /// phone would achieve nothing, but it would also set
    /// ``PhoneLink/isCompanionInstalled`` to `false`, and the empty-state copy
    /// branches on it: a seeded run would draw its list correctly and a run
    /// seeded with no trails would blame a missing companion app for it.
    ///
    /// Everything it writes is what a phone would have sent, so the screens
    /// below are not told they are being photographed — see
    /// ``SeededWatchFixture``.
    func applySeededFixture() {
        let fixture = SeededWatchFixture(configuration: WatchLaunchEnvironment.configuration)
        library = fixture.library
        trail = fixture.trail
        queuedWalkCount = fixture.queuedWalkCount
        phoneRecording = fixture.phoneRecording
        if let trail { tracker = WatchRouteTracker(trail) }
        if let position = fixture.position { follow.update(position) }
        if let recording = fixture.recording {
            recorder.applySeededRecording(recording.phase, stats: recording.stats)
        }
        recorder.stats.update(heartRateBPM: fixture.heartRateBPM)
    }
    #endif

    /// Starts the link and sends whatever is already waiting.
    func start() {
        link.activate { [weak self] delivery in self?.apply(delivery) }
        drainQueue()
        askForLibraryIfEmpty()
    }

    /// Asks the phone for the library, but only when there is nothing to show.
    ///
    /// The push half — an application context — covers every case but one: a
    /// watch app installed while the phone app was *already running* has no
    /// context waiting for it and no change coming, so it sat on an empty list
    /// telling the hiker to open an app that was open. Asking costs one small
    /// transfer and only happens when the list is empty, so a watch that has
    /// its trails never sends it.
    ///
    /// Called at launch, whenever the phone comes back into range, and every
    /// time the app comes to the front — a hiker who opens it again is a
    /// hiker who is already wondering why the list is empty.
    func askForLibraryIfEmpty() {
        guard library.hikes.isEmpty else { return }
        link.requestLibrary()
    }

    // MARK: Trails

    /// Asks the phone for a trail, and shows the one already held if it is
    /// this one.
    func selectTrail(_ hikeID: UUID) {
        if trail?.hikeID == hikeID {
            // Already here. Asking again would cost a transfer for geometry
            // that does not change; a trail whose route was edited on the
            // phone arrives with the next digest-driven request instead.
            return
        }
        follow.clear()
        link.requestTrail(hikeID)
    }

    /// Starts the live position feed for a trail being followed without a
    /// recording. See ``WatchRecorder/startFollowingFeed()`` for what this
    /// does and does not buy.
    func startFollowing() {
        isFollowing = true
        #if DEBUG
        // A seeded launch already has the position it was asked for, matched
        // through the real tracker — see ``applySeededFixture()``. Starting
        // the receiver here would hand ``advanceFollow(with:)`` whatever the
        // simulator happens to be standing on and overwrite it, which is a
        // screenshot of a hiker a continent off their trail.
        if WatchLaunchEnvironment.configuration.isUITesting { return }
        #endif
        guard trail != nil else { return }
        recorder.startFollowingFeed()
    }

    func stopFollowing() {
        isFollowing = false
        recorder.stopFollowingFeed()
    }

    private func advanceFollow(with location: CLLocation) {
        guard tracker?.isUsable == true,
              let position = tracker?.advance(
                  latitude: location.coordinate.latitude,
                  longitude: location.coordinate.longitude,
                  // Core Location reports a negative course when it cannot
                  // say, which is exactly when a hiker is standing still.
                  // Passed through it would point them due north and make the
                  // out-and-back tie-break worse than having none.
                  courseDegrees: location.course >= 0 ? location.course : nil
              )
        else { return }
        follow.update(position, at: location.timestamp)
    }

    // MARK: The phone's recording

    /// Whether the phone is recording, as far as this watch has been told.
    ///
    /// Used to keep the watch from starting one of its own: two hikes for one
    /// walk is the failure a hiker finds afterwards, in their library, with no
    /// way to tell which is which. The guard lives here rather than on the
    /// phone because this is the side that has the information — the phone is
    /// never told about a watch recording while it runs, by design.
    var isPhoneRecording: Bool { phoneRecording?.isActive == true }

    /// Sends a button to the phone's recorder.
    func command(_ action: WatchRecordingCommand.Action) {
        guard pendingCommand == nil else { return }
        commandRefusal = nil
        pendingCommand = action
        link.send(WatchRecordingCommand(action: action))
    }

    /// Clears a refusal the hiker has read.
    func acknowledgeRefusal() { commandRefusal = nil }

    // MARK: Recording on this watch

    /// Starts a recording, named after the trail being followed when there is
    /// one.
    func startRecording(alongTrail: Bool) async {
        // Refused rather than merely hidden. The screen does not offer this
        // while the phone is recording, but a reading can land between the tap
        // and this call, and two hikes for one walk is the failure a hiker
        // finds afterwards in their library with no way to tell which is
        // which. See ``isPhoneRecording``.
        guard !isPhoneRecording else { return }
        let along = alongTrail ? trail : nil
        await recorder.start(trailHikeID: along?.hikeID, title: along?.title)
    }

    /// Pauses the recording.
    ///
    /// Through the model rather than straight to the recorder so the *walk*
    /// and the *trail* stay one gesture: see ``resumeRecording()`` for the
    /// half that matters.
    func pauseRecording() {
        recorder.pause()
    }

    /// Resumes, and releases the trail matcher's continuity anchor.
    ///
    /// The stretch between a pause and a resume is unobserved by construction,
    /// and it can be longer than ``WatchRouteTracker/continuityWindowMeters``
    /// — a hiker who paused at a saddle and resumed at the hut has moved
    /// further than any run of rejected fixes ever would. Left anchored, the
    /// first fix after the resume is searched around where they *were* and
    /// reads as off the trail; released, it is searched against the whole
    /// trail, which is where they are.
    func resumeRecording() {
        recorder.resume()
        tracker?.forgetPosition()
        follow.clear()
    }

    /// Stops. The walk, if there was one, goes through ``walkQueued(_:)``.
    func stopRecording() {
        recorder.stop()
        // The too-short and out-of-storage paths leave nothing on the queue
        // and never reach the hook, so the count is refreshed either way.
        queuedWalkCount = store.queuedWalks().count
        // A walk along a trail leaves the hiker where they finished it, which
        // is where they are. Nothing is cleared — but the receiver is: the
        // recording owned it and stopping took it down, and a trail screen
        // left open behind it would freeze the hiker's dot where they
        // pressed Stop.
        if isFollowing { recorder.startFollowingFeed() }
    }

    /// Offers a walk the recorder has just put on the disk queue.
    ///
    /// The hook rather than ``stopRecording()``'s own return value, because a
    /// recording does not always end with the hiker's Stop: a workout session
    /// that fails takes it down, and the walk it leaves behind would otherwise
    /// sit on disk until the next launch or the next reachability change.
    private func walkQueued(_ walk: WatchRecordedWalk) {
        queuedWalkCount = store.queuedWalks().count
        link.send(walk)
    }

    // MARK: The link

    private func apply(_ delivery: PhoneDelivery) {
        switch delivery {
        case .library(let digest):
            // Older than what is held, which a transfer that crossed out of
            // order can be. Dropped rather than applied: a list that went
            // backwards would lose a trail the hiker saved this morning.
            guard digest.sentAt >= library.sentAt else { return }
            library = digest
            store.save(digest)
        case .trail(let package):
            trail = package
            tracker = WatchRouteTracker(package)
            follow.clear()
            store.save(package)
            // The screen that asked for this trail may have opened with
            // nothing to match against, which is every first launch: its
            // ``startFollowing()`` had no trail to start a feed for. This is
            // that moment arriving.
            if isFollowing { recorder.startFollowingFeed() }
        case .walkKept(let sessionID):
            store.removeWalk(sessionID)
            link.forget(sessionID)
            queuedWalkCount = store.queuedWalks().count
        case .phoneRecording(let recording):
            apply(recording)
        case .commandOutcome(let outcome):
            pendingCommand = nil
            commandRefusal = outcome.refusal
            apply(outcome.recording)
        case .reachabilityChanged(let isReachable):
            // The phone is back. If this watch still has no trails, this is
            // the moment to ask again rather than to keep waiting for a push
            // that may have nothing to push.
            if isReachable {
                askForLibraryIfEmpty()
                drainQueue()
            } else {
                // Out of range is not idle. Keeping the last reading and
                // drawing it as current would be a stopwatch running on a
                // screen whose phone might have stopped ten minutes ago; the
                // screen says "out of range" from the link instead.
                phoneRecording = nil
                pendingCommand = nil
            }
        }
    }

    /// Takes a reading, unless it is older than the one already held.
    ///
    /// A push and a command's reply can cross, and the reply is the one that
    /// matters — it describes the state the hiker's own button produced.
    private func apply(_ recording: WatchPhoneRecording) {
        if let current = phoneRecording, recording.updatedAt < current.updatedAt { return }
        phoneRecording = recording
    }

    /// Offers every queued walk again.
    ///
    /// Sending a walk the phone already has is safe by construction: the
    /// import is keyed on `sessionID` and recognises an arrival it has seen,
    /// which is why a receipt can be lost without costing anything but one
    /// more transfer. See `WatchWalkImport` on the phone.
    private func drainQueue() {
        let queued = store.queuedWalks()
        queuedWalkCount = queued.count
        guard !queued.isEmpty else { return }
        Self.logger.debug("Offering \(queued.count, privacy: .public) queued walk(s) to the phone")
        for walk in queued { link.send(walk) }
    }
}
