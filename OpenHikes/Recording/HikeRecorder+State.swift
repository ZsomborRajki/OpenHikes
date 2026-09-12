//
//  HikeRecorder+State.swift
//  OpenHikes
//
//  Supporting types for HikeRecorder: failure cases, location authorization,
//  source protocols, recovery summary, stop outcome, trail-graph prefetch
//  retry state, and the pending-save and review state.
//

import CoreLocation
import Foundation
import Observation
import os
import SwiftData

nonisolated enum RecordingFailure: LocalizedError, Equatable, Sendable {
    case locationDenied
    case preciseLocationRequired
    case save(String)
    case storage(String)
    case storageUnavailable
    case tooShort

    var errorDescription: String? {
        switch self {
        case .locationDenied: "Location access is needed to record a hike."
        case .preciseLocationRequired: "Precise Location is needed to record a hike."
        case .save: "The recorded hike couldn't be saved."
        case .storage: "The recording could not be written safely."
        case .storageUnavailable: "The recording journal couldn't be created."
        case .tooShort: "This recording has only one track point."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .locationDenied: "Allow location access in Settings, then try again."
        case .preciseLocationRequired: "Turn on Precise Location for OpenHikes in Settings."
        case .save(let detail), .storage(let detail): detail
        case .storageUnavailable: "Check that the app has storage available, then try again."
        case .tooShort: "A hike needs at least two points to have a route."
        }
    }
}

enum RecordingLocationAuthorization: Equatable {
    case authorized
    case denied
    case notDetermined
}

protocol RecordingLocationSource: AnyObject {
    var authorization: RecordingLocationAuthorization { get }
    var hasFullAccuracy: Bool { get }
    var sourceDelegate: CLLocationManagerDelegate? { get set }

    func requestWhenInUseAuthorization()
    func requestTemporaryFullAccuracy() async
    func startRecordingUpdates(profile: RecordingEnergyProfile)
    /// Re-configures an already-running session. Separate from starting one
    /// because the energy profile changes *during* a hike — a hiker stops, a
    /// battery drops into Low Power Mode — and tearing down and restarting
    /// location updates to say so would drop the background activity session
    /// with them.
    func apply(_ profile: RecordingEnergyProfile)
    func stopRecordingUpdates()
    /// Swaps a running recording's delivery for the cheapest one that can
    /// still notice the hiker has set off again, and back.
    ///
    /// Separate from the energy profile above because it is not a
    /// configuration of the same feed: with Always authorization it is
    /// significant-location-change monitoring, which needs neither the
    /// background mode nor the activity session and so takes the status
    /// indicator off the hiker's screen for the length of the pause. Only
    /// without it does the watch stay a — deliberately coarse — continuous
    /// feed, because a when-in-use app that stops updating location is
    /// suspended and would notice nothing at all.
    ///
    /// Started only when something will read it: see
    /// ``MovementReminderController/recordingDidPause(at:on:)``, whose answer
    /// is what the recorder calls this on. A pause with reminders off stops
    /// the sensors outright, exactly as it did before either existed.
    func startMovementWatch()
    func stopMovementWatch()
    /// Ends a background activity session this app left outstanding when a
    /// previous launch died without stopping cleanly.
    ///
    /// Separate from ``stopRecordingUpdates()`` because the two have nothing
    /// in common but the word "stop". That one releases a session *this*
    /// process is holding; this one releases a session that outlived the
    /// process that made it, which no reference in memory points at any more.
    func releaseOrphanedBackgroundActivity()
}

extension RecordingLocationSource {
    /// So a stub that only cares about start/stop is not obliged to model the
    /// energy profile as well.
    func apply(_ profile: RecordingEnergyProfile) {
        // Nothing to do: the default is to ignore the profile entirely.
    }

    /// Likewise: a source with no background activity session has none to
    /// orphan, and nothing to do here.
    func releaseOrphanedBackgroundActivity() {
        // Nothing to do: the default source holds no background session.
    }

    /// And likewise: a source that models one feed keeps delivering it, which
    /// is what a suite driving fixes into a paused recorder wants.
    func startMovementWatch() {
        // Nothing to do: the default source has one delivery mode.
    }

    func stopMovementWatch() {
        // Nothing to do, for the same reason.
    }
}

final class SystemRecordingLocationSource: RecordingLocationSource {
    private static let logger = Logger(
        subsystem: "OpenHikes",
        category: "RecordingLocation"
    )

