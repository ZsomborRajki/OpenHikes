//
//  HealthKitWorkoutWriter.swift
//  OpenHikes
//
//  The one file that speaks HealthKit.
//
//  Everything above ``HikeWorkoutWriting`` is a value with no framework in it,
//  for the reason that protocol's header gives; this is where that stops being
//  true, and it is deliberately the whole of it.
//
//  ## A post-hoc write, not a session
//
//  There is no `HKWorkoutSession` on iOS, so nothing here runs while the hike
//  does. `HKWorkoutBuilder` is handed a finished walk at save time, which is
//  also the cheap one: the recording already owns its own clock, its own
//  distance and its own barometric ascent, and none of it is measured twice.
//
//  ## What a failure means
//
//  Nothing. A refused or failed write leaves no workout, no route and no
//  half-finished builder in the hiker's Health store, which is why this needs
//  no owner and no sweep the way files written outside SwiftData do. The
//  caller logs and moves on; the hike is already saved.
//

import CoreLocation
import Foundation
import HealthKit
import OpenHikesData
import os

@MainActor
final class HealthKitWorkoutWriter: HikeWorkoutWriting {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Health")

    private let store = HKHealthStore()

    /// Write-only. No `.readTypes` anywhere in this file — see
    /// ``HikeWorkoutWriting``.
    private var shareTypes: Set<HKSampleType> {
        [
            HKQuantityType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.distanceWalkingRunning),
        ]
    }

    /// `false` on a device with no Health store at all, which is not a device
    /// this app ships to but is what a simulator can be.
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var isAuthorizationDetermined: Bool {
        guard Self.isAvailable else { return false }
        // `.notDetermined` is the only answer that means "has not been asked".
        // `.sharingDenied` is an answer, and a settled one: Apple deliberately
        // does not tell an app whether a *read* was refused, but a share
        // refusal is reportable and is not a reason to ask again.
        return store.authorizationStatus(for: HKQuantityType.workoutType()) != .notDetermined
    }

    private func requestAuthorization() async -> Bool {
        guard Self.isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: [])
            return store.authorizationStatus(for: HKQuantityType.workoutType()) == .sharingAuthorized
        } catch {
            Self.logger.error(
                "Health authorization failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    func write(_ request: HikeWorkoutRequest) async throws -> UUID {
        guard Self.isAvailable else { throw HikeWorkoutFailure.unavailable }
        // Asked at the first write rather than when the switch is flipped,
        // which is the shape *Also Save to Photos* already takes and the
        // reason its footer says the same thing. Not re-asked afterwards:
        // HealthKit answers a second `requestAuthorization` for a type the
        // hiker has refused by doing nothing at all, so a refusal that is not
        // remembered is a prompt that never appears and a write that silently
        // fails forever.
        if !isAuthorizationDetermined {
            _ = await requestAuthorization()
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .hiking
        configuration.locationType = .outdoor

        let builder = HKWorkoutBuilder(
            healthStore: store,
            configuration: configuration,
            device: .local()
        )
        try await builder.beginCollection(at: request.startedAt)
        let events = Self.events(for: request)
        if !events.isEmpty {
            try await builder.addWorkoutEvents(events)
        }
        try await builder.addSamples([distanceSample(for: request)])
        let metadata = Self.metadata(for: request)
        if !metadata.isEmpty {
            try await builder.addMetadata(metadata)
        }
        try await builder.endCollection(at: request.endedAt)
        guard let workout = try await builder.finishWorkout() else {
            throw HikeWorkoutFailure.notWritten
        }

        // The line on the workout's own map. After the workout exists, because
        // a route builder needs something to belong to — and separately, so a
        // route that cannot be written does not cost the workout that can.
        await attachRoute(request.route, to: workout)
        return workout.uuid
    }

    /// Deletes by predicate rather than by sample, which is what keeps this
    /// file write-only.
    ///
    /// `HKHealthStore.delete(_:)` wants the `HKWorkout` itself, and getting
    /// one means an `HKSampleQuery`, which means `.workoutType()` in
    /// `readTypes` — the authorization this app has never asked for and whose
    /// absence the Settings footer states. `deleteObjects(of:predicate:)`
    /// needs only the share access already granted, and
    /// `HKQuery.predicateForObject(with:)` names exactly the one workout by
    /// its UUID.
    ///
    /// **It can only reach this app's own samples, which is the other half of
    /// why it is safe.** HealthKit refuses a delete of an object another
    /// source wrote, so the worst a wrong identifier can do is delete
    /// nothing — and the identifier is not guessed: it is what
    /// ``write(_:)`` returned and ``HikeLocalState/healthWorkoutID`` stored.
    ///
    /// A count of zero is not an error. The hiker may have deleted the
    /// workout in the Health app already, which is a perfectly ordinary
    /// thing to have done and leaves this with nothing to do.
    func delete(workoutID: UUID) async throws {
        guard Self.isAvailable else { throw HikeWorkoutFailure.unavailable }
        try await store.deleteObjects(
            of: HKQuantityType.workoutType(),
            predicate: HKQuery.predicateForObject(with: workoutID)
        )
    }

    /// A pause and a resume around each of the request's pauses, which is
    /// what takes them out of `elapsedTime(at:)` and so out of the workout's
    /// duration — see ``HikeWorkoutPauses``.
    ///
    /// No resume for a pause that runs to the end: that is a walk stopped
    /// while paused, and a resume at the instant it ended would say it
    /// started again.
    private static func events(for request: HikeWorkoutRequest) -> [HKWorkoutEvent] {
        request.pauses.flatMap { pause in
            var events = [Self.event(.pause, at: pause.start)]
            if pause.end < request.endedAt {
                events.append(Self.event(.resume, at: pause.end))
            }
            return events
        }
    }

    private static func event(_ type: HKWorkoutEventType, at date: Date) -> HKWorkoutEvent {
        HKWorkoutEvent(type: type, dateInterval: DateInterval(start: date, duration: 0), metadata: nil)
    }

    /// The climb, the descent and the weather, each only when the request
    /// has it: a missing key is Health drawing nothing, where a zero would be
    /// Health drawing a claim.
    ///
    /// Metadata on a sample this app wrote, and nothing read — so the
    /// write-only promise in ``HikeWorkoutWriting`` holds as written.
    private static func metadata(for request: HikeWorkoutRequest) -> [String: Any] {
        var metadata: [String: Any] = [:]
        if let ascent = request.elevationGainMeters {
            metadata[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: ascent)
        }
        if let descent = request.elevationLossMeters {
            metadata[HKMetadataKeyElevationDescended] = HKQuantity(unit: .meter(), doubleValue: descent)
        }
        if let weather = request.weather {
            metadata[HKMetadataKeyWeatherTemperature] = HKQuantity(
                unit: .degreeCelsius(),
                doubleValue: weather.temperature.converted(to: .celsius).value
            )
            metadata[HKMetadataKeyWeatherHumidity] = HKQuantity(
                unit: .percent(),
                doubleValue: weather.humidity
            )
        }
        return metadata
    }

    /// The walked distance as one sample spanning the whole workout.
    ///
    /// One sample rather than a series: the figure that matters is
    /// ``PreparedRecording/distanceMeters``, which already has its stationary
    /// windows retracted, and re-deriving a per-segment series from the saved
    /// line would be a second opinion that could only disagree with the number
    /// the hike itself shows.
    private func distanceSample(for request: HikeWorkoutRequest) -> HKQuantitySample {
        HKQuantitySample(
            type: HKQuantityType(.distanceWalkingRunning),
            quantity: HKQuantity(unit: .meter(), doubleValue: request.distanceMeters),
            start: request.startedAt,
            end: request.endedAt
        )
    }

    /// Logged rather than thrown: the workout is already in the store by the
    /// time this runs, and losing the line is a worse outcome to report as a
    /// total failure than it is to accept quietly.
    private func attachRoute(_ route: [RouteCoordinate], to workout: HKWorkout) async {
        let locations = route.compactMap(Self.location)
        guard !locations.isEmpty else { return }
        let builder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        do {
            try await builder.insertRouteData(locations)
            _ = try await builder.finishRoute(with: workout, metadata: nil)
        } catch {
            Self.logger.error(
                "Workout route not written: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// A saved point as Core Location sees it.
    ///
    /// A route point with no timestamp is dropped rather than stamped with
    /// `Date.now`: `insertRouteData` orders by time, and inventing one would
    /// put a point somewhere on the walk it never was. Imported routes are the
    /// case — a recording always stamps its own.
    private static func location(from coordinate: RouteCoordinate) -> CLLocation? {
        guard let timestamp = coordinate.timestamp else { return nil }
        let position = CLLocationCoordinate2D(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        guard CLLocationCoordinate2DIsValid(position) else { return nil }
        return CLLocation(
            coordinate: position,
            altitude: coordinate.elevation ?? 0,
            horizontalAccuracy: kCLLocationAccuracyNearestTenMeters,
            verticalAccuracy: coordinate.elevation == nil ? -1 : kCLLocationAccuracyNearestTenMeters,
            timestamp: timestamp
        )
    }
}

/// Why a workout did not reach Health.
///
/// Two cases, and neither is reported to the hiker: the caller is
/// fire-and-forget and the hike is already saved either way — see
/// ``HikeWorkoutWriting/write(_:)``.
/// The cases are alphabetical, which `sorted_enum_cases` requires and nothing
/// here minds: no code compares two of these.
nonisolated enum HikeWorkoutFailure: Error, Equatable {
    /// `finishWorkout()` answered with nothing.
    case notWritten
    /// The device has no Health store.
    case unavailable
}
