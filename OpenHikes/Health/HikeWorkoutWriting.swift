//
//  HikeWorkoutWriting.swift
//  OpenHikes
//
//  The seam between a finished recording and the hiker's Health store.
//
//  ## Why there is a seam at all
//
//  HealthKit is unavailable in a hosted unit test the way ActivityKit and
//  `StoreKitTest` are — see *Environment capabilities that are absent, not
//  missing*. So everything worth asserting is arranged to sit *above* this
//  protocol, and ``OpenHikesModel/makeWorkoutWriter()`` returns `nil` under
//  `isRunningTests`, matching `makeCommunityTransport()` and
//  `makeLiveActivityController(defaults:)`.
//
//  ## Why the request is a value
//
//  Nothing here imports HealthKit, for the reason ``WeatherSnapshot`` and
//  ``HikeEntity`` are values: a suite, a preview or a UI-automation launch can
//  build one without the entitlement, and the one file that speaks HealthKit
//  is the one that has to.
//
//  ## Write-only, and off by default
//
//  `.shareTypes` and no `.readTypes`. Nothing in this app needs to read
//  Health, and asking for read access buys a second prompt and a privacy
//  manifest question for nothing.
//
//  Authorization is not on this protocol. It is asked for at the first write
//  and nowhere else — see ``HealthKitWorkoutWriter/write(_:)``, which says why
//  the switch being flipped is the wrong moment — so there is nothing above
//  this seam that has to know whether the hiker has been prompted, and a stub
//  that answered the question would be answering one nobody asks.
//
//  ``delete(workoutID:)`` does not change that, and it is worth saying why
//  rather than leaving a reader to check: it deletes *by predicate* rather
//  than by sample, so it never fetches one. The alternative — `delete(_:)`,
//  which takes the `HKWorkout` — would have needed `.workoutType()` in
//  `readTypes` and cost exactly the promise this section makes. A delete is
//  not a read, but it is also not nothing, so the Settings footer says it
//  out loud beside the sentence about reading. The switch is off until a hiker turns it on,
//  because Health is their most sensitive store and the app has no business
//  writing to it merely because they recorded a walk — the same shape
//  ``SettingsKey/keepScreenAwake`` and *Also Save to Photos* already take.
//

import Foundation
import OpenHikesData

/// Everything a workout carries, lifted off the recording that produced it.
///
/// Every figure here is already computed and already `Sendable` by the time a
/// recording is persisted; none of it is derived a second time.
nonisolated struct HikeWorkoutRequest: Equatable, Sendable {
    /// The hike this describes, so the identifier the write returns can be
    /// filed against the right row.
    let hikeID: UUID
    let startedAt: Date
    /// `startedAt` plus the recording's own elapsed time — see
    /// ``PreparedRecording/recordedSeconds``, which counts the gaps between
    /// saved points rather than the wall clock, so a paused lunch is not
    /// exported as an hour of hiking.
    let endedAt: Date
    /// The figure the hike itself shows, with the stationary windows already
    /// retracted — ``PreparedRecording/distanceMeters``.
    let distanceMeters: Double
    /// Barometrically fused where the device had a barometer —
    /// ``RecordingDistanceAccumulator/elevationGainMeters``. `nil` when no two
    /// points carried a trusted altitude, which is a fact about the walk
    /// rather than a zero.
    let elevationGainMeters: Double?
    /// The descent, off the same accumulator and by the same rule —
    /// ``RecordingDistanceAccumulator/elevationLossMeters``. `nil` exactly
    /// when ``elevationGainMeters`` is.
    let elevationLossMeters: Double?
    /// The weather the walk was taken in, or `nil` when the app holds no
    /// reading that is about this walk — see ``HikeWorkoutWeather``.
    let weather: HikeWorkoutWeather?
    /// The saved line, for the map on the workout itself.
    let route: [RouteCoordinate]
}

/// Writes a finished hike into the hiker's Health store, if they asked for it.
@MainActor
protocol HikeWorkoutWriting: Sendable {
    /// Writes `request` as a hiking workout and answers with its identifier in
    /// the Health store.
    ///
    /// Throws rather than reporting, because the caller is fire-and-forget and
    /// logs. A failed write leaves nothing behind — there is no half-written
    /// workout to sweep — which is why this needs no owner the way
    /// `TileOwnership` does.
    func write(_ request: HikeWorkoutRequest) async throws -> UUID

    /// Removes the workout this app wrote under `workoutID`, and its route
    /// with it.
    ///
    /// **A delete, and still no read type.** `HKHealthStore.delete(_:)` takes
    /// the sample, which would mean fetching it, which would mean asking for
    /// `.workoutType()` as a *read* type — and the promise above, and the
    /// sentence under the Settings switch, are that nothing is read back.
    /// `deleteObjects(of:predicate:)` against
    /// `HKQuery.predicateForObject(with:)` needs only share authorization, so
    /// the one thing this app has ever been allowed to do to Health is the
    /// one thing it does.
    ///
    /// The route goes with the workout: `HKWorkoutRoute` is a child of the
    /// sample it was finished against, and HealthKit takes an object's
    /// children with it.
    ///
    /// Throws for the same reason ``write(_:)`` does and is called the same
    /// way. A hike is deleted whether or not this lands — the alternative
    /// would be refusing to delete a hike because a second store would not
    /// co-operate — so the caller logs and moves on.
    func delete(workoutID: UUID) async throws
}
