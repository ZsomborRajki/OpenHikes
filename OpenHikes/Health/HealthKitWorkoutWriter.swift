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
//  Nothing here runs while the hike does. `HKWorkoutBuilder` is handed a
//  finished walk once the hike is saved, and that is a choice, not a limit of
//  the platform.
//
//  An iPhone can run a workout session of its own only from iOS 26, which is
//  where `HKWorkoutSession(healthStore:configuration:)`, its
//  `associatedWorkoutBuilder()` and `HKLiveWorkoutBuilder` arrive; before that
//  the class reaches a phone only as a session mirrored from a watch. That is
//  above the deployment floor, so a session would mean a second writer behind
//  `#available`, with this one still beside it as the fallback (see
//  *Deployment floor* in `AGENTS.md`). And it would buy the recording nothing:
//
//  - The recording needs no session to stay alive. The `location` background
//    mode keeps it running here; on the watch a session is the only thing
//    that does, which is why `WatchRecorder` starts one.
//  - The figures already exist. The recording owns its own clock, its own
//    distance and its own barometric ascent, and a live builder would collect
//    a second set that could only disagree with the hike's. A write
//    afterwards measures none of it twice.
//  - Health must never hold a walk this app does not, so the write waits for
//    a successful save. A builder started at Start would break that rule from
//    its first sample, which is saved to Health as it is added. Throwing the
//    builder away on a path that saves nothing — a discard, a refused save —
//    keeps out only the workout: `discardWorkout()` leaves the samples where
//    they are (`HKWorkoutBuilder.h` says both).
//  - The same write takes the watch's walks (``WatchWalkHealthExport``),
//    which no session on this phone ever saw, so one writer serves both
//    devices.
//
//  ## What a failure leaves
//
//  Not always nothing, and `HKWorkoutBuilder.h` names both ways in.
//  `addSamples` saves the distance as it is added: "The samples will be saved
//  to the database if they have not already been saved." So a throw at any
//  later step leaves the distance in Health with no workout around it, and
//  `discardWorkout()` would not take it back. And `finishWorkout()` can save
//  the workout and hand nothing back: "If both workout and error are nil then
//  finishing the workout succeeded but the workout sample is not available
//  because the device is locked." A phone locked in a pocket while the watch's
//  Stop saves the walk is that case.
//
//  Health cannot be read here, so unlike a file written outside SwiftData
//  (*Persistence and sync* in `AGENTS.md`) nothing can sweep for either
//  afterwards. Instead:
//
//  - **Everything a write saves carries the hike's identifier**, as
//    `HKMetadataKeyExternalUUID`: the distance sample, the workout and the
//    route. A deletion finds them by it, rather than by an object identifier
//    Health may never have handed back. See *The tag* below.
//  - **A locked finish is a write.** The workout is in Health, so the caller
//    is told it landed. It has no route, because a route is finished against
//    the `HKWorkout` itself.
//  - **A failure after the distance sample takes back what it saved** before
//    it throws, with the same deletion the hike's own would make.
//
//  What even that cannot take back, such as a take-back Health refuses or a
//  write this process never comes back to finish, is still the hike's
//  deletion's to find, because ``HikeWorkoutExport`` marks the hike before
//  Health hears anything (``HikeLocalState/wroteToHealth``). The caller logs
//  and moves on; the hike is already saved.
//
//  ## The tag
//
//  The hike's own identifier, because that is what Apple documents the key
//  for: "You typically use the UUID from the corresponding data entry on your
//  server", shared by every copy of that entry. `HKMetadata.h` says HealthKit
//  does not enforce its uniqueness, and it is unique where it is searched: a
//  hike has one workout, one route and one distance sample, and a deletion
//  searches one type at a time.
//
//  A deletion names each of the three types. Neither `HKHealthStore.h` nor
//  Apple's pages on deleting say that a workout takes its route or its samples
//  with it, and a type with nothing left under the tag costs a count of zero.
//
//  ## The seam
//
//  ``HealthWorkoutStore`` and ``HealthWorkoutBuilding`` are the calls this
//  writer makes, one requirement each, except the route's, which covers the
//  route builder's two calls. ``HealthKitStore`` passes them straight to
//  HealthKit. So the order, the tag, what counts as written and what a
//  failure takes back all stay in this writer, where
//  `HealthKitWorkoutWriterTests` runs them against a scripted store.
//

