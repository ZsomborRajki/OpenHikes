//
//  HikeRecorder+PlaceName.swift
//  OpenHikes
//
//  The name a recording is offered: the trail it mostly followed, or else the
//  town it started in.
//
//  A recording that followed no trail used to be named for the time of day
//  alone — "Morning Hike – Oct 26, 2026" — which says the same of every walk
//  started that morning, wherever it was. The town a walk set off from is what
//  a hiker remembers it by, so it now takes that town's name in the same
//  shape: "Budapest – Oct 26, 2026". It ranks below the two names that know
//  more about the walk itself — the one the hiker types, and the trail the
//  walk mostly followed (``RecordingTrailNames``) — and above the time of day,
//  which is what is left when the town cannot be had. See
//  ``HikeRecorder/suggestedTitle(forDistance:)``.
//
//  ## Asked once, at the first fix
//
//  Not at Stop, for two reasons. The stop alert offers the name a hike will be
//  saved under as its placeholder, and it can only offer one that is already
//  known. And a trailhead is where a phone is likeliest to have signal; the
//  end of a walk can be the far side of a ridge.
//
//  One question per recording, about one coordinate, and a failed one is not
//  asked again: the name it would have given is a nicety, and the name it
//  falls back to is the one every recording had before this. A relaunch that
//  recovers the walk asks once more, about the same first point, because the
//  answer was only ever held in memory. That includes a walk already stopped,
//  which comes back to its route review, where no fix arrives to ask at.
//
//  ## Held, not written
//
//  The answer waits in ``HikeRecorder/startPlaceTitle`` until the hike is
//  saved, and the draft keeps its time-of-day title until then, as it does for
//  a trail's name. The draft is a mirrored row and the title the Live Activity
//  draws, so renaming it seconds after Start would be a CloudKit export and a
//  Lock Screen relabeling itself, for a name the stop alert shows the hiker
//  anyway.
//
//  ## What the stop alert shows is what is saved
//
//  The answer can still be on its way when the hiker stops: from a trailhead
//  with poor signal, or soon after a relaunch. So the stop alert hands the
//  recorder the name it showed, and a blank field saves that name even if the
//  town answers while the alert is up or during the route review after it —
//  see ``HikeRecorder/stop(customName:offeredTitle:)``. Only a Stop that
//  showed no name, such as Siri's, takes whatever has arrived by the save.
//

import CoreLocation
import Foundation
import OpenHikesData

extension HikeRecorder {
    /// The name to offer this walk: the trail that covered enough of it to be
    /// worth claiming — see ``RecordingTrailNames/coverageFloor`` — or else
    /// the town it started in, ``startPlaceTitle``. `nil` when neither has
    /// one, which leaves the draft's own name: the time of day and the date.
    ///
    /// The trail first, because it is the more particular of the two: a town
    /// is where every walk from its station starts, and the trail is the one
    /// this walk went along.
    ///
    /// Bounded through ``HikeTitle`` like every other name this app stores.
    /// OpenStreetMap's `name` is somebody else's free text arriving over the
    /// network, which is exactly the input that bound exists for, and a route
    /// relation's name is occasionally a paragraph. The town's name is bounded
    /// where it was made, in ``placeTitle(city:for:calendar:)``.
    ///
    /// - Parameter totalMeters: The walk's distance. Passed rather than read
    ///   off ``stats`` so the two callers can each use the figure that is
    ///   authoritative for them: the live accumulator's while the walk is
    ///   still running, and the prepared recording's once it has been
    ///   measured for the last time.
    func suggestedTitle(forDistance totalMeters: Double) -> String? {
        HikeTitle.bounded(trailNames.dominantName(of: totalMeters)) ?? startPlaceTitle
    }

    /// What the walk would be named if it ended now.
    ///
    /// Read when the hiker asks to stop, to fill the name field's placeholder.
    /// Deliberately *not* read from inside a `body`: it reads
    /// ``RecordingStats/distanceMeters``, which changes on every accepted fix,
    /// and a body that observed it would re-run at fix rate.
    var suggestedTitle: String? {
        suggestedTitle(forDistance: stats.distanceMeters)
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
              let askingSessionID = sessionID,
              let startedAt = sessionStartedAt else { return }
        hasAskedForStartPlace = true
        Task { [weak self] in
            let city = await placeNames.cityName(at: coordinate)
            guard let self, sessionID == askingSessionID else { return }
            startPlaceTitle = city.flatMap { name in
                Self.placeTitle(city: name, for: startedAt)
            }
        }
    }
}
