//
//  WatchWalkHealthExport.swift
//  OpenHikes
//
//  A walk from the watch, written to Health by the phone.
//
//  ## Why the phone
//
//  The watch discards the workout its session builds, on every path out of a
//  recording, so that one walk is one workout — see `WatchRecorder`'s
//  `endWorkoutSession()`. That makes this phone the single writer for a watch
//  walk as it is for its own recordings, and this is that writer's call site:
//  without it a walk arrived, became a hike, and never reached Health.
//
//  ## Only on the arrival that saved it
//
//  `.imported`, never `.alreadyImported`. A redelivery is the same walk, and
//  the arrival that saved it is the one that wrote it; a second write would be
//  the duplicate workout the watch threw its own away to avoid. A refused
//  import writes nothing, for the rule `HikeRecorder` keeps: Health must never
//  hold a walk this app does not.
//
//  ## Whose figures
//
//  The saved hike's distance and line, for the reason ``WatchWalkImport``
//  measures the track itself rather than taking the watch's total. The climb
//  and descent are the watch's, off its own accumulator, the way a phone
//  recording's come off the phone's. The end is when the hiker stopped, and
//  the pauses are the saved line's, which carries the watch's own pause flags
//  as ``RouteBoundary`` — so Health's duration is the moving time the watch
//  counted without the workout ending early. See ``HikeWorkoutPauses``.
//
//  ## Handed on, not read back
//
//  The line and the distance are the ones the import saved, handed on in
//  ``ImportedWatchWalk``, the way a phone recording hands on its
//  `PreparedRecording`. This used to fetch the hike into the main context
//  and read its line there (#1372). The line is external storage, so that
//  decoded all of it on the main actor to learn what the import had held a
//  moment before. Whether the hike is still there to describe is
//  ``HikeWorkoutExport``'s question, asked on both sides of the write, so a
//  hike deleted since the import is neither written nor marked.
//

import Foundation
import OpenHikesData
import OpenHikesShared
import SwiftData

@MainActor
struct WatchWalkHealthExport {
    let writer: any HikeWorkoutWriting
    let container: ModelContainer
    let defaults: UserDefaults
    /// The phone's weather, read once per walk. Kept only when the reading is
    /// about this walk — see ``HikeWorkoutWeather`` — which for a walk that
    /// ended hours before the phone heard of it is usually not.
    let weatherState: () -> WeatherBadgeState

    /// Writes the walk to Health if this arrival saved it and the hiker asked
    /// for that; otherwise does nothing.
    func export(_ walk: WatchRecordedWalk, after outcome: WatchWalkImportOutcome) async {
        guard case .imported(let saved) = outcome,
              HikeWorkoutExport.isEnabled(in: defaults) else { return }
        await HikeWorkoutExport.write(request(for: walk, savedAs: saved), with: writer, filingInto: container)
    }

    /// The workout `walk` becomes, from what its import saved.
    private func request(for walk: WatchRecordedWalk, savedAs saved: ImportedWatchWalk) -> HikeWorkoutRequest {
        let endedAt = HikeWorkoutPauses.end(
            stoppedAt: walk.endedAt,
            startedAt: walk.startedAt,
            route: saved.route
        )
        return HikeWorkoutRequest(
            hikeID: saved.hikeID,
            startedAt: walk.startedAt,
            endedAt: endedAt,
            pauses: HikeWorkoutPauses.pauses(in: saved.route, from: walk.startedAt, to: endedAt),
            distanceMeters: saved.distanceMeters,
            elevationGainMeters: walk.elevationGainMeters,
            elevationLossMeters: walk.elevationLossMeters,
            weather: HikeWorkoutWeather(
                state: weatherState(),
                walkFrom: walk.startedAt,
                to: endedAt
            ),
            route: saved.route
        )
    }
}
