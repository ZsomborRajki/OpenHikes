//
//  HikeRecorder+State.swift
//  OpenTrails
//
//  Supporting types for HikeRecorder: failure cases, location authorization,
//  source protocols, recovery summary, stop outcome, and review state.
//

import CoreLocation
import Foundation
import Observation
import OpenTrailsShared
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
        case .preciseLocationRequired: "Turn on Precise Location for OpenTrails in Settings."
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
    func startRecordingUpdates()
    func stopRecordingUpdates()
}

final class SystemRecordingLocationSource: RecordingLocationSource {
    private static let logger = Logger(
        subsystem: "OpenTrails",
        category: "RecordingLocation"
    )

    private let manager = CLLocationManager()

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
        guard manager.accuracyAuthorization == .reducedAccuracy else {
            return
        }
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

    func startRecordingUpdates() {
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        startBackgroundActivitySession()
        #endif
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.startUpdatingLocation()
    }

    func stopRecordingUpdates() {
        manager.stopUpdatingLocation()
        #if os(iOS)
        sessionDiagnostics?.cancel()
        sessionDiagnostics = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        #endif
    }

    #if os(iOS)
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
    /// below. It also makes the status indicator *tappable*: the walker who
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
    /// is asked the walker is off the mountain and the state that would have
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
        static let maximumExponent = 30
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
        let exponent = min(
            max(0, failures - 1),
            Defaults.maximumExponent
        )
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
        guard let current else {
            return
        }
        choices[current.id] = choice
    }

    func moveBackward() {
        guard canMoveBackward else {
            return
        }
        currentIndex -= 1
    }

    func moveForward() {
        guard canMoveForward else {
            return
        }
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