    private let manager = CLLocationManager()
    /// The profile currently pushed at `CLLocationManager`. Held so a
    /// re-evaluation that reaches the same answer — which is most of them,
    /// since the conditions are checked on every accepted fix — costs nothing
    /// rather than two property writes into the location daemon.
    private var appliedProfile: RecordingEnergyProfile?

    #if os(iOS)
    /// The outstanding background activity session, held so it can be
    /// invalidated when recording stops. See ``startBackgroundActivitySession()``.
    private var backgroundSession: CLBackgroundActivitySession?
    /// Drains that session's diagnostics for as long as it is held.
    private var sessionDiagnostics: Task<Void, Never>?
    #endif

    var authorization: RecordingLocationAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    var hasFullAccuracy: Bool {
        #if os(iOS)
        manager.accuracyAuthorization == .fullAccuracy
        #else
        true
        #endif
    }

    var sourceDelegate: CLLocationManagerDelegate? {
        get { manager.delegate }
        set { manager.delegate = newValue }
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func requestTemporaryFullAccuracy() async {
        #if os(iOS)
        guard manager.accuracyAuthorization == .reducedAccuracy else { return }
        do {
            try await manager.requestTemporaryFullAccuracyAuthorization(
                withPurposeKey: "RecordHike"
            )
        } catch {
            Self.logger.error(
                "Temporary full-accuracy request failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        #endif
    }

    func startRecordingUpdates(profile: RecordingEnergyProfile) {
        // A recording feed and a pause's watch are two answers to the same
        // question, so starting one ends the other — including a watch armed
        // by a launch that is no longer running, which is the case
        // ``stopMovementWatch()`` is unconditional for. The paused-watch
        // profile is the one caller that arrives *through* this and has
        // nothing to clear.
        if profile != .pausedWatch { stopMovementWatch() }
        manager.activityType = .fitness
        // Still `false`, and still deliberately. CoreLocation's automatic
        // pause is keyed on the device looking stationary *and* the app being
        // in the background, and it does not resume on its own — a hike that
        // paused at a summit view could stay paused for the descent. The
        // app's own stationary handling in ``RecordingEnergyPolicy`` raises
        // the distance filter instead, which stops the wakeups without ever
        // stopping delivery.
        manager.pausesLocationUpdatesAutomatically = false
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        startBackgroundActivitySession()
        #endif
        apply(profile)
        manager.startUpdatingLocation()
    }

    func apply(_ profile: RecordingEnergyProfile) {
        guard profile != appliedProfile else { return }
        appliedProfile = profile
        manager.desiredAccuracy = profile.desiredAccuracy
        manager.distanceFilter = profile.distanceFilter
        RenderSignpost.mark(
            "RecordingEnergyProfileApplied",
            "\(profile.name) filter=\(profile.distanceFilter)"
        )
    }

    func stopRecordingUpdates() {
        stopMovementWatch()
        manager.stopUpdatingLocation()
        appliedProfile = nil
        #if os(iOS)
        endBackgroundActivitySession()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        #endif
    }

    /// The two ways a paused recording can be watched, and which one this
    /// hiker's authorization allows.
    ///
    /// Always: significant location changes. They cost nothing — the system is
    /// already computing them for other apps — they wake or relaunch this
    /// process, and they arrive roughly every five hundred metres, which is
    /// the same figure ``MovementReminderPolicy/awayMeters`` is written
    /// against. The continuous feed, the background mode and the activity
    /// session all go for the length of the pause, and the status indicator
    /// goes with them: a paused hike stops showing the hiker a pill that says
    /// their location is being used.
    ///
    /// When in use: the feed has to keep running, because an app that stops
    /// updating location is suspended and a suspended app notices nothing.
    /// So the profile drops to ``RecordingEnergyProfile/pausedWatch`` and
    /// everything else stays exactly where a running recording left it —
    /// including the indicator, which is honest, since location really is
    /// still being used.
    func startMovementWatch() {
        #if os(iOS)
        guard manager.authorizationStatus == .authorizedAlways else {
            // Started rather than merely reconfigured, because this is also
            // the path a relaunch takes: a session recovered into a pause has
            // no feed running to re-point, and `apply` alone would leave a
            // watch that never delivers.
            startRecordingUpdates(profile: .pausedWatch)
            return
        }
        manager.stopUpdatingLocation()
        appliedProfile = nil
        endBackgroundActivitySession()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        manager.startMonitoringSignificantLocationChanges()
        #endif
    }

    /// Unconditional, and that is the point rather than an oversight.
    ///
    /// Significant-change monitoring outlives the process that armed it — that
    /// is what makes it able to relaunch an app — so a launch that died during
    /// a pause leaves a hiker's phone waking this app every five hundred
    /// metres for a watch no object in the new process is holding. A flag
    /// saying "this process started one" would be false in exactly that
    /// launch, which is the one that has to clear it. The cost of being wrong
    /// the other way is one no-op call into the daemon.
    func stopMovementWatch() {
        #if os(iOS)
        manager.stopMonitoringSignificantLocationChanges()
        #endif
    }

    /// Reclaims the session a previous launch left outstanding, then ends it.
    ///
    /// The two steps are one gesture, not two. A session outlives the process
    /// that created it on purpose — that is what lets a relaunch pick a hike
    /// back up — but it also means a launch that *declines* to resume has no
    /// reference to invalidate, because the object holding it died with the
    /// previous process. Constructing one reclaims the outstanding session
    /// rather than opening a second (the same property
    /// ``startBackgroundActivitySession()`` relies on), so invalidating that
    /// fresh handle ends the real thing and takes the status indicator with
    /// it. Without this the hiker is left with a tappable location pill for
    /// a recording the app has already decided not to continue.
    func releaseOrphanedBackgroundActivity() {
        #if os(iOS)
        // A session this process owns belongs to a live recording. Ending it
        // here would silently stop that recording, so hand it to the code
        // that also tears down location updates.
        guard backgroundSession == nil else {
            stopRecordingUpdates()
            return
        }
        // Reclaiming needs the authorization that created it. Without that,
        // constructing a session would prompt for location on launch to end
        // something the system has already ended for us.
        guard authorization == .authorized else { return }
        CLBackgroundActivitySession().invalidate()
        #endif
    }

    #if os(iOS)
    /// Ends the session this process is holding, if it is holding one.
    ///
    /// Factored out because a *pause* ends one too, and the two paths must not
    /// disagree about what ending it involves: the diagnostics task is drained
    /// from the session, so a session invalidated with the task still running
    /// leaves a loop waiting on something that will never report again.
    private func endBackgroundActivitySession() {
        sessionDiagnostics?.cancel()
        sessionDiagnostics = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    /// Starts — or, after a relaunch, reclaims — the session that keeps this
    /// app in use for as long as it is recording.
    ///
    /// Additive to `allowsBackgroundLocationUpdates` above, not a replacement
    /// for it. That flag is still the thing that permits delivery at all, and
    /// dropping it in favour of this would stop background recording
    /// *silently* — the one failure a hike recorder cannot afford, and one no
    /// simulator run would catch.
    ///
    /// What the session adds is standing. While it is active the app counts as
    /// in direct use, so the When-In-Use authorization this source asks for
    /// keeps applying once the screen locks, instead of the recording becoming
    /// eligible for the `insufficientlyInUse` suspension CoreLocation reports
    /// below. It also makes the status indicator *tappable*: the hiker who
    /// notices the blue pill can get back to the recording from it, rather
    /// than only being told the recording exists.
    ///
    /// Creating one is also how an existing session is reclaimed. CoreLocation
    /// keeps an active session outstanding across a relaunch, but only for an
    /// app that claims it immediately on the next run — otherwise it ends.
    /// `HikeRecorder.init` starts journal recovery straight away and the
    /// resume path there calls `startRecordingUpdates()`, so the claim lands
    /// on the same launch that recovers the track rather than one interaction
    /// later.
    private func startBackgroundActivitySession() {
        // A second session would be a second claim on the same activity, and
        // only one can be held here to invalidate when recording stops.
        guard backgroundSession == nil else { return }
        let session = CLBackgroundActivitySession()
        backgroundSession = session
        sessionDiagnostics = Task { await Self.logDiagnostics(of: session) }
    }

    /// Logs the reasons CoreLocation gives for a session that has stopped
    /// counting as in use.
    ///
    /// Nothing reads these but Console, and that is the point: "my hike
    /// stopped recording" otherwise has no answer at all, and by the time it
    /// is asked the hiker is off the mountain and the state that would have
    /// explained it is gone. Deliberately not `#if DEBUG` — a debug build is
    /// exactly where this never happens.
    private static func logDiagnostics(of session: CLBackgroundActivitySession) async {
        do {
            for try await diagnostic in session.diagnostics {
                guard diagnostic.authorizationDenied
                    || diagnostic.authorizationDeniedGlobally
                    || diagnostic.authorizationRestricted
                    || diagnostic.insufficientlyInUse
                    || diagnostic.serviceSessionRequired
                else { continue }
                logger.error(
                    """
                    Background recording session suspended — \
                    denied: \(diagnostic.authorizationDenied, privacy: .public), \
                    deniedGlobally: \(diagnostic.authorizationDeniedGlobally, privacy: .public), \
                    restricted: \(diagnostic.authorizationRestricted, privacy: .public), \
                    insufficientlyInUse: \(diagnostic.insufficientlyInUse, privacy: .public), \
                    serviceSessionRequired: \(diagnostic.serviceSessionRequired, privacy: .public)
                    """
                )
            }
        } catch {
            logger.error(
                "Background session diagnostics ended: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    #endif
}

nonisolated struct RecordingRecoverySummary: Equatable, Sendable {
    let startedAt: Date
    let lastUpdatedAt: Date
    let distanceMeters: Double
    let pointCount: Int
}

enum RecordingStopOutcome {
    case needsReview
    case saved(Hike)
}

nonisolated struct TrailGraphPrefetchRetryPolicy: Sendable {
    static let standard = Self()

    private enum Defaults {
        static let initialDelay: TimeInterval = 30
        static let maximumDelay: TimeInterval = 15 * 60
        static let jitterFraction = 0.25
    }

    let initialDelay: TimeInterval
    let maximumDelay: TimeInterval
    let jitterFraction: Double

    init(
        initialDelay: TimeInterval = Defaults.initialDelay,
        maximumDelay: TimeInterval = Defaults.maximumDelay,
        jitterFraction: Double = Defaults.jitterFraction
    ) {
        let resolvedInitialDelay = max(0, initialDelay)
        self.initialDelay = resolvedInitialDelay
        self.maximumDelay = max(resolvedInitialDelay, maximumDelay)
        self.jitterFraction = max(0, jitterFraction)
    }

    func delay(afterFailures failures: Int, jitter: Double) -> TimeInterval {
        let exponent = min(max(0, failures - 1), 30)
        let baseDelay = min(
            maximumDelay,
            initialDelay * pow(2, Double(exponent))
        )
        let boundedJitter = min(max(0, jitter), 1)
        return min(
            maximumDelay,
            baseDelay * (1 + jitterFraction * boundedJitter)
        )
    }
}

enum TrailGraphPrefetchState: Equatable {
    case fetching(previousFailures: Int)
    case loaded
    case waiting(failures: Int, retryAt: Date)
}

nonisolated struct PendingPreparedSave: Sendable {
    let session: TrackJournalSession
    let prepared: PreparedRecording
    let customName: String?
}

/// The sections of a finished recording the hiker can still change, and what
/// they are currently set to. The recording is not saved until this is
/// resolved, so a review that vanishes silently would lose the hike.
@Observable
final class RecordingRouteReview {
    nonisolated deinit { /* intentionally ignored */ }

    let sections: [RouteReviewSection]
    private(set) var currentIndex = 0
    private(set) var choices: [Int: TrailRouteChoice]

    init(sections: [RouteReviewSection]) {
        self.sections = sections
        choices = Dictionary(
            uniqueKeysWithValues: sections.map { ($0.id, $0.defaultChoice) }
        )
    }

    var current: RouteReviewSection? {
        sections.indices.contains(currentIndex)
            ? sections[currentIndex]
            : nil
    }

    var canMoveBackward: Bool {
        currentIndex > 0
    }

    var canMoveForward: Bool {
        currentIndex + 1 < sections.count
    }

    /// The section choices expanded onto the legs they cover, which is the
    /// form ``TrailMatchResult/points(resolving:)`` consumes.
    var legChoices: [Int: TrailRouteChoice] {
        var expanded: [Int: TrailRouteChoice] = [:]
        for section in sections {
            let choice = choices[section.id] ?? section.defaultChoice
            for legIndex in section.legIndices {
                expanded[legIndex] = choice
            }
        }
        return expanded
    }

    func choice(for section: RouteReviewSection) -> TrailRouteChoice {
        choices[section.id] ?? section.defaultChoice
    }

    func select(_ choice: TrailRouteChoice) {
        guard let current else { return }
        choices[current.id] = choice
    }

    func moveBackward() {
        guard canMoveBackward else { return }
        currentIndex -= 1
    }

    func moveForward() {
        guard canMoveForward else { return }
        currentIndex += 1
    }
}

nonisolated struct PendingReviewSave: Sendable {
    let session: TrackJournalSession
    let normalizedPoints: [RecordingPoint]
    let matchResult: TrailMatchResult
    let customName: String?
    /// Grouped once off the main actor, so the decision to review and the
    /// review itself cannot disagree about what there is to review.
    let sections: [RouteReviewSection]
}
