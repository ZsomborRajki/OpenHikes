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
        guard case .imported(let hikeID) = outcome,
              HikeWorkoutExport.isEnabled(in: defaults),
              let request = request(for: walk, savedAs: hikeID) else { return }
        await HikeWorkoutExport.write(request, with: writer, filingInto: container)
    }

    /// The workout `walk` becomes, or `nil` once its hike is gone — deleted in
    /// the moment between the import and this, which leaves nothing to write.
    private func request(for walk: WatchRecordedWalk, savedAs hikeID: UUID) -> HikeWorkoutRequest? {
        var descriptor = FetchDescriptor<Hike>(predicate: #Predicate { $0.id == hikeID })
        descriptor.fetchLimit = 1
        guard let hike = try? container.mainContext.fetch(descriptor).first else { return nil }
        let endedAt = HikeWorkoutPauses.end(
            stoppedAt: walk.endedAt,
            startedAt: walk.startedAt,
            route: hike.route
        )
        return HikeWorkoutRequest(
            hikeID: hikeID,
            startedAt: walk.startedAt,
            endedAt: endedAt,
            pauses: HikeWorkoutPauses.pauses(in: hike.route, from: walk.startedAt, to: endedAt),
            distanceMeters: hike.distanceMeters,
            elevationGainMeters: walk.elevationGainMeters,
            elevationLossMeters: walk.elevationLossMeters,
            weather: HikeWorkoutWeather(
                state: weatherState(),
                walkFrom: walk.startedAt,
                to: endedAt
            ),
            route: hike.route
        )
    }
}
