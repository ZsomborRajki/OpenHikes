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
//  run at launch, which covers the watch having been rebooted in between, and
//  whenever the app comes to the front, which covers a phone that refused a
//  walk and then stayed in range.
//
//  Every queue call is awaited on ``WatchWalkQueue``, off the main actor. The
//  count comes from file names and a walk is read only when the link is about
//  to send it, so a queue that grew while the phone was away costs this
//  actor nothing to count.
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
    /// How many finished walks are still waiting for the phone. Zero until
    /// ``start()``'s drain has asked the queue.
    private(set) var queuedWalkCount = 0
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
    /// The trail the hiker last opened, which decides whether an arriving
    /// package is the answer the screen is waiting for or a late one — see
    /// ``WatchTrailSelection``.
    @ObservationIgnored private var selection = WatchTrailSelection()
    /// Whether a trail screen is asking for live position right now, and so
    /// what a screen coming and going, a trail landing and a recording
    /// stopping each do to the receiver — see ``WatchFollowClaim``.
    @ObservationIgnored private var followClaim = WatchFollowClaim()
    /// Whether ``start()`` has run. `false` on a seeded launch, whose queue
    /// count is the fixture's and must not be recounted from a disk it never
    /// wrote.
    @ObservationIgnored private var isStarted = false
    /// The queue as last applied to ``queuedWalkCount``, so an answer that
    /// resumes after a later one cannot put the count back — see
    /// ``WatchQueuedWalks/isNewer(than:)``.
    @ObservationIgnored private var queuedWalks: WatchQueuedWalks?

    init(store: WatchStore = WatchStore()) {
        self.store = store
        recorder = WatchRecorder(store: store)
        library = store.loadLibrary()
        trail = store.loadTrail()
        if let trail { tracker = WatchRouteTracker(trail) }
        recorder.onFix = { [weak self] location in self?.advanceFollow(with: location) }
        recorder.onWalkQueued = { [weak self] walk, queued in self?.walkQueued(walk, queued: queued) }
        recorder.onRecordingEnded = { [weak self] in self?.recordingEnded() }
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
        isStarted = true
        link.activate { [weak self] delivery in self?.apply(delivery) }
        drainQueue()
        askForLibraryIfEmpty()
    }

    /// The app came to the front: ask for a library it lacks, and offer any
    /// walk the phone has not acknowledged whose wait has run out.
    ///
    /// The drain matters for a phone that refused a walk and never left
    /// range — no reachability change will come to retry it, and a hiker
    /// opening the app to look at a walk still waiting is the moment to.
    func cameToFront() {
        askForLibraryIfEmpty()
        if isStarted { drainQueue() }
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
    ///
    /// Asked even when it is — a trail edited on the phone would otherwise be
    /// the old route on this watch for good, since the package is persisted.
    /// The request names the revision held, so the phone answers only if the
    /// route has changed and the held copy is drawn and matched against in the
    /// meantime, in or out of range.
    func selectTrail(_ hikeID: UUID) {
        let request = selection.select(hikeID, holding: trail)
        if trail?.hikeID != hikeID { follow.clear() }
        link.requestTrail(request)
    }

    /// A trail screen came on screen and claims the live position feed.
    ///
    /// The feed starts now only when the watch holds this screen's trail and
    /// no recording is already running it; otherwise the claim waits for the
    /// trail to land or the recording to stop. See
    /// ``WatchRecorder/startFollowingFeed()`` for what the feed does and does
    /// not buy.
    ///
    /// - Parameters:
    ///   - hikeID: the trail the screen shows. Another trail held here is not
    ///     one it can show a position on, so it starts nothing.
    ///   - screen: the screen claiming, the same when it leaves.
    func startFollowing(_ hikeID: UUID, for screen: UUID) {
        let recording = recorder.phase.isActive
        applyToReceiver(
            followClaim.screenAppeared(screen, asking: hikeID, holding: trail?.followableHikeID, recording: recording)
        )
    }

    /// A trail screen left. Its claim goes with it whether or not anything is
    /// recording; a recording keeps the receiver, which is its own.
    func stopFollowing(for screen: UUID) {
        applyToReceiver(followClaim.screenLeft(screen, recording: recorder.phase.isActive))
    }

    /// The app left the screen or came back to it. A map still pushed when it
    /// leaves gets no `onDisappear`, and the receiver would go on delivering
    /// behind it — see ``WatchFollowClaim``.
    func sceneMoved(onScreen: Bool) {
        let recording = recorder.phase.isActive
        applyToReceiver(
            onScreen
                ? followClaim.appReturned(holding: trail?.followableHikeID, recording: recording)
                : followClaim.appLeftScreen(recording: recording)
        )
    }

    private func applyToReceiver(_ change: WatchFollowClaim.FeedChange) {
        #if DEBUG
        // A seeded launch already has the position it was asked for, matched
        // through the real tracker — see ``applySeededFixture()``. Starting
        // the receiver for a follow would hand ``advanceFollow(with:)``
        // whatever the simulator happens to be standing on and overwrite it,
        // which is a screenshot of a hiker a continent off their trail. Here
        // rather than in ``startFollowing(_:for:)`` alone, so a Stop, a trail
        // landing or a return to the screen cannot start it on a seeded
        // screen either, and a return cannot clear the seeded position.
        if WatchLaunchEnvironment.configuration.isUITesting { return }
        #endif
        switch change {
        case .start:
            recorder.startFollowingFeed()
        case .restart:
            // The gap ``resumeRecording()`` lets go of for a pause, here for
            // the app's time off screen. Kept, the anchor would hold the
            // first fix to the ground around where the app left, which on an
            // out-and-back is the outbound leg for the whole way home, and
            // the figures would go on showing the last reading as current
            // until a new fix replaced it.
            tracker?.forgetPosition()
            follow.clear()
            recorder.startFollowingFeed()
        case .stop:
            recorder.stopFollowingFeed()
        case .unchanged:
            break
        }
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

    /// Stops. The walk, if there was one, goes through
    /// ``walkQueued(_:queued:)``, and the receiver through
    /// ``recordingEnded()``.
    func stopRecording() async {
        await recorder.stop()
    }

    /// A recording ended and took the receiver down with it, whether the
    /// hiker pressed Stop or a workout session failed under them.
    ///
    /// The hook rather than the tail of ``stopRecording()``, for the reason
    /// ``walkQueued(_:queued:)`` is one: a failed session stops the recorder
    /// without passing through here, and a trail map open behind it went on
    /// showing the reading from the moment it failed (issue #1021).
    private func recordingEnded() {
        // A walk along a trail leaves the hiker where they finished it, which
        // is where they are. Nothing is cleared — but the receiver is: the
        // recording owned it and stopping took it down, and a trail screen
        // left open behind it would freeze the hiker's dot where the
        // recording ended. A screen already gone asks for nothing.
        applyToReceiver(followClaim.recordingStopped(holding: trail?.followableHikeID))
    }

    /// Tries again to write a walk that Stop could not. A success goes
    /// through ``walkQueued(_:queued:)`` like any other.
    func retrySavingWalk() async {
        await recorder.retrySave()
    }

    /// Throws away a walk that could not be written.
    func discardUnsavedWalk() {
        recorder.discardUnsaved()
    }

    /// Carries on recording a walk the last process never finished.
    ///
    /// Refused while the phone is recording, for the reason
    /// ``startRecording(alongTrail:)`` is: carrying on is starting again.
    func continueInterruptedRecording() async {
        guard !isPhoneRecording else { return }
        await recorder.continueInterrupted()
    }

    /// Keeps a walk the last process never finished, as it stood. A walk kept
    /// goes through ``walkQueued(_:queued:)`` like any other.
    func saveInterruptedRecording() async {
        await recorder.saveInterrupted()
    }

    func discardInterruptedRecording() {
        recorder.discardInterrupted()
    }

    /// Offers a walk the recorder has just put on the disk queue.
    ///
    /// The hook rather than ``stopRecording()``'s own return value, because a
    /// recording does not always end with the hiker's Stop: a workout session
    /// that fails takes it down, and the walk it leaves behind would otherwise
    /// sit on disk until the next launch or the next reachability change.
    private func walkQueued(_ walk: WatchRecordedWalk, queued: WatchQueuedWalks) {
        apply(queued)
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
            // A new list is the phone saying its library changed, and the
            // trail held here may be what changed. Asking costs one small
            // request and nothing comes back unless it did — see
            // ``selectTrail(_:)``. Which trail to ask about is the
            // selection's to say: see
            // ``WatchTrailSelection/refreshTarget(holding:in:)``.
            if let hikeID = selection.refreshTarget(holding: trail, in: digest) {
                link.requestTrail(selection.refresh(hikeID, holding: trail))
            }
        case .trail(let package):
            // An answer to a request the hiker has moved on from, or an older
            // copy of the trail held. Taken, it would put another trail under
            // the screen that is open and leave it waiting for good.
            guard selection.accepts(package, replacing: trail) else {
                Self.logger.debug("Dropped a trail package that arrived after a newer selection or revision")
                return
            }
            selection.took(package)
            trail = package
            tracker = WatchRouteTracker(package)
            follow.clear()
            store.save(package)
            // The screen that asked for this trail may have opened with
            // nothing to match against, which is every first launch: its
            // ``startFollowing(_:for:)`` had no trail of its own to start a
            // feed for. This is that moment arriving, if this is its trail.
            applyToReceiver(
                followClaim.trailArrived(holding: trail?.followableHikeID, recording: recorder.phase.isActive)
            )
        case .walkKept(let sessionID):
            Task { [weak self, store] in
                let queued = await store.walks.remove(sessionID)
                // Forgotten only once the file is gone, so a drain in between
                // still finds the walk crossing rather than due again.
                self?.link.forget(sessionID)
                self?.apply(queued)
            }
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

    /// Offers every queued walk again, bar the ones ``PhoneLink`` holds back
    /// as still crossing or not yet due a retry — see `WatchWalkDelivery`.
    ///
    /// Sending a walk the phone already has is safe by construction: the
    /// import is keyed on `sessionID` and recognises an arrival it has seen,
    /// which is why a receipt can be lost without costing anything but one
    /// more transfer. See `WatchWalkImport` on the phone.
    private func drainQueue() {
        Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        let queued = await store.walks.pending()
        apply(queued)
        guard !queued.isEmpty else { return }
        Self.logger.debug("Offering \(queued.count, privacy: .public) queued walk(s) to the phone")
        var isAnyUnread = false
        for sessionID in queued.sessionIDs where link.isDue(sessionID) {
            // One at a time, and only a walk the link will take: the read is
            // the whole recording.
            guard let walk = await store.walks.walk(sessionID) else {
                isAnyUnread = true
                continue
            }
            link.send(walk)
        }
        // A walk that does not decode leaves the queue's count — see
        // ``WatchWalkQueue/walk(_:)`` — and the screen should say so. One
        // whose receipt landed mid-drain has already said so itself.
        if isAnyUnread { apply(await store.walks.pending()) }
    }

    private func apply(_ queued: WatchQueuedWalks) {
        guard queued.isNewer(than: queuedWalks) else { return }
        queuedWalks = queued
        queuedWalkCount = queued.count
    }
}
