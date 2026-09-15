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
//  protocol, and ``OpenHikesModel/makeWorkoutWriter(defaults:)`` returns `nil`
//  under `isRunningTests`, matching `makeCommunityTransport()` and
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
//  manifest question for nothing. The switch is off until a hiker turns it on,
//  because Health is their most sensitive store and the app has no business
//  writing to it merely because they recorded a walk — the same shape
//  ``SettingsKey/keepScreenAwake`` and *Also Save to Photos* already take.
//

import Foundation

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
    /// The saved line, for the map on the workout itself.
    let route: [RouteCoordinate]
}

/// Writes a finished hike into the hiker's Health store, if they asked for it.
@MainActor
protocol HikeWorkoutWriting: Sendable {
    /// Whether the hiker has ever been asked. Answering without prompting, so
    /// the Settings switch can be drawn before any permission dialog.
    var isAuthorizationDetermined: Bool { get }

    /// Asks for permission to write, and reports whether the app may.
    ///
    /// Called when the hiker turns the switch on rather than at launch: an app
    /// that asks for Health access before being told to is asking for a
    /// refusal.
    func requestAuthorization() async -> Bool

    /// Writes `request` as a hiking workout and answers with its identifier in
    /// the Health store.
    ///
    /// Throws rather than reporting, because the caller is fire-and-forget and
    /// logs. A failed write leaves nothing behind — there is no half-written
    /// workout to sweep — which is why this needs no owner the way
    /// `TileOwnership` does.
    func write(_ request: HikeWorkoutRequest) async throws -> UUID
}
