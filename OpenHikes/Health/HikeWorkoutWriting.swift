//
//  HikeWorkoutWriting.swift
//  OpenHikes
//
//  The seam between a finished recording and the hiker's Health store.
//
//  ## Why there is a seam at all
//
//  HealthKit is unavailable in a hosted unit test the way ActivityKit and
//  `StoreKitTest` are — see *Settled decisions* in `AGENTS.md`. So everything
//  worth asserting is arranged to sit *above* this protocol, and
//  ``OpenHikesModel/makeWorkoutWriter()`` returns `nil` under
//  `isRunningTests`, matching `makeCommunityTransport()` and
//  `makeLiveActivityController(defaults:)`. What the writer itself decides —
//  the tag, what a failure takes back, what a locked finish counts as — sits
//  above a second, narrower seam under it, ``HealthWorkoutStore``.
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
//  ``deleteWorkout(of:)`` does not change that, and it is worth saying why
//  rather than leaving a reader to check: it deletes *by predicate* — the tag
//  the write put on everything it saved — rather than by sample, so it never
//  fetches one. The alternative — `delete(_:)`, which takes the `HKWorkout` —
//  would have needed `.workoutType()` in `readTypes` and cost exactly the
//  promise this section makes, which the Health purpose strings in
//  `OpenHikes/Info.plist` make to the hiker. A delete is not a read, but it is
//  also not nothing, so the Settings footer says it out loud: deleting the
//  hike takes its workout with it.
//
//  The switch is off until a hiker turns it on, because Health is their most
//  sensitive store and the app has no business writing to it merely because
//  they recorded a walk — the same shape ``SettingsKey/keepScreenAwake`` and
//  *Also Save to Photos* already take.
//

import Foundation
import OpenHikesData

/// Everything a workout carries, lifted off the recording that produced it.
///
/// Every figure here is already computed and already `Sendable` by the time a
/// recording is persisted; none of it is derived a second time.
nonisolated struct HikeWorkoutRequest: Equatable, Sendable {
    /// The hike this describes. Everything the write saves is tagged with it,
    /// which is how the hike's deletion finds those objects again without
    /// reading Health.
    let hikeID: UUID
    let startedAt: Date
    /// When the hiker stopped — the wall clock, pauses and all — so every
    /// point of ``route`` falls inside the workout. See
    /// ``HikeWorkoutPauses/end(stoppedAt:startedAt:route:)``.
    let endedAt: Date
    /// The stretches of `startedAt...endedAt` the walk was not recording,
    /// written as pause and resume events so Health's duration is the moving
    /// time the hike shows rather than the wall clock: a paused lunch is not
    /// exported as an hour of hiking. See ``HikeWorkoutPauses``.
    let pauses: [DateInterval]
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
    /// Writes `request` as a hiking workout, tagging everything it saves with
    /// ``HikeWorkoutRequest/hikeID``.
    ///
    /// Throws rather than reporting, because the caller is fire-and-forget and
    /// logs. A throw does not mean Health holds nothing. A write that fails
    /// after its first sample takes back what it saved before it throws, and
    /// whatever that cannot take back is still the hike's deletion's to find
    /// by the tag. A workout Health saved and did not hand back, which is what
    /// a locked phone answers, is no throw at all: it is a write. See
    /// `HealthKitWorkoutWriter.swift`.
    func write(_ request: HikeWorkoutRequest) async throws

    /// Removes everything a write for `hikeID` saved — the workout, its route
    /// and its distance — found by the tag rather than by an identifier
    /// Health may never have handed back.
    ///
    /// **A delete, and still no read type.** `HKHealthStore.delete(_:)` takes
    /// the sample, which would mean fetching it, which would mean asking for
    /// `.workoutType()` as a *read* type — and the promise above, and the
    /// Health purpose strings in `OpenHikes/Info.plist`, are that nothing is
    /// read back. `deleteObjects(of:predicate:)` against
    /// `HKQuery.predicateForObjects(withMetadataKey:allowedValues:)` needs
    /// only share authorization, so the one thing this app has ever been
    /// allowed to do to Health is the one thing it does.
    ///
    /// Each type by name: neither HealthKit's headers nor Apple's pages on
    /// deleting say that a workout takes its route or its samples with it.
    ///
    /// Throws for the same reason ``write(_:)`` does and is called the same
    /// way. A hike is deleted whether or not this lands — the alternative
    /// would be refusing to delete a hike because a second store would not
    /// co-operate — so the caller logs and moves on.
    func deleteWorkout(of hikeID: UUID) async throws
}
