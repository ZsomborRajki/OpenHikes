//
//  RouteEditWorkout.swift
//  OpenHikes
//
//  The workout Health holds for a hike whose line was edited: taken out, and
//  written again from the line the hike has now.
//
//  A recording saved with *Save to Health* on left a workout there, with the
//  drive in it if the recording ran on through one. Cut off the hike and left
//  in Health, the two would disagree for good — Health cannot be read, so
//  nothing would ever notice — and the owner's decision is that an edit
//  replaces it. A revert writes the original back the same way.
//
//  ## Only what this phone wrote, and only while the switch is on
//
//  ``HikeLocalState/wroteToHealth`` is device-local, so a hike edited on the
//  iPad leaves the phone's workout alone: only the device that wrote one can
//  find it again, by the hike's identifier. And the hiker's switch is read
//  here as it is at every export (``HikeWorkoutExport/isEnabled(in:)``): with
//  it off nothing is written to Health, a replacement included, and a workout
//  that cannot be put back is not taken out.
//
//  ## Out before in, and not in unless out
//
//  Two workouts for one walk is the outcome every Health path here exists to
//  prevent, so the new one is written only once the delete has answered. A
//  delete that failed leaves the old workout, which is still a true record of
//  the hike as it was saved. So the delete is the one a replacement makes
//  (``HikeWorkoutWriting/deleteWorkoutToReplace(of:)``), which takes the
//  workout out last and only once nothing after it can fail: the delete a
//  hike's deletion makes can throw with the workout already gone.
//
//  ## One at a time
//
//  Each visit to the editor fires off its own replacement, and the recording
//  may still be writing the first workout. Two of them side by side would
//  interleave their deletes and writes and leave two workouts, so each takes
//  its turn on the recorder's ``HikeWorkoutQueue``.
//
//  ## Whose figures
//
//  The line's own, as the hike's screen reads them: its first and last stamp,
//  its pauses (``HikeWorkoutPauses``), its distance, and the climb and
//  descent ``RouteProfile`` adds up. The barometer's totals the first export
//  carried were about the whole recording and cannot be cut.
//

import Foundation
import OpenHikesData
import os
import SwiftData

@MainActor
enum RouteEditWorkout {
    private static let logger = Logger(subsystem: "OpenHikes", category: "Health")

    /// What a replacement needs of the app, which a launch with no Health
    /// has none of — see ``OpenHikesModel/makeWorkoutWriter()``.
    struct Health {
        let writer: any HikeWorkoutWriting
        /// The recorder's, which every other path into Health takes its
        /// turn on too.
        let queue: HikeWorkoutQueue
        let container: ModelContainer
        let defaults: UserDefaults
        let weatherState: () -> WeatherBadgeState
    }

    /// Whether `hike` has a workout of this phone's in Health that an edit
    /// should replace.
    static func isOwed(for hike: Hike, in defaults: UserDefaults) -> Bool {
        hike.localState?.wroteToHealth == true && HikeWorkoutExport.isEnabled(in: defaults)
    }

    /// Replaces the workout of the hike `hikeID` with one of `route`, once
    /// everything asked of Health for the hike before it has finished.
    ///
    /// Awaited by nobody: the caller has saved the hike and fires this off,
    /// as the recorder fires its export.
    ///
    /// - Returns: The task that makes the replacement, for a suite to wait on.
    @discardableResult static func replace(
        of hikeID: UUID,
        with route: [RouteCoordinate],
        distanceMeters: Double,
        through health: Health
    ) -> Task<Void, Never> {
        health.queue.enqueue(for: hikeID) {
            await replaceInTurn(of: hikeID, with: route, distanceMeters: distanceMeters, through: health)
        }
    }

    private static func replaceInTurn(
        of hikeID: UUID,
        with route: [RouteCoordinate],
        distanceMeters: Double,
        through health: Health
    ) async {
        guard let request = await request(for: hikeID, route: route, distanceMeters: distanceMeters, health) else {
            return
        }
        do {
            try await health.writer.deleteWorkoutToReplace(of: hikeID)
        } catch {
            logger.error(
                """
                Health kept the workout of an edited hike \(hikeID, privacy: .private): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            return
        }
        await HikeWorkoutExport.write(request, with: health.writer, filingInto: health.container)
    }

    /// The workout `route` becomes, or `nil` for a line with no clock, which
    /// is no workout.
    private static func request(
        for hikeID: UUID,
        route: [RouteCoordinate],
        distanceMeters: Double,
        _ health: Health
    ) async -> HikeWorkoutRequest? {
        guard let startedAt = route.first(where: { $0.timestamp != nil })?.timestamp else { return nil }
        let endedAt = HikeWorkoutPauses.end(stoppedAt: nil, startedAt: startedAt, route: route)
        guard endedAt > startedAt else { return nil }
        let relief = await relief(of: route)
        return HikeWorkoutRequest(
            hikeID: hikeID,
            startedAt: startedAt,
            endedAt: endedAt,
            pauses: HikeWorkoutPauses.pauses(in: route, from: startedAt, to: endedAt),
            distanceMeters: distanceMeters,
            elevationGainMeters: relief.gainMeters,
            elevationLossMeters: relief.lossMeters,
            weather: HikeWorkoutWeather(state: health.weatherState(), walkFrom: startedAt, to: endedAt),
            route: route
        )
    }

    /// The line's climb and descent, added up off the main actor: a long
    /// recording is twenty thousand points.
    @concurrent
    nonisolated private static func relief(of route: [RouteCoordinate]) async -> RouteElevationSummary {
        RouteProfile(route: route).elevation
    }
}
