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
    /// Set while a trail has been asked for and has not arrived.
    private(set) var awaitingTrail: UUID?
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

    init(store: WatchStore = WatchStore()) {
        self.store = store
        recorder = WatchRecorder(store: store)
        library = store.loadLibrary()
        trail = store.loadTrail()
        queuedWalkCount = store.queuedWalks().count
        if let trail { tracker = WatchRouteTracker(trail) }
        recorder.onFix = { [weak self] location in self?.advanceFollow(with: location) }
    }

    /// Starts the link and sends whatever is already waiting.
    func start() {
        link.activate { [weak self] delivery in self?.apply(delivery) }
        drainQueue()
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
        awaitingTrail = hikeID
        follow.clear()
        link.requestTrail(hikeID)
    }

    /// Starts the live position feed for a trail being followed without a
    /// recording. See ``WatchRecorder/startFollowingFeed()`` for what this
    /// does and does not buy.
    func startFollowing() {
        guard trail != nil else { return }
        recorder.startFollowingFeed()
    }

    func stopFollowing() {
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

    /// Stops, and sends the walk if it survived being stopped.
    func stopRecording() {
        guard let walk = recorder.stop() else {
            queuedWalkCount = store.queuedWalks().count
            return
        }
        queuedWalkCount = store.queuedWalks().count
        link.send(walk)
        // A walk along a trail leaves the hiker where they finished it, which
        // is where they are. Nothing is cleared.
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
            if awaitingTrail == package.hikeID { awaitingTrail = nil }
        case .walkKept(let sessionID):
            store.removeWalk(sessionID)
            queuedWalkCount = store.queuedWalks().count
        case .phoneRecording(let recording):
            apply(recording)
        case .commandOutcome(let outcome):
            pendingCommand = nil
            commandRefusal = outcome.refusal
            apply(outcome.recording)
        case .reachabilityChanged(let isReachable):
            if isReachable {
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
