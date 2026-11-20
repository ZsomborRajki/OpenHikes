//
//  HikeRecorder+PlaceName.swift
//  OpenHikes
//
//  The name a recording is offered: the town it started in, the trail it
//  mostly followed, a word for a loop, and the day.
//
//  A recording used to take one of those and drop the rest: the trail's name
//  alone where a trail covered half the walk, "Budapest – Oct 26, 2026" where
//  none did, and "Morning Hike – Oct 26, 2026" with no town either. A trail's
//  name alone says the same of every walk along it, and of a walk round it
//  the same as of one up it and back. So the walk now says all it knows, in
//  one order — see ``RecordingTitle`` — and this file is where each part is
//  found: the town here, the trail by ``RecordingTrailNames``, the loop by
//  ``RouteShape``. See ``HikeRecorder/suggestedTitle(forDistance:along:startedAt:)``.
//
//  ## The town is asked once, at the first fix
//
//  Not at Stop, for two reasons. The stop alert offers the name a hike will be
//  saved under, and it can only offer one that is already known. And a
//  trailhead is where a phone is likeliest to have signal; the end of a walk
//  can be the far side of a ridge.
//
//  One question per recording, about one coordinate, and a failed one is not
//  asked again: the town is a nicety, and the name without it is one every
//  recording could already have. A relaunch that recovers the walk asks once
//  more, about the same first point, because the answer was only ever held in
//  memory. That includes a walk already stopped, which comes back to its
//  route review, where no fix arrives to ask at.
//
//  ## Held, not written
//
//  The answer waits in ``HikeRecorder/startPlaceName`` until the hike is
//  saved, and the draft keeps its time-of-day title until then, as it does for
//  a trail's name. The draft is a mirrored row and the title the Live Activity
//  draws, so renaming it seconds after Start would be a CloudKit export and a
//  Lock Screen relabeling itself, for a name the stop alert shows the hiker
//  anyway.
//
//  ## What the stop alert shows is what is saved
//
//  The town can still be on its way when the hiker stops: from a trailhead
//  with poor signal, or soon after a relaunch. So the stop alert hands the
//  recorder the name it showed, and a field left as it opened saves that name
//  even if the town answers while the alert is up or during the route review
//  after it — see ``HikeRecorder/stop(customName:offeredTitle:)``. Only a
//  Stop that showed no name, such as Siri's, takes whatever has arrived by
//  the save.
//

import CoreLocation
import Foundation
import OpenHikesData

extension HikeRecorder {
    /// The name to offer this walk — see ``RecordingTitle`` for its parts and
    /// their order — or `nil` when it has neither a trail nor a town to be
    /// named for, which leaves the draft's own name: the time of day and the
    /// date.
    ///
    /// The trail is the one that covered enough of the walk to be worth
    /// claiming — see ``RecordingTrailNames/coverageFloor`` — and the loop is
    /// said only beside it, so the line is not read for a walk no trail
    /// named.
    ///
    /// - Parameters:
    ///   - totalMeters: The walk's distance. Passed rather than read off
    ///     ``stats`` so the two callers can each use the figure that is
    ///     authoritative for them: the live accumulator's while the walk is
    ///     still running, and the prepared recording's once it has been
    ///     measured for the last time.
    ///   - line: The line the walk drew, for the same two callers: the one
    ///     on the map while it runs, and the prepared one at the save.
    ///   - startedAt: When it started, or `nil` for no walk at all.
    func suggestedTitle(
        forDistance totalMeters: Double,
        along line: @autoclosure () -> [CLLocationCoordinate2D],
        startedAt: Date?
    ) -> String? {
        guard let startedAt else { return nil }
        let trail = trailNames.dominantName(of: totalMeters)
        return RecordingTitle.title(
            city: startPlaceName,
            trail: trail,
            shape: trail == nil ? nil : RouteShape.of(line()),
            date: startedAt
        )
    }

    /// What the walk would be named if it ended now.
    ///
    /// Read when the hiker asks to stop, to fill the name field. Deliberately
    /// *not* read from inside a `body`: it reads
    /// ``RecordingStats/distanceMeters``, which changes on every accepted fix,
    /// and a body that observed it would re-run at fix rate. It also copies
    /// the line drawn so far, which is once a tap and never once a fix.
    var suggestedTitle: String? {
        suggestedTitle(
            forDistance: stats.distanceMeters,
            along: trace.recordedCoordinates,
            startedAt: sessionStartedAt
        )
    }

    /// Asks what town this recording started in, the first time it is called
    /// for a recording.
    ///
    /// Called with every accepted fix and with a recovered walk's first point,
    /// so the first of those is the start: later calls ask nothing. A `nil`
    /// coordinate — a recovered walk with no points yet — asks nothing either,
    /// and leaves the question to the first fix.
    ///
    /// The answer belongs to the recording that asked. One that lands after
    /// that recording was saved or discarded, or after another has started, is
    /// dropped rather than naming a walk somewhere else.
    func nameStartPlace(at coordinate: CLLocationCoordinate2D?) {
        guard let placeNames,
              let coordinate,
              !hasAskedForStartPlace,
              let askingSessionID = sessionID else { return }
        hasAskedForStartPlace = true
        Task { [weak self] in
            let city = await placeNames.cityName(at: coordinate)
            guard let self, sessionID == askingSessionID else { return }
            startPlaceName = city
        }
    }
}