import CoreLocation
import Foundation
import HealthKit
import OpenHikesData
import os

@MainActor
final class HealthKitWorkoutWriter: HikeWorkoutWriting {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Health")

    private let store: any HealthWorkoutStore

    /// - Parameter store: This phone's Health store, or a suite's script of
    ///   one — see *The seam* in this file's header.
    init(store: any HealthWorkoutStore = HealthKitStore()) {
        self.store = store
    }

    /// What a write saves, and so what a deletion takes back.
    private static var savedTypes: [HKSampleType] {
        [
            HKQuantityType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.distanceWalkingRunning),
        ]
    }

    /// Write-only. No `.readTypes` anywhere in this file — see
    /// ``HikeWorkoutWriting``.
    private var shareTypes: Set<HKSampleType> { Set(Self.savedTypes) }

    /// `false` on a device with no Health store at all, which is not a device
    /// this app ships to but is what a simulator can be.
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var isAuthorizationDetermined: Bool {
        guard store.isHealthDataAvailable else { return false }
        // `.notDetermined` is the only answer that means "has not been asked".
        // `.sharingDenied` is an answer, and a settled one: Apple deliberately
        // does not tell an app whether a *read* was refused, but a share
        // refusal is reportable and is not a reason to ask again.
        return store.authorizationStatus(for: HKQuantityType.workoutType()) != .notDetermined
    }

    private func requestAuthorization() async -> Bool {
        guard store.isHealthDataAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: shareTypes)
            return store.authorizationStatus(for: HKQuantityType.workoutType()) == .sharingAuthorized
        } catch {
            Self.logger.error(
                "Health authorization failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    func write(_ request: HikeWorkoutRequest) async throws {
        guard store.isHealthDataAvailable else { throw HikeWorkoutFailure.unavailable }
        // Asked at the first write rather than when the switch is flipped,
        // which is the shape *Also Save to Photos* already takes. Not re-asked
        // afterwards: HealthKit answers a second `requestAuthorization` for a
        // type the hiker has refused by doing nothing at all, so a refusal
        // that is not remembered is a prompt that never appears and a write
        // that silently fails forever.
        if !isAuthorizationDetermined {
            _ = await requestAuthorization()
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .hiking
        configuration.locationType = .outdoor

        let builder = store.workoutBuilder(for: configuration)
        try await builder.beginCollection(at: request.startedAt)
        let events = Self.events(for: request)
        if !events.isEmpty {
            try await builder.addWorkoutEvents(events)
        }
        // Health can hold part of this write from the distance sample on,
        // so a failure from here takes back what was saved before it is
        // reported. See *What a failure leaves* in this file's header.
        do {
            try await builder.addSamples([Self.distanceSample(for: request)])
            try await builder.addMetadata(Self.metadata(for: request))
            try await builder.endCollection(at: request.endedAt)
            guard try await builder.finishWorkout() != nil else {
                // Saved, and not handed back, which is a locked phone's
                // answer. A write all the same, and one its hike's
                // deletion finds by the tag.
                Self.logger.notice(
                    """
                    Health kept the workout for \(request.hikeID, privacy: .private) \
                    while the device was locked, without its route
                    """
                )
                return
            }
        } catch {
            await takeBack(request.hikeID)
            throw error
        }

        // The line on the workout's own map. After the workout exists, because
        // a route builder needs something to belong to — and separately, so a
        // route that cannot be written does not cost the workout that can.
        await attachRoute(request, to: builder)
    }

    /// Deletes by predicate rather than by sample, which is what keeps this
    /// file write-only.
    ///
    /// `HKHealthStore.delete(_:)` wants the objects themselves, and getting
    /// them means an `HKSampleQuery`, which means read types — the
    /// authorization this app has never asked for and whose absence the
    /// Health purpose strings in `OpenHikes/Info.plist` state.
    /// `deleteObjects(of:predicate:)` deletes "objects saved by this
    /// application that match the provided type and predicate", and the only
    /// authorization Apple's page for it names is share: it fails with
    /// `errorAuthorizationNotDetermined` for a type never asked to share and
    /// `errorAuthorizationDenied` for one refused.
    ///
    /// **It can only reach this app's own samples, which is the other half of
    /// why it is safe.** HealthKit refuses a delete of an object another
    /// source wrote, so the worst a wrong tag can do is delete nothing — and
    /// the tag is not guessed: it is the hike's own identifier, which
    /// ``write(_:)`` put on everything it saved.
    ///
    /// Every type is asked even after one refuses. A hiker can turn one type
    /// off in Health's own settings and leave the others on, and that refusal
    /// is no reason to keep the rest. The first refusal is what this throws.
    ///
    /// A count of zero is not an error. The hiker may have deleted the
    /// workout in the Health app already, a failed write may have taken its
    /// own sample back, and Health may take a workout's route with it.
    func deleteWorkout(of hikeID: UUID) async throws {
        guard store.isHealthDataAvailable else { throw HikeWorkoutFailure.unavailable }
        var refusal: (any Error)?
        for type in Self.savedTypes {
            do {
                try await store.deleteObjects(of: type, predicate: Self.tagged(hikeID))
            } catch {
                refusal = refusal ?? error
            }
        }
        if let refusal { throw refusal }
    }

    /// Takes back what a failed write may have saved, with the deletion the
    /// hike's own would make.
    ///
    /// Logged rather than thrown: the write's own failure is the one its
    /// caller hears about, and what this cannot take back the hike's deletion
    /// still asks for, since the hike was marked before the write began.
    private func takeBack(_ hikeID: UUID) async {
        do {
            try await deleteWorkout(of: hikeID)
        } catch {
            Self.logger.error(
                """
                A failed Health write kept what it saved for \(hikeID, privacy: .private): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }

    /// The tag on everything a write saves — see *The tag* in this file's
    /// header.
    private static func tag(_ hikeID: UUID) -> [String: Any] {
        [HKMetadataKeyExternalUUID: hikeID.uuidString]
    }

    /// Whatever this app saved under `hikeID`'s tag, in the one type a
    /// deletion asks about.
    private static func tagged(_ hikeID: UUID) -> NSPredicate {
        HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeyExternalUUID,
            allowedValues: [hikeID.uuidString]
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
    /// Health drawing a claim. And the hike's tag, always.
    ///
    /// Metadata on a sample this app wrote, and nothing read — so the
    /// write-only promise in ``HikeWorkoutWriting`` holds as written.
    private static func metadata(for request: HikeWorkoutRequest) -> [String: Any] {
        var metadata = tag(request.hikeID)
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
    private static func distanceSample(for request: HikeWorkoutRequest) -> HKQuantitySample {
        HKQuantitySample(
            type: HKQuantityType(.distanceWalkingRunning),
            quantity: HKQuantity(unit: .meter(), doubleValue: request.distanceMeters),
            start: request.startedAt,
            end: request.endedAt,
            metadata: tag(request.hikeID)
        )
    }

    /// Logged rather than thrown: the workout is already in the store by the
    /// time this runs, and losing the line is a worse outcome to report as a
    /// total failure than it is to accept quietly.
    private func attachRoute(_ request: HikeWorkoutRequest, to builder: any HealthWorkoutBuilding) async {
        let locations = request.route.compactMap(Self.location)
        guard !locations.isEmpty else { return }
        do {
            try await builder.finishRoute(locations, metadata: Self.tag(request.hikeID))
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

// MARK: - The calls

/// The HealthKit calls a write and a deletion make, as a seam a suite can
/// script.
///
/// Deliberately thin: each requirement is one call on `HKHealthStore` or
/// `HKWorkoutBuilder`, which ``HealthKitStore`` passes straight through. The
/// one exception is ``HealthWorkoutBuilding/finishRoute(_:metadata:)``, which
/// covers the two calls an `HKWorkoutRouteBuilder` takes. So every decision
/// stays in ``HealthKitWorkoutWriter``: the order of the calls, the tag on
/// what they save, what counts as written, and what a failure takes back.
/// Those are the decisions a stub standing in for ``HikeWorkoutWriting``
/// cannot reach. Such a stub can fail a write or let it succeed, but it
/// cannot be a Health store that saved a workout and handed nothing back, or
/// one that kept a sample and then refused the workout.
///
/// Authorization asks for share types only. There is no read parameter
/// anywhere on this, so nothing above it can ask for one.
@MainActor
protocol HealthWorkoutStore {
    var isHealthDataAvailable: Bool { get }

    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus
    func requestAuthorization(toShare types: Set<HKSampleType>) async throws
    func workoutBuilder(for configuration: HKWorkoutConfiguration) -> any HealthWorkoutBuilding
    func deleteObjects(of type: HKObjectType, predicate: NSPredicate) async throws
}

/// One `HKWorkoutBuilder`, call for call, and the route that goes onto the
/// workout it finished.
@MainActor
protocol HealthWorkoutBuilding {
    func beginCollection(at date: Date) async throws
    func addWorkoutEvents(_ events: [HKWorkoutEvent]) async throws
    func addSamples(_ samples: [HKSample]) async throws
    func addMetadata(_ metadata: [String: Any]) async throws
    func endCollection(at date: Date) async throws
    /// The identifier of the workout Health saved and handed back, or `nil`
    /// when it saved one and handed nothing back. That is not a failure:
    /// `HKWorkoutBuilder.h` says a nil workout with a nil error means
    /// "finishing the workout succeeded but the workout sample is not
    /// available because the device is locked".
    func finishWorkout() async throws -> UUID?
    /// Saves `locations` as the route of the workout ``finishWorkout()``
    /// handed back. A route needs the workout itself to belong to, so there is
    /// none after a finish that handed nothing back.
    func finishRoute(_ locations: [CLLocation], metadata: [String: Any]) async throws
}

/// This phone's own Health store, the only one the shipping app writes to.
@MainActor
struct HealthKitStore: HealthWorkoutStore {
    private let store = HKHealthStore()

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus {
        store.authorizationStatus(for: type)
    }

    func requestAuthorization(toShare types: Set<HKSampleType>) async throws {
        try await store.requestAuthorization(toShare: types, read: [])
    }

    func workoutBuilder(for configuration: HKWorkoutConfiguration) -> any HealthWorkoutBuilding {
        HealthKitBuilder(store: store, configuration: configuration)
    }

    func deleteObjects(of type: HKObjectType, predicate: NSPredicate) async throws {
        try await store.deleteObjects(of: type, predicate: predicate)
    }
}

/// An `HKWorkoutBuilder` on this phone's store, and the route builder its
/// workout's line goes through.
@MainActor
private final class HealthKitBuilder: HealthWorkoutBuilding {
    private let store: HKHealthStore
    private let builder: HKWorkoutBuilder
    /// What `finishWorkout()` handed back, which the route is finished
    /// against. `nil` before the finish, and after one that handed nothing
    /// back.
    private var workout: HKWorkout?

    init(store: HKHealthStore, configuration: HKWorkoutConfiguration) {
        self.store = store
        builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
    }

    func beginCollection(at date: Date) async throws {
        try await builder.beginCollection(at: date)
    }

    func addWorkoutEvents(_ events: [HKWorkoutEvent]) async throws {
        try await builder.addWorkoutEvents(events)
    }

    func addSamples(_ samples: [HKSample]) async throws {
        try await builder.addSamples(samples)
    }

    func addMetadata(_ metadata: [String: Any]) async throws {
        try await builder.addMetadata(metadata)
    }

    func endCollection(at date: Date) async throws {
        try await builder.endCollection(at: date)
    }

    func finishWorkout() async throws -> UUID? {
        workout = try await builder.finishWorkout()
        return workout?.uuid
    }

    func finishRoute(_ locations: [CLLocation], metadata: [String: Any]) async throws {
        guard let workout else { return }
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        try await routeBuilder.insertRouteData(locations)
        _ = try await routeBuilder.finishRoute(with: workout, metadata: metadata)
    }
}

/// Why a workout did not reach Health, when the reason is this app's to give
/// rather than HealthKit's.
///
/// Not reported to the hiker: the caller is fire-and-forget and the hike is
/// already saved either way — see ``HikeWorkoutWriting/write(_:)``. There is
/// no case for a finish that handed nothing back, because that is a write:
/// see *What a failure leaves* in this file's header.
nonisolated enum HikeWorkoutFailure: Error, Equatable {
    /// The device has no Health store.
    case unavailable
}
