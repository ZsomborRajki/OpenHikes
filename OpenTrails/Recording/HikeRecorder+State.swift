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
        #endif
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.startUpdatingLocation()
    }

    func stopRecordingUpdates() {
        manager.stopUpdatingLocation()
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        #endif
    }
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

@Observable
final class RecordingAmbiguityReview {
    nonisolated deinit { /* intentionally ignored */ }

    let ambiguities: [TrailMatchAmbiguity]
    private(set) var currentIndex = 0
    private(set) var choices: [Int: TrailAmbiguityChoice]

    init(ambiguities: [TrailMatchAmbiguity]) {
        self.ambiguities = ambiguities
        choices = Dictionary(
            uniqueKeysWithValues: ambiguities.map { ($0.id, .gps) }
        )
    }

    var current: TrailMatchAmbiguity? {
        ambiguities.indices.contains(currentIndex)
            ? ambiguities[currentIndex]
            : nil
    }

    var canMoveBackward: Bool {
        currentIndex > 0
    }

    var canMoveForward: Bool {
        currentIndex + 1 < ambiguities.count
    }

    func select(_ choice: TrailAmbiguityChoice) {
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

nonisolated struct PendingAmbiguitySave: Sendable {
    let session: TrackJournalSession
    let normalizedPoints: [RecordingPoint]
    let matchResult: TrailMatchResult
}
